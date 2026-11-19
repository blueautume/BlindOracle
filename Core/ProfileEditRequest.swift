import Foundation

/// A conversational request can open the form and identify a field or person.
/// Only the form may supply the value to be saved.
struct ProfileEditRequest: Equatable {
    enum Target: Equatable {
        case selfProfile
        case profiles([UUID])
        case unspecified
    }

    let fields: [OracleField]
    let target: Target
    let readingQuestion: String?
    let acceptsCurrentParticipant: Bool
    var startsNewReading: Bool { readingQuestion != nil }

    static func recognize(_ text: String, profiles: [OracleProfile], selfProfileID: UUID?) -> Self? {
        let clauses = text.components(separatedBy: CharacterSet(charactersIn: "，,；;。\n\r"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard let first = clauses.first else { return nil }
        let following = clauses.dropFirst()
        let editsBeforeReading = following.contains { ReadingContinuationPolicy.isBareRecastRequest($0) || usesUpdatedDetails($0) }
        let edit: EditClause
        let trailing: ArraySlice<String>
        if let firstEdit = editClause(first, allowsValueStatement: editsBeforeReading),
           !firstEdit.isValueStatement || isSelf(normalizedOwner(firstEdit.owner))
                || !matchingIDs(normalizedOwner(firstEdit.owner), profiles: profiles).isEmpty {
            edit = firstEdit
            trailing = following
        } else if let second = following.first, let nextEdit = editClause(second, allowsValueStatement: editsBeforeReading), nextEdit.owner.isEmpty,
                  isSelf(normalizedOwner(first)) || !matchingIDs(normalizedOwner(first), profiles: profiles).isEmpty {
            // Users sometimes name the intended person in its own clause.
            edit = EditClause(owner: first, fields: nextEdit.fields, checkedClause: first + "，" + nextEdit.checkedClause,
                              tail: nextEdit.tail, isValueStatement: false)
            trailing = following.dropFirst()
        } else {
            return nil
        }
        // Polite requests may end in a question mark. A consultation or
        // hypothetical still fails the same policy used for profile facts.
        let checked = ([edit.checkedClause] + trailing).joined(separator: "，")
        guard ProfileFactPolicy.allowsPersistence(in: checked) else { return nil }

        let owner = normalizedOwner(edit.owner)
        let ids = matchingIDs(owner, profiles: profiles)
        let target: Target
        if isSelf(owner) || ids.count == 1 && ids.first == selfProfileID {
            target = .selfProfile
        } else if !ids.isEmpty {
            target = .profiles(ids)
        } else {
            target = .unspecified
        }
        let readingQuestion = readingClause(in: edit.tail) ?? trailing.compactMap(readingClause).first
        let contextualOwner = ["", "他", "她", "对方", "這個人", "这个人", "his", "her"].contains(owner.lowercased())
        return Self(fields: edit.fields, target: target, readingQuestion: readingQuestion,
                    acceptsCurrentParticipant: contextualOwner)
    }

    /// Use the confirmed replacement input with the existing reading when
    /// the user asks to interpret updated details without requesting a redraw.
    static func usesUpdatedDetails(_ tail: String) -> Bool {
        let details = #"(?:最新|新|已更正|已修改|已补充|更新后|更正后|修改后|补充后|改过)(?:的)?(?:出生资料|出生信息|资料|信息|数据)"#
        let pattern = #"^\s*(?:那就|那|就|请|帮我|麻烦|然后|接着)*(?:按|按照|用|参考|结合|根据)"# + details
            + #"(?:再)?(?:看看|看一下|看一看|看|分析一下|解读一下)(?:吧|呢|好吗)?[。！!？?]*\s*$"#
        return contains(pattern, in: tail)
            || contains(#"^\s*(?:please\s+)?(?:revisit|review|look again|interpret)(?:\s+(?:it|the reading))?\s+(?:using|with)\s+(?:the\s+)?(?:updated|corrected|new)\s+(?:birth\s+)?details[.!?]*\s*$"#, in: tail)
    }

    private struct EditClause {
        let owner: String
        let fields: [OracleField]
        let checkedClause: String
        let tail: String
        let isValueStatement: Bool
    }

    private static let fields: [(OracleField, String, String)] = [
        (.birthTimeZone, #"出生地(?:的)?时区|出生时区|出生地(?:的)?時區|出生時區|时区|時區"#, #"birth(?:place)? time ?zone|time ?zone"#),
        (.birthCoordinates, #"出生地(?:经纬度|經緯度|坐标|座標)|出生(?:经纬度|經緯度|坐标|座標)"#, #"birth(?:place)? coordinates"#),
        (.birthPlace, #"出生地(?:点|點)?|出生城市"#, #"place of birth|birth ?place|birth city"#),
        (.birthTime, #"出生(?:的)?时[间刻辰]|出生(?:的)?時[間刻辰]|时辰|時辰"#, #"time of birth|birth time"#),
        (.birthDate, #"出生(?:的)?日[期子]|出生年月日|出生年月|生[日辰]|出生日期"#, #"date of birth|birth ?date|birthday|dob"#),
        (.currentLocation, #"当前所在地|目前所在地|当前地点|目前地点|现居地|現居地|所在地"#, #"current location|where i live|place of residence"#),
        (.gender, #"排盘性别|排盤性別|性别|性別"#, #"chart gender|gender|sex"#),
        (.surname, #"姓氏"#, #"family name|last name|surname"#),
        (.givenName, #"名讳|名諱"#, #"given name|first name"#),
        (.name, #"姓名|名字|代称|代稱|昵称|暱稱"#, #"name|nickname|alias"#)
    ]

    private static let chineseField = "(?:" + fields.map { $0.1 }.joined(separator: "|") + ")"
    private static let englishField = "(?:" + fields.map { $0.2 }.joined(separator: "|") + ")"
    private static let chineseFields = chineseField + #"(?:\s*(?:和|及|与|與|以及|、)\s*"# + chineseField + ")*"
    private static let englishFields = englishField + #"(?:\s+and\s+"# + englishField + ")*\\b"
    private static let chineseAction = #"(?:改一下|改一改|修改|更改|更正|修正|纠正|糾正|编辑|編輯|更新|补填|補填|补充|補充|改成|改为|改為|改到|改)"#
    private static let chineseMistake = #"(?:填[错錯]了?|录[错錯]了?|錄[错錯]了?|记[错錯]了?|記[错錯]了?|写[错錯]了?|寫[错錯]了?|有[误誤]|不[对對]|需要修改|需要更正|(?:实际|實際|正确|正確|应该|應該)(?:是|为|為))"#
    private static let chinesePrefix = #"(?:(?:麻烦(?:你)?|麻煩(?:你)?|请(?:你)?|請(?:你)?|帮我|幫我|替我|我要|我想|我需要|你能(?:不能)?|能(?:不能|否)?|可(?:以|不可以))\s*)*"#
    private static let chineseOwner = #"([\p{Han}\p{Latin}\d·・“”「」'’\s-]{0,40}?)\s*的?\s*"#
    private static let withdrawnClock = try? NSRegularExpression(pattern: "^" + chineseOwner
        + #"(?:现在|其实|也)?(?:不(?:太)?知道|不清楚|不确定|不记得|记不清|忘了)(?:自己)?(?:到底|具体)?(?:几点(?:钟)?(?:出生|生的?)|出生(?:的)?(?:时间|时辰|时刻))了?[！!]?$"#)
    private static let englishPrefix = #"(?:(?:please|(?:can|could|would|will) you|(?:can|could|may) i|i (?:want|need|would like) to|help me)\s+)*"#
    private static let englishAction = #"(?:change|correct|update|edit|fix|amend|set|fill in)"#
    private static let englishOwner = #"(?:(my|our|his|her|their|[^\p{P}\d\s][\p{L}\d .’'·-]{0,47}?['’]s|the)\s+)?"#
    private static let regexes: [(NSRegularExpression, isEnglish: Bool, valueStatement: Bool)] = [
        ("^" + chinesePrefix + "(?:把|将|將)\\s*" + chineseOwner + "(" + chineseFields + ")\\s*" + chineseAction + "(.*)$", false, false),
        ("^" + chinesePrefix + chineseAction + "\\s*(?:一下\\s*)?" + chineseOwner + "(" + chineseFields + ")(.*)$", false, false),
        ("^" + chinesePrefix + chineseOwner + "(" + chineseFields + ")\\s*" + "(?:" + chineseAction + "|" + chineseMistake + ")(.*)$", false, false),
        ("^" + englishPrefix + englishAction + "\\s+" + englishOwner + "(" + englishFields + ")(.*)$", true, false),
        ("^" + englishOwner + "(" + englishFields + ")" + #"\s+(?:(?:is|was)\s+(?:wrong|incorrect|mistaken|out of date)|(?:should|ought to) be\b)(.*)$"#, true, false),
        ("^" + chineseOwner + "(" + chineseFields + ")" + #"\s*(?:是|为|為|[:：])(\s*[^\s]+.*)$"#, false, true)
    ].compactMap { pattern, isEnglish, valueStatement in
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { return nil }
        return (regex, isEnglish, valueStatement)
    }

    private static func editClause(_ clause: String, allowsValueStatement: Bool = false) -> EditClause? {
        let polite = contains(#"^(?:请|請|麻[烦煩]|能(?:帮我|幫我|不能|否)|可(?:以|不可以)|你能|can (?:i|you)\b|could (?:i|you)\b|would you\b|may i\b|please\b)"#, in: clause)
        let checkedClause = polite ? clause.replacingOccurrences(of: #"(?:好吗|好嗎|可以吗|可以嗎|吗|嗎)?[？?]+\s*$"#, with: "", options: .regularExpression) : clause
        guard !contains(#"^(?:别|別|不要|不用|无需|無需|不必|不想|不需要|不是要|\b(?:don['’]t|do not|never)\b)"#, in: checkedClause) else { return nil }
        // Do not treat advice about changing a date as a request to edit it.
        guard !contains(#"会不会|會不會|有必要吗|有必要嗎|应该改吗|應該改嗎|should i\b|what happens\b"#, in: checkedClause) else { return nil }
        let range = NSRange(checkedClause.startIndex..., in: checkedClause)
        for (regex, isEnglish, valueStatement) in regexes where allowsValueStatement || !valueStatement {
            guard let match = regex.firstMatch(in: checkedClause, range: range) else { continue }
            func value(at index: Int) -> String {
                Range(match.range(at: index), in: checkedClause).map { String(checkedClause[$0]) } ?? ""
            }
            let names = value(at: 2)
            // Tokenize the longest names first so “出生地时区” focuses the
            // time zone, rather than opening both birthplace and time zone.
            let tokenPattern = isEnglish ? englishField : chineseField
            guard let tokenRegex = try? NSRegularExpression(pattern: tokenPattern, options: .caseInsensitive) else { return nil }
            var seen = Set<OracleField>()
            let matchedFields = tokenRegex.matches(in: names, range: NSRange(names.startIndex..., in: names)).compactMap { token -> OracleField? in
                guard let range = Range(token.range, in: names) else { return nil }
                let key = String(names[range])
                return fields.first { contains("^" + (isEnglish ? "(?:" + $0.2 + ")" : "(?:" + $0.1 + ")") + "$", in: key) }?.0
            }.filter { seen.insert($0).inserted }
            guard !matchedFields.isEmpty else { continue }
            let tail = value(at: 3).trimmingCharacters(in: .whitespacesAndNewlines)
            return EditClause(owner: value(at: 1), fields: matchedFields, checkedClause: checkedClause, tail: tail,
                              isValueStatement: valueStatement)
        }
        if let match = withdrawnClock?.firstMatch(in: checkedClause, range: range),
           let owner = Range(match.range(at: 1), in: checkedClause) {
            return EditClause(owner: String(checkedClause[owner]), fields: [.birthTime], checkedClause: checkedClause, tail: "",
                              isValueStatement: false)
        }
        return nil
    }

    private static func normalizedOwner(_ raw: String) -> String {
        normalizedLabel(normalizedLabel(raw).replacingOccurrences(of: #"['’]s$"#, with: "", options: .regularExpression))
    }

    private static func normalizedLabel(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "“”「」\"")))
            .precomposedStringWithCanonicalMapping
    }

    private static func isSelf(_ owner: String) -> Bool {
        ["我", "我自己", "本人", "自己", "my"].contains(owner.lowercased())
    }

    private static func matchingIDs(_ owner: String, profiles: [OracleProfile]) -> [UUID] {
        guard !owner.isEmpty else { return [] }
        var seen = Set<UUID>()
        return profiles.filter {
            let labels = [$0.resolvedName, $0.alias ?? "", $0.participantLabel]
            return labels.contains { !$0.isEmpty && normalizedLabel($0).localizedCaseInsensitiveCompare(owner) == .orderedSame }
                && seen.insert($0.id).inserted
        }.map(\.id)
    }

    private static func readingClause(in clause: String) -> String? {
        let continuation = #"^(?:然后|然後|接着|接著|接下来|接下來|顺便|順便|(?:and\s+)?then\b)\s*"#
        let subject = clause.replacingOccurrences(of: continuation, with: "", options: [.regularExpression, .caseInsensitive])
        if ReadingContinuationPolicy.isBareRecastRequest(subject) || usesUpdatedDetails(subject) { return subject }
        let question = #"^(?:再|帮我|幫我|请|請|and )*(?:想问|想問|看看|看一下|算一下|测算|測算|帮我看|幫我看|read for\b|read about\b|calculate\b|recalculate\b|interpret\b)"#
        return contains(question, in: subject) ? subject : nil
    }

    private static func contains(_ pattern: String, in text: String) -> Bool {
        text.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
    }
}

import Foundation

/// A patch contains only information the user explicitly supplied. Missing keys
/// preserve saved values; unknownFields explicitly marks individual facts unknown.
/// Dates/times are local calendar text, not inferred UTC instants.
struct ProfileUpdate: Codable, Equatable, Sendable {
    var id: UUID? = nil
    var name: String? = nil
    var familyName: String? = nil
    var givenName: String? = nil
    var sex: String? = nil
    var birthDate: String? = nil
    var birthTime: String? = nil
    var birthTimeKnown: Bool? = nil
    var birthTimeZoneID: String? = nil
    var birthPlace: String? = nil
    var birthLatitude: Double? = nil
    var birthLongitude: Double? = nil
    var unknownFields: [OracleField]? = nil
}

struct ProfileDirectoryIssue: Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable { case missingName, ambiguousName, unknownID, invalidValue }
    var kind: Kind
    var name: String?
    var message: String
    var candidateIDs: [UUID] = []
}

struct ProfileMergeResult: Sendable {
    var profiles: [OracleProfile]
    var appliedIDs: [UUID]
    var issues: [ProfileDirectoryIssue]
}

struct ProfileResolution: Sendable {
    var ids: [UUID]
    var issues: [ProfileDirectoryIssue]
}

enum ProfileDirectory {
    /// Apply the app's default to an unconfirmed zone for an editable or fresh
    /// calculation snapshot. Preserve the birth clock in the old local zone.
    static func assigningDefaultBirthTimeZone(to profile: OracleProfile) -> OracleProfile {
        guard profile.unknownFields.contains(.birthTimeZone)
            || profile.declaredUnknownFields?.contains(.birthTimeZone) == true
            || TimeZone(identifier: profile.birthTimeZoneID) == nil else { return profile }
        var value = profile
        var issues: [ProfileDirectoryIssue] = []
        applyFields(ProfileUpdate(birthTimeZoneID: OracleProfile.defaultChinaTimeZoneID), to: &value, issues: &issues)
        return value
    }

    static func clearingFields(_ fields: Set<OracleField>, in profile: OracleProfile) -> OracleProfile {
        guard !fields.isEmpty else { return profile }
        var value = profile
        var issues: [ProfileDirectoryIssue] = []
        applyFields(ProfileUpdate(unknownFields: Array(fields)), to: &value, issues: &issues)
        return value
    }

    /// An incomplete cached form must not hide facts subsequently saved for
    /// the same UUID. Explicit unknowns and edited known values remain intact.
    static func restoringKnownFields(in draft: OracleProfile, from saved: OracleProfile) -> OracleProfile {
        guard draft.id == saved.id else { return draft }
        var patch = ProfileUpdate(id: draft.id)
        let declared = draft.declaredUnknownFields ?? draft.unknownFields
        func canRestore(_ field: OracleField, missing: Bool) -> Bool {
            !declared.contains(field) && (missing || draft.unknownFields.contains(field))
                && !saved.unknownFields.contains(field) && saved.declaredUnknownFields?.contains(field) != true
        }
        if canRestore(.name, missing: draft.resolvedName.isEmpty), !saved.resolvedName.isEmpty { patch.name = saved.resolvedName }
        if canRestore(.surname, missing: draft.familyName.isEmpty), !saved.familyName.isEmpty { patch.familyName = saved.familyName }
        if canRestore(.givenName, missing: draft.givenName.isEmpty), !saved.givenName.isEmpty { patch.givenName = saved.givenName }
        if canRestore(.birthDate, missing: draft.birthDate == nil), let date = saved.birthDate {
            patch.birthDate = saved.birthDateText ?? format(date, zone: saved.birthTimeZoneID, pattern: "yyyy-MM-dd")
        }
        if canRestore(.birthTime, missing: !draft.birthTimeKnown || (draft.birthTimeText == nil && draft.birthDate == nil)), saved.birthTimeKnown {
            patch.birthTime = saved.birthTimeText ?? saved.birthDate.map { format($0, zone: saved.birthTimeZoneID, pattern: "HH:mm:ss") }
            if patch.birthTime != nil { patch.birthTimeKnown = true }
        }
        if canRestore(.birthTimeZone, missing: TimeZone(identifier: draft.birthTimeZoneID) == nil), TimeZone(identifier: saved.birthTimeZoneID) != nil {
            patch.birthTimeZoneID = saved.birthTimeZoneID
        }
        if canRestore(.gender, missing: draft.sex == "未提供"), ["男", "女"].contains(saved.sex) { patch.sex = saved.sex }
        let draftPlace = draft.birthPlace.trimmingCharacters(in: .whitespacesAndNewlines)
        let savedPlace = saved.birthPlace.trimmingCharacters(in: .whitespacesAndNewlines)
        let noDraftCoordinates = draft.birthLatitude == nil && draft.birthLongitude == nil
        let restorePlace = draftPlace.isEmpty && draft.birthDistrictCode == nil && noDraftCoordinates && !savedPlace.isEmpty
            && canRestore(.birthPlace, missing: true)
        if restorePlace { patch.birthPlace = saved.birthPlace }
        let samePlace: Bool
        if let draftDistrict = draft.birthDistrictCode {
            samePlace = draftDistrict == saved.birthDistrictCode
        } else if saved.birthDistrictCode != nil {
            samePlace = false
        } else {
            samePlace = draftPlace == savedPlace && (!draftPlace.isEmpty || (noDraftCoordinates && !declared.contains(.birthPlace)))
        }
        if (restorePlace || samePlace), canRestore(.birthCoordinates, missing: draft.birthLatitude == nil || draft.birthLongitude == nil),
           let latitude = saved.birthLatitude, let longitude = saved.birthLongitude,
           (-90...90).contains(latitude), (-180...180).contains(longitude) {
            patch.birthLatitude = latitude; patch.birthLongitude = longitude
        }
        var value = draft
        value.alias = draft.alias ?? saved.alias
        value.isAnonymousRecord = draft.isAnonymousRecord ?? saved.isAnonymousRecord
        if patch != ProfileUpdate(id: draft.id) {
            value = applying([patch], to: [value]).profiles.first ?? value
            if patch.birthPlace != nil { value.birthDistrictCode = saved.birthDistrictCode }
        }
        return value
    }

    static func applying(_ updates: [ProfileUpdate], to profiles: [OracleProfile]) -> ProfileMergeResult {
        var result = ProfileMergeResult(profiles: profiles, appliedIDs: [], issues: [])
        for update in updates.prefix(20) {
            let suppliedName = normalizedName(update.name)
            let index: Int
            if let id = update.id {
                guard let found = result.profiles.firstIndex(where: { $0.id == id }) else {
                    result.issues.append(.init(kind: .unknownID, name: suppliedName, message: L10n.text("没有找到这个档案编号，未自动新建或覆盖。", "No profile matches this ID.")))
                    continue
                }
                index = found
            } else {
                guard let suppliedName else {
                    result.issues.append(.init(kind: .missingName, name: nil, message: L10n.text("请明确这份资料对应的姓名，未自动存入任何人的档案。", "Provide a name before saving these details to a profile.")))
                    continue
                }
                let matches = result.profiles.indices.filter { normalizedName(result.profiles[$0].resolvedName) == suppliedName }
                guard matches.count <= 1 else {
                    result.issues.append(.init(kind: .ambiguousName, name: suppliedName,
                        message: L10n.text("有多位同名的\(suppliedName)，请先确认要补充哪一份档案。", "Several people are named \(suppliedName). Choose which profile to update."),
                        candidateIDs: matches.map { result.profiles[$0].id }))
                    continue
                }
                if let found = matches.first { index = found }
                else {
                    var profile = OracleProfile()
                    profile.name = suppliedName
                    profile.sex = "未提供"
                    profile.birthTimeKnown = false
                    // UTC is a storage anchor until the user supplies a zone.
                    // unknownFields prevents it from being asserted as a fact.
                    profile.birthTimeZoneID = "UTC"
                    profile.unknownFields.formUnion([.gender, .birthDate, .birthTime, .birthTimeZone, .birthPlace])
                    result.profiles.append(profile)
                    index = result.profiles.count - 1
                }
            }

            var profile = result.profiles[index]
            if let suppliedName {
                if let oldName = normalizedName(profile.resolvedName), oldName != suppliedName {
                    profile.familyName = ""; profile.givenName = ""
                    profile.unknownFields.formUnion([.surname, .givenName])
                }
                profile.name = suppliedName
                profile.unknownFields.remove(.name)
                profile.declaredUnknownFields?.remove(.name)
            }
            applyFields(update, to: &profile, issues: &result.issues)
            profile.updatedAt = Date()
            result.profiles[index] = profile
            if !result.appliedIDs.contains(profile.id) { result.appliedIDs.append(profile.id) }
        }
        return result
    }

    /// Resolves only explicit names. A duplicate name is never resolved by array
    /// order, recency, sex, relationship words or an assumed "self" profile.
    static func resolve(names: [String], in profiles: [OracleProfile]) -> ProfileResolution {
        var result = ProfileResolution(ids: [], issues: [])
        var seen = Set<String>()
        for raw in names {
            guard let name = normalizedName(raw), seen.insert(name).inserted else { continue }
            let matches = profiles.filter { normalizedName($0.resolvedName) == name }
            if matches.count == 1, let profile = matches.first { result.ids.append(profile.id) }
            else if matches.count > 1 {
                result.issues.append(.init(kind: .ambiguousName, name: name,
                    message: L10n.text("有多位同名的\(name)，请先确认参与的是哪一位。", "Several people are named \(name). Choose the participant’s profile."), candidateIDs: matches.map(\.id)))
            } else {
                result.issues.append(.init(kind: .missingName, name: name, message: L10n.text("还没有\(name)的档案，请先提供其姓名与所需资料。", "There’s no profile for \(name) yet. Enter the name and required details.")))
            }
        }
        return result
    }

    /// Uses the same name boundaries as profile extraction. A saved 李四 is
    /// not selected merely because the question mentions 李四海.
    static func referencedNames(in text: String, profiles: [OracleProfile]) -> [String] {
        let knownNames = Set(profiles.compactMap { normalizedName($0.resolvedName) })
        var seen = Set<String>()
        return nameAnchors(in: text, profiles: profiles, routing: true).compactMap { anchor in
            guard knownNames.contains(anchor.name), seen.insert(anchor.name).inserted else { return nil }
            return anchor.name
        }
    }

    private static let possessivePersonPattern = #"^\s*的\s*(?:同事|同学|朋友|对象|伴侣|家人|爸爸|妈妈|父亲|母亲|孩子|儿子|女儿)(?!关系|缘|运|圈|们|气)"#

    /// A name mentioned while excluding or replacing somebody is not a target.
    static func participantReferences(in text: String, profiles: [OracleProfile]) -> (included: [String], excluded: [String]) {
        let knownNames = Set(profiles.compactMap { normalizedName($0.resolvedName) })
        let source = text as NSString
        let boundaries = CharacterSet(charactersIn: "，,；;。！？!?\n\r")
        var order: [String] = []
        var included: [String: Bool] = [:]
        for anchor in nameAnchors(in: text, profiles: profiles, routing: true) where knownNames.contains(anchor.name) {
            let before = source.substring(to: anchor.range.location).components(separatedBy: boundaries).last ?? ""
            let after = source.substring(from: NSMaxRange(anchor.range)).components(separatedBy: boundaries).first ?? ""
            let prefix = String(before.suffix(20)).filter { !$0.isWhitespace }
            let suffix = String(after.prefix(16)).filter { !$0.isWhitespace }
            let selected = matchesPattern(#"(?:换成|改成|改看|改问|改算|转而看|只看|单独看)$"#, in: prefix)
            let negatedSwitch = matchesPattern(#"(?:不要|不用|不想|先不|暂不|别|不是要|并非要|不)(?:(?:把|将)[^，,；;。！？!?]{1,12})?(?:再)?(?:换成|改成|改看|改问|改算|转而看|只看|单独看)$"#, in: prefix)
            let notOnly = matchesPattern(#"(?:不只|不止|不只是|不是只|不是仅)(?:看|问|算)$"#, in: prefix)
            let negativePrefix = matchesPattern(#"(?:不要|不用|不想|先不|暂不|不看|不算|不问|别|不是|并非).{0,6}$"#, in: prefix)
            let negativeSuffix = matchesPattern(#"^(?:就|先)?(?:不看|不算|不问|别看|暂不看)(?:了|吧|$)"#, in: suffix)
            let replaced = matchesPattern(#"(?:把|将)$"#, in: prefix) && matchesPattern(#"^(?:换成|改成|换掉|替换为)"#, in: suffix)
            let describesAnotherPerson = matchesPattern(possessivePersonPattern, in: suffix)
                || EnglishConversation.matches(after, #"^['’]s\s+(?:friend|partner|spouse|child|sister|brother|mother|father|colleague)\b"#)
            let englishExcluded = EnglishConversation.matches(before, #"\b(?:not|except|exclude|skip|instead of|rather than)\s*$"#)
                || EnglishConversation.matches(before, #"\b(?:replace|switch from)\s*$"#)
            if included[anchor.name] == nil { order.append(anchor.name) }
            included[anchor.name] = !negativeSuffix && !replaced && !describesAnotherPerson && !negatedSwitch && !englishExcluded
                && (selected || notOnly || !negativePrefix)
        }
        return (order.filter { included[$0] == true }, order.filter { included[$0] == false })
    }

    /// A planner can propose a new name. Require the exact literal as a
    /// positive question target before turning it into a saved participant.
    static func isAffirmativeParticipantReference(_ rawName: String, in text: String, profiles: [OracleProfile]) -> Bool {
        guard let name = normalizedName(rawName), isPlausibleName(name) else { return false }
        var candidates = profiles
        if !candidates.contains(where: { normalizedName($0.resolvedName) == name }) {
            var temporary = OracleProfile(); temporary.name = name
            candidates.append(temporary)
        }
        let asks = matchesPattern(#"[？?]|(?:想问|想看|看看|呢|怎么样|如何|怎样|合不合|能不能|会不会)"#, in: text)
        let targetPrefix = #"(?:看看|看一下|看|替|给|问一下|问|算一下|算|换成|改看|改问|改算)(?:我(?:的)?(?:朋友|同事|同学|对象|伴侣|家人|爸爸|妈妈))?\s*$"#
        let targetSuffix = #"^\s*(?:的)?(?:工作|事业|感情|运势|财运|婚姻|学业|关系|合作|合不合|相处|呢|最近|下周|这周|今年|明年|怎么样|如何|这个名字|这个笔名|当笔名|作为笔名)"#
        let boundaries = CharacterSet(charactersIn: "，,；;。！？!?\n\r")
        return text.components(separatedBy: boundaries).contains { clause in
            guard participantReferences(in: clause, profiles: candidates).included.contains(name) else { return false }
            let source = clause as NSString
            return nameAnchors(in: clause, profiles: candidates, routing: true).contains { anchor in
                guard anchor.name == name else { return false }
                let before = source.substring(to: anchor.range.location)
                let after = source.substring(from: NSMaxRange(anchor.range))
                guard !matchesPattern(possessivePersonPattern, in: after),
                      !matchesPattern(#"^\s*的(?:资料|档案)"#, in: after) else { return false }
                return matchesPattern(targetPrefix, in: before) || asks && matchesPattern(targetSuffix, in: after)
                    || EnglishConversation.matches(before, #"\b(?:for|about|switch to|read for|include)\s*$"#)
                    || asks && EnglishConversation.matches(after, #"^['’]s\s+(?:career|job|relationship|chart|health|finances|marriage)\b"#)
            }
        }
    }

    /// Conservative offline grammar: named demographic statements only. It does
    /// not bind pronouns or infer sex, birth place, birth time or birth time zone.
    static func parseExplicitUpdates(in text: String, profiles: [OracleProfile]) -> [ProfileUpdate] {
        let source = text as NSString
        let anchors = nameAnchors(in: text, profiles: profiles)
        let speaker = explicitSelfName(in: text, profiles: profiles)
        var updates: [ProfileUpdate] = []
        for (index, anchor) in anchors.enumerated() {
            let end = index + 1 < anchors.count ? anchors[index + 1].range.location : source.length
            var segment = source.substring(with: NSRange(location: NSMaxRange(anchor.range), length: max(0, end - NSMaxRange(anchor.range))))
            if matchesPattern(possessivePersonPattern, in: segment) { continue }
            if let questionBoundary = segment.firstIndex(where: { $0 == "？" || $0 == "?" }) {
                let preceding = segment[..<questionBoundary]
                let breakIndex = preceding.lastIndex(where: { "，,；;。！!\n\r".contains($0) })
                let clauseStart = breakIndex.map { preceding.index(after: $0) } ?? preceding.startIndex
                let clause = String(preceding[clauseStart...])
                let beforeAnchor = source.substring(to: anchor.range.location)
                let uncertain = matchesPattern(#"(?:是不是|是否|可能是|好像是|大概是|对不对|[吗么]\s*$)"#, in: clause)
                    || EnglishConversation.matches(clause, #"\b(?:maybe|possibly|probably|is that right|i think)\b"#)
                    || EnglishConversation.matches(beforeAnchor, #"\b(?:was|is|were|could|might|maybe|possibly|did|when was|where was)\s*$"#)
                segment = String(preceding[..<(uncertain ? clauseStart : preceding.endIndex)])
            }
            if speaker != anchor.name,
               let selfFacts = segment.range(of: #"(?:^|[，,；;。.!\n\r])\s*(?:and\s+)?(?:(?:我(?:自己)?(?:的)?|本人(?:的)?)\s*(?:出生|生日|性别|时区|姓氏|名字|(?:不(?:知道|清楚|确定|记得)|记不清|忘了).{0,8}(?:几点(?:出生|生)|出生.{0,3}(?:时间|时辰)))|my\s+(?:birth(?:day| date| time|place)?|date of birth|time of birth|sex|gender|time zone|surname|given name)|i was born|i(?: am|['’]m)\s+(?:male|female)\b)"#, options: [.regularExpression, .caseInsensitive]) {
                segment = String(segment[..<selfFacts.lowerBound])
            }
            var patch = parseFields(in: segment)
            patch.name = anchor.name
            let matches = profiles.filter { normalizedName($0.resolvedName) == anchor.name }
            if matches.count == 1 { patch.id = matches.first?.id }
            if anchor.explicitName || hasFacts(patch) { updates.append(patch) }
        }
        return updates
    }

    /// Intake already bound to a UUID may accept a field statement without
    /// requiring the profile to contain a real name.
    static func parseContextualFields(in text: String, for id: UUID) -> [ProfileUpdate] {
        guard !text.contains("？"), !text.contains("?") else { return [] }
        var patch = parseFields(in: text)
        guard hasFacts(patch) else { return [] }
        patch.id = id
        return [patch]
    }

    private static func parseFields(in segment: String) -> ProfileUpdate {
        var patch = ProfileUpdate()
        var unknown: [OracleField] = []

        if let family = capture(#"姓氏\s*(?:是|为)?\s*[:：]?\s*([^，,；;。\n\s]+)"#, in: segment) {
            if matchesPattern(#"^(?:未知|不详|不确定|不知道|不清楚)$"#, in: family) { unknown.append(.surname) }
            else { patch.familyName = family }
        }
        if let given = capture(#"名字\s*(?:是|为)?\s*[:：]?\s*([^，,；;。\n\s]+)"#, in: segment) {
            if matchesPattern(#"^(?:未知|不详|不确定|不知道|不清楚)$"#, in: given) { unknown.append(.givenName) }
            else { patch.givenName = given }
        }

        if let sex = capture(#"(?:性别\s*(?:是|为)?\s*[:：]?\s*|(?:^|[，,；;\s]))(男|女)(?:性|生)?(?=$|[，,；;。\s]|\d{4})"#, in: segment) { patch.sex = sex }
        if matchesPattern(#"(?:性别|性别是|性别为)\s*[:：]?\s*(?:未知|不详|不确定|不知道|不清楚)"#, in: segment) { unknown.append(.gender) }

        var expectsBirthCorrection = false
        for match in allMatches(#"(\d{4})[年./-](\d{1,2})[月./-](\d{1,2})(?:日|号)?"#, in: segment) {
            let ns = segment as NSString
            let before = ns.substring(to: match.range.location)
            let after = ns.substring(from: NSMaxRange(match.range))
            let clause = before.components(separatedBy: CharacterSet(charactersIn: "，,；;。！!\n\r")).last ?? ""
            let hasBirthCue = matchesPattern(#"(?:出生|生日|生于)"#, in: clause) || matchesPattern(#"^\s*(?:出生|生)"#, in: after)
            if matchesPattern(#"(?:不是(?:在|于)?|并非|不在|不于|误写成)\s*(?:公历|农历|阴历|阳历)?\s*[:：]?\s*$"#, in: clause) {
                expectsBirthCorrection = hasBirthCue
                continue
            }
            let directDate = matchesPattern(#"^[\s，,:：]*(?:(?:性别\s*[:：]?\s*)?[男女](?:性|生)?[\s，,:：]*)?$"#, in: before)
            let isCorrection = expectsBirthCorrection && matchesPattern(#"^\s*(?:是|为|实际是|应该是|正确的是|改成|更正为)\s*[:：]?\s*$"#, in: clause)
            if hasBirthCue || directDate || isCorrection {
                let pieces = (1...3).map { ns.substring(with: match.range(at: $0)) }
                if let year = Int(pieces[0]), let month = Int(pieces[1]), let day = Int(pieces[2]) {
                    patch.birthDate = String(format: "%04d-%02d-%02d", year, month, day)
                    break
                }
            }
            expectsBirthCorrection = false
        }
        if matchesPattern(#"(?:出生日期|生日|出生年月日)\s*(?:是|为|也)?\s*[:：]?\s*(?:未知|不详|不确定|不知道|不清楚|不记得)"#, in: segment) { unknown.append(.birthDate) }

        if let value = capture(#"(?:出生时间|出生时辰|生于|出生于|时间|时辰)\s*(?:是|为)?\s*[:：]?\s*((?:[01]?\d|2[0-3]):[0-5]\d(?::[0-5]\d)?)"#, in: segment) {
            patch.birthTime = value
        } else if patch.birthDate != nil,
                  let value = capture(#"(?:日|号|\d{4}[-/]\d{1,2}[-/]\d{1,2})\s*((?:[01]?\d|2[0-3]):[0-5]\d(?::[0-5]\d)?)"#, in: segment) {
            patch.birthTime = value
        } else if let match = firstMatch(#"(?:出生时间|出生时辰|时间|时辰)\s*(?:是|为)?\s*[:：]?\s*(上午|早上|凌晨|中午|下午|晚上)?\s*(\d{1,2})[点时](半|\d{1,2}分?)?"#, in: segment) {
            let ns = segment as NSString
            let period = match.range(at: 1).location == NSNotFound ? "" : ns.substring(with: match.range(at: 1))
            if var hour = Int(ns.substring(with: match.range(at: 2))) {
                let minuteText = match.range(at: 3).location == NSNotFound ? "" : ns.substring(with: match.range(at: 3))
                let minute = minuteText == "半" ? 30 : Int(minuteText.replacingOccurrences(of: "分", with: "")) ?? 0
                // A 1–12 clock without a period is ambiguous. Keep it for
                // conversational clarification instead of assuming morning.
                if !period.isEmpty || hour == 0 || hour >= 13 {
                    if ["下午", "晚上"].contains(period), hour < 12 { hour += 12 }
                    if ["凌晨", "晚上"].contains(period), hour == 12 { hour = 0 }
                    if period == "中午", hour < 11 { hour += 12 }
                    if hour < 24, minute < 60 { patch.birthTime = String(format: "%02d:%02d", hour, minute) }
                }
            }
        }
        if matchesPattern(#"(?:出生时间|出生时辰|时辰|具体时间|时间|几点)\s*(?:是|为|也)?\s*[:：]?\s*(?:未知|不详|不确定|不知道|不清楚|不记得|没记住)"#, in: segment) {
            patch.birthTimeKnown = false; unknown.append(.birthTime)
        }
        if retractsBirthTime(in: segment) {
            // A rejected old clock is not evidence for a known birth time.
            // A separately stated replacement can restore a precise value.
            if let replacement = capture(#"(?:实际是|实际为|正确的是|更正为|改成|改为|应该是|其实是|现在确认|确认是|[，,]\s*是)\s*[:：]?\s*((?:[01]?\d|2[0-3]):[0-5]\d(?::[0-5]\d)?)"#, in: segment) {
                patch.birthTime = replacement; patch.birthTimeKnown = true
                unknown.removeAll { $0 == .birthTime }
            } else {
                patch.birthTime = nil; patch.birthTimeKnown = false; unknown.append(.birthTime)
            }
        }

        if let value = capture(#"(?:出生时区|时区)\s*(?:是|为)?\s*[:：]?\s*([A-Za-z_]+/[A-Za-z_+/-]+|(?:UTC|GMT)(?:[+-]\d{1,2}(?::?\d{2})?)?|东八区|北京时间)"#, in: segment) { patch.birthTimeZoneID = value }
        if matchesPattern(#"(?:出生时区|时区)\s*(?:是|为|也)?\s*[:：]?\s*(?:未知|不详|不确定|不知道|不清楚|不记得)"#, in: segment) { unknown.append(.birthTimeZone) }
        if let value = capture(#"(?:出生地|出生地点|出生于|出生在)\s*(?:是|为|在)?\s*[:：]?\s*([^，,；;。\n]+)"#, in: segment) {
            let place = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if matchesPattern(#"^(?:未知|不详|不确定|不知道|不清楚|不记得)$"#, in: place) { unknown.append(.birthPlace) }
            else if !matchesPattern(#"^(?:经纬度|纬度|经度|坐标|\d|上午|下午|早上|晚上|凌晨|中午)"#, in: place) { patch.birthPlace = place }
        }
        if let latitude = capture(#"(?:出生地)?纬度\s*[:：]?\s*([+-]?\d{1,2}(?:\.\d+)?)"#, in: segment) { patch.birthLatitude = Double(latitude) }
        if let longitude = capture(#"(?:出生地)?经度\s*[:：]?\s*([+-]?\d{1,3}(?:\.\d+)?)"#, in: segment) { patch.birthLongitude = Double(longitude) }
        let english = parseEnglishFields(in: segment)
        patch.familyName = patch.familyName ?? english.familyName
        patch.givenName = patch.givenName ?? english.givenName
        patch.sex = patch.sex ?? english.sex
        patch.birthDate = patch.birthDate ?? english.birthDate
        patch.birthTime = english.birthTime ?? patch.birthTime
        patch.birthTimeKnown = patch.birthTimeKnown ?? english.birthTimeKnown
        patch.birthTimeZoneID = patch.birthTimeZoneID ?? english.birthTimeZoneID
        patch.birthPlace = patch.birthPlace ?? english.birthPlace
        unknown += english.unknownFields ?? []
        if unknown.contains(.birthTime) { patch.birthTime = nil; patch.birthTimeKnown = false }
        if !unknown.isEmpty { patch.unknownFields = Array(Set(unknown)).sorted { $0.rawValue < $1.rawValue } }
        return patch
    }

    private static func retractsBirthTime(in text: String) -> Bool {
        let birthClock = #"(?:出生(?:的)?(?:时间|时辰|时刻)|几点(?:钟)?(?:出生|生的?))"#
        let uncertain = #"(?:不知道|不清楚|不确定|不记得|记不清|忘了)"#
        let patterns = [
            uncertain + #"(?:自己|我|具体|到底|当时|是|在|的){0,3}"# + birthClock,
            birthClock + #"[^，,。；;！？?\n]{0,18}(不准|不准确|不对|有误|不能确定|不能用|不可信|作废)"#,
            #"(?:不要用|别用|不用|不能用|撤回|作废)(?:之前|原来|原先|上次|刚才|原)?(?:那个|的)?(?:出生(?:时间|时辰|时刻)|时辰|时刻)"#,
            #"(?:不要用|别用|不用|不能用)[^，,。；;！？?\n]{0,16}(?:作为|当作)?出生(?:时间|时辰|时刻)"#,
            birthClock + #"\s*(?:不是|并非)\s*(?:\d{1,2}[:点时]|[零〇一二两三四五六七八九十]{1,3}[点时])"#
        ]
        for pattern in patterns {
            for match in allMatches(pattern, in: text) {
                let source = text as NSString
                let marker = match.numberOfRanges > 1 && match.range(at: 1).location != NSNotFound
                    ? match.range(at: 1).location : match.range.location
                let before = source.substring(to: marker)
                guard !matchesPattern(#"(?:不是|并非|并不是|没说|没有说|不能说)\s*$"#, in: before) else { continue }
                return true
            }
        }
        return false
    }

    private static let englishName = #"([\p{L}][\p{L}\p{M}'’\-]*(?:[ \t]+[\p{L}][\p{L}\p{M}'’\-]*){0,5}?)"#
    private static let englishFieldBoundary = #"(?=\s*(?:[,;.!?\n\r]|$|(?:was\s+)?born\b|birth(?:day| date| time|place)?\b|date of birth\b|time of birth\b|sex\b|gender\b|time zone\b|surname\b|given name\b))"#
    private static let englishUnknown = #"(?:unknown|not known|not sure|unavailable|i (?:do not|don['’]t) (?:know|remember))"#
    private static let englishDatePattern = #"(?:\d{4}-\d{2}-\d{2}|(?:[A-Za-z]+\.?\s+\d{1,2}(?:st|nd|rd|th)?|\d{1,2}(?:st|nd|rd|th)?\s+[A-Za-z]+\.?),?\s+\d{4})\b"#
    private static let englishClockPattern = #"(?:noon|midnight|\d{1,2}(?::[0-5]\d)?(?::[0-5]\d)?\s*(?:[ap]\.?m\.?)?)(?![\p{L}\d:])"#
    private static let englishPlacePattern = #"[\p{L}][\p{L}\p{M}'’ .\-]*?(?=\s*(?:[,;.!?()\n\r]|$|\s(?:on|at|and|but)\s))"#

    private static func parseEnglishFields(in segment: String) -> ProfileUpdate {
        let text = segment.trimmingCharacters(in: .whitespacesAndNewlines)
        var patch = ProfileUpdate()
        let cues: [(OracleField, String)] = [
            (.surname, #"surname|last name|family name"#), (.givenName, #"given name|first name"#),
            (.gender, #"sex|gender"#), (.birthDate, #"birth date|birthday|date of birth"#),
            (.birthTime, #"birth time|time of birth"#), (.birthTimeZone, #"birth time zone|time zone|timezone"#),
            (.birthPlace, #"birthplace|birth place|place of birth"#)
        ]
        func field(_ cue: String) -> String { #"(?i)\b(?:"# + cue + #")\s*(?:(?:is|was)\s+|[:=]\s*|(?=\s))\s*"# }
        func fact(_ pattern: String) -> String? {
            guard let match = supportedEnglishFactMatch(pattern, in: text), match.range(at: 1).location != NSNotFound else { return nil }
            return (text as NSString).substring(with: match.range(at: 1))
        }
        let unknown = cues.compactMap { supportedEnglishFactMatch(field($0.1) + englishUnknown + #"\b"#, in: text) != nil ? $0.0 : nil }
        if !unknown.isEmpty { patch.unknownFields = unknown }
        if unknown.contains(.birthTime) { patch.birthTimeKnown = false }
        if !unknown.contains(.surname) { patch.familyName = fact(field(cues[0].1) + englishName + englishFieldBoundary) }
        if !unknown.contains(.givenName) { patch.givenName = fact(field(cues[1].1) + englishName + englishFieldBoundary) }
        if !unknown.contains(.gender), let value = fact(field(cues[2].1) + #"(male|female)\b"#)
            ?? fact(#"(?i)(?:^|[,;.!\n\r])\s*(?:and\s+)?(?:i(?: am|['’]m)\s+)?(male|female)\s*(?=[,;.!\n\r]|$)"#) {
            patch.sex = normalizedSex(value)
        }

        let birth = parseEnglishBirthStatement(in: text, dateFieldCue: field(cues[3].1))
        if !EnglishConversation.isLunarDate(text), !unknown.contains(.birthDate) {
            let value = fact(field(cues[3].1) + "(" + englishDatePattern + ")")
            patch.birthDate = value.flatMap { normalizedDate($0) ?? englishDate($0) } ?? birth.birthDate
        }
        if !unknown.contains(.birthTime) {
            let value = fact(field(cues[4].1) + "(" + englishClockPattern + ")")
            patch.birthTime = value.flatMap(englishClock) ?? birth.birthTime
        }
        if let zone = fact(field(cues[5].1) + #"([A-Za-z_]+(?:/[A-Za-z_+\-]+)+|(?:UTC|GMT)(?:[+-]\d{1,2}(?::?\d{2})?)?)\b"#) {
            patch.birthTimeZoneID = normalizedTimeZone(zone)
        }
        if !unknown.contains(.birthPlace),
           let place = englishPlaceMatch(after: field(cues[6].1), in: text)?.place ?? birth.birthPlace,
           !EnglishConversation.matches(place, "^" + englishUnknown + "$") { patch.birthPlace = place }
        return patch
    }

    private static func supportedEnglishFactMatch(_ pattern: String, in text: String) -> NSTextCheckingResult? {
        let source = text as NSString
        return allMatches(pattern, in: text).first { match in
            let before = source.substring(to: match.range.location)
            let clause = before.components(separatedBy: CharacterSet(charactersIn: ";.!?\n\r")).last ?? ""
            return !EnglishConversation.introducesOtherPerson(clause)
                && !EnglishConversation.matches(clause, #"['’]s\s+(?:friend|partner|spouse|sister|brother|mother|father|child|colleague)\b|\b(?:not|never|wasn['’]t|weren['’]t|isn['’]t|might|maybe|possibly|probably|could|unsure|uncertain)\b|\bmay\s+(?:have|be)\b"#)
        }
    }

    private static func hasEnglishDistrictQualifier(_ place: String) -> Bool {
        EnglishConversation.matches(place, #"\b(?:district|new area|county)\b|[区區县縣]"#)
    }

    /// Preserve a district's comma-separated city/province qualifiers. A city
    /// alone keeps the existing short form; independent field or subject clauses
    /// terminate the location rather than becoming part of its administrative path.
    private static func englishPlaceMatch(after prefix: String, in text: String) -> (place: String, end: Int)? {
        guard let first = supportedEnglishFactMatch(prefix + "(" + englishPlacePattern + ")", in: text) else { return nil }
        let source = text as NSString
        let original = source.substring(with: first.range(at: 1))
        var parts = [original]
        var end = NSMaxRange(first.range)
        while end < source.length {
            let tail = source.substring(from: end)
            guard let next = firstMatch(#"^\s*,\s*("# + englishPlacePattern + ")", in: tail) else { break }
            let component = (tail as NSString).substring(with: next.range(at: 1))
            guard !EnglishConversation.matches(component, #"\b(?:i|my|we|our|he|his|she|her|they|their|now|currently|live|living|work|working|born|birth|male|female|gender|sex|timezone|time|on|at|and|but|please|thanks|thank|unknown|not)\b"#) else { break }
            parts.append(component)
            end += NSMaxRange(next.range)
            if parts.count > 8 { return nil }
        }
        let hasDistrict = parts.contains(where: hasEnglishDistrictQualifier)
        return hasDistrict ? (parts.joined(separator: ", "), end) : (original, NSMaxRange(first.range))
    }

    /// Keep date, clock and place attached to one affirmative birth statement.
    /// Only adjacent on/at/in phrases may extend it; later work or event details
    /// and another person's birth statement cannot supply its missing fields.
    private static func parseEnglishBirthStatement(in text: String, dateFieldCue: String) -> ProfileUpdate {
        let source = text as NSString
        for match in allMatches(#"(?i)(?:\bborn\s+|"# + dateFieldCue + ")", in: text) {
            let before = source.substring(to: match.range.location)
            let clause = before.components(separatedBy: CharacterSet(charactersIn: ";.!?\n\r")).last ?? ""
            guard !EnglishConversation.introducesOtherPerson(clause),
                  !EnglishConversation.matches(clause, #"\b(?:not|never|wasn['’]t|weren['’]t|isn['’]t|might|maybe|possibly|probably|could|unsure|uncertain)\b|\bmay\s+(?:have|be)\b"#) else { continue }
            var remainder = source.substring(from: NSMaxRange(match.range))
            var patch = ProfileUpdate()
            let prefix = #"(?i)^\s*(?:,\s*)?"#
            for _ in 0..<3 {
                let pattern: String
                let field: OracleField
                if patch.birthDate == nil, firstMatch(prefix + #"(?:on\s+)?("# + englishDatePattern + ")", in: remainder) != nil {
                    pattern = prefix + #"(?:on\s+)?("# + englishDatePattern + ")"; field = .birthDate
                } else if patch.birthTime == nil, firstMatch(prefix + #"at\s+("# + englishClockPattern + ")", in: remainder) != nil {
                    pattern = prefix + #"at\s+("# + englishClockPattern + ")"; field = .birthTime
                } else {
                    if patch.birthPlace != nil { break }
                    guard let place = englishPlaceMatch(after: prefix + #"in\s+"#, in: remainder) else { break }
                    patch.birthPlace = place.place
                    remainder = (remainder as NSString).substring(from: place.end)
                    continue
                }
                guard let value = firstMatch(pattern, in: remainder) else { break }
                let ns = remainder as NSString
                let raw = ns.substring(with: value.range(at: 1))
                switch field {
                case .birthDate: patch.birthDate = normalizedDate(raw) ?? englishDate(raw)
                case .birthTime: patch.birthTime = englishClock(raw)
                case .birthPlace: patch.birthPlace = raw
                default: break
                }
                remainder = ns.substring(from: NSMaxRange(value.range))
            }
            if hasFacts(patch) { return patch }
        }
        return ProfileUpdate()
    }

    private static func englishDate(_ text: String) -> String? {
        let clean = text.replacingOccurrences(of: #"(?i)(?<=\d)(?:st|nd|rd|th)\b|[.,]"#, with: "", options: .regularExpression)
        let input = DateFormatter(); input.locale = Locale(identifier: "en_US_POSIX")
        input.timeZone = .gmt; input.calendar = Calendar(identifier: .gregorian)
        input.isLenient = false
        for pattern in ["MMMM d yyyy", "d MMMM yyyy", "MMM d yyyy", "d MMM yyyy"] {
            input.dateFormat = pattern
            if let date = input.date(from: clean) { return format(date, zone: "UTC", pattern: "yyyy-MM-dd") }
        }
        return nil
    }

    static func englishClock(_ raw: String) -> String? {
        let clean = raw.lowercased().filter { !$0.isWhitespace && $0 != "." }
        if clean == "noon" { return "12:00" }
        if clean == "midnight" { return "00:00" }
        guard let match = firstMatch(#"^(\d{1,2})(?::([0-5]\d))?(?::([0-5]\d))?(am|pm)?$"#, in: clean) else { return nil }
        let source = clean as NSString
        func part(_ index: Int) -> String? { match.range(at: index).location == NSNotFound ? nil : source.substring(with: match.range(at: index)) }
        guard let hours = part(1), var hour = Int(hours) else { return nil }
        let minute = part(2)
        if let period = part(4) {
            guard (1...12).contains(hour) else { return nil }
            hour = hour % 12 + (period == "pm" ? 12 : 0)
        } else if minute == nil || (1...12).contains(hour) && !hours.hasPrefix("0") { return nil }
        guard hour < 24 else { return nil }
        return String(format: "%02d:%02d", hour, minute.flatMap(Int.init) ?? 0) + (part(3).map { ":" + $0 } ?? "")
    }

    /// A self binding requires a direct declaration and a name boundary. In
    /// particular, "我是张三的朋友" is not a declaration that the user is 张三.
    static func explicitSelfName(in text: String, profiles: [OracleProfile]) -> String? {
        let source = text as NSString
        for match in allMatches(#"(?i)(?:^|[,;.!?\n\r])\s*(?:my name is|i am|i['’]m)\s+"# + englishName + englishFieldBoundary, in: text) {
            guard let name = normalizedName(source.substring(with: match.range(at: 1))), isPlausibleName(name),
                  !EnglishConversation.matches(name, #"^(?:a|an|the|not|from|currently|just|sure|unsure|doing|looking|trying|asking|wondering)\b|\b(?:friend|relative|sister|brother|partner|colleague)\b"#) else { continue }
            let declaration = source.substring(with: match.range)
            if EnglishConversation.matches(declaration, #"(?:^|[,;.!?\n\r])\s*my name is\b"#)
                || profiles.contains(where: { $0.resolvedName == name }) { return name }
        }
        let pattern = #"(?:我叫|我是)\s*([^，,；;。！？!?:：\n\r]+?)(?=$|[，,；;。！？!?:：\n\r])"#
        guard let raw = capture(pattern, in: text), let name = normalizedName(raw), isPlausibleName(name),
              matchesPattern(#"^(?:[\p{Han}]{2,6}|[A-Za-z][A-Za-z' -]{0,47})$"#, in: name),
              !name.contains("的"), !name.hasSuffix("呀"), !name.hasSuffix("啊") else { return nil }
        return name
    }

    private static let selfFactPrefix = #"^\s*(?:我(?:自己)?(?:的)?|本人(?:的)?)\s*(?=出生|生日|性别|时区|姓氏|名字|(?:不(?:知道|清楚|确定|记得)|记不清|忘了).{0,8}(?:几点(?:出生|生)|出生.{0,3}(?:时间|时辰)))"#

    private static let englishSelfFactPrefix = #"(?i)^\s*(?:my\s+(?=birth(?:day| date| time|place)?|date of birth|time of birth|sex|gender|time zone|surname|given name)|i\s+(?:was\s+)?(?=born))"#

    static func hasExplicitSelfFacts(in text: String) -> Bool {
        text.components(separatedBy: CharacterSet(charactersIn: "，,；;。！？!?\n\r")).contains {
            matchesPattern(selfFactPrefix, in: $0) || matchesPattern(englishSelfFactPrefix, in: $0)
        }
    }

    /// A bound speaker may supply their own facts in a separate clause. Do not
    /// apply the clause to a previous named person or to an unbound profile.
    static func explicitSelfUpdates(in text: String, profiles: [OracleProfile], selfProfileID: UUID?) -> [ProfileUpdate] {
        guard let id = selfProfileID, let selfProfile = profiles.first(where: { $0.id == id }) else { return [] }
        let name = normalizedName(selfProfile.resolvedName)
        if let declaration = explicitSelfName(in: text, profiles: profiles), declaration != name { return [] }
        let source = text as NSString
        return allMatches(#"[^，,；;。！？!?\n\r]+[，,；;。！？!?]?"#, in: text).flatMap { range -> [ProfileUpdate] in
            let clause = source.substring(with: range.range)
            guard !clause.hasSuffix("？"), !clause.hasSuffix("?"),
                  !matchesPattern(#"(?:是不是|是否|可能是|好像是|大概是|对不对)"#, in: clause) else { return [] }
            guard let match = clause.range(of: selfFactPrefix, options: .regularExpression)
                ?? clause.range(of: englishSelfFactPrefix, options: .regularExpression) else { return [] }
            let fact = String(clause[match.upperBound...])
            guard let name else { return parseContextualFields(in: fact, for: id) }
            return parseExplicitUpdates(in: "\(name)，\(fact)", profiles: [selfProfile]).compactMap { update in
                guard update.name == name, hasFacts(update) else { return nil }
                var scoped = update
                scoped.id = id
                return scoped
            }
        }
    }

    /// Grounds model patches in this message, one named person at a time. An AI
    /// cannot fill absent facts from defaults, another person's clause or its
    /// own interpretation. Omitted names bind only to one explicit context ID.
    static func groundedUpdates(_ updates: [ProfileUpdate], in text: String, profiles: [OracleProfile], contextIDs: [UUID] = []) -> [ProfileUpdate] {
        let local = parseExplicitUpdates(in: text, profiles: profiles)
        let anchors = nameAnchors(in: text, profiles: profiles)
        let independentNameTokens = Set(text.components(separatedBy: CharacterSet(charactersIn: "、，,；;\n\r和与")).compactMap(normalizedName))
        let singleContext = Set(contextIDs).count == 1 && !EnglishConversation.introducesOtherPerson(text)
            ? profiles.first { $0.id == contextIDs.first } : nil
        var grounded: [ProfileUpdate] = []
        for update in updates.prefix(20) {
            let existing = update.id.flatMap { id in profiles.first { $0.id == id } }
            if update.id != nil, existing == nil { continue }
            var name = normalizedName(update.name) ?? normalizedName(existing?.resolvedName)
            var contextBound = false
            if name == nil, let context = singleContext, anchors.isEmpty {
                name = normalizedName(context.resolvedName); contextBound = true
            }
            guard let name else { continue }
            let explicitlyNamed = anchors.contains { $0.name == name }
            // Only an AI-proposed name can use this identity-only fallback.
            // Bare text is not independently turned into a local profile patch.
            let bareIdentity = isPlausibleName(name) && (normalizedName(text) == name || independentNameTokens.contains(name))
            if !explicitlyNamed && !bareIdentity {
                guard let context = singleContext, anchors.isEmpty,
                      normalizedName(context.resolvedName) == name,
                      update.id == nil || update.id == context.id else { continue }
                contextBound = true
            }
            var evidence = contextBound
                ? parseExplicitUpdates(in: name + "，" + text, profiles: profiles).filter { $0.name == name }
                : local.filter { $0.name == name }
            if contextBound, let singleContext {
                // The caller has identified the owner of this otherwise unbound
                // response. Keep an explicit self-owned clause separate from
                // the synthetic name used to parse ordinary field answers.
                evidence += explicitSelfUpdates(in: text, profiles: profiles, selfProfileID: singleContext.id)
                let bare = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if matchesPattern(#"^\d{2}:[0-5]\d(?::[0-5]\d)?$"#, in: bare), let time = normalizedTime(bare) {
                    evidence.append(ProfileUpdate(name: name, birthTime: time))
                } else if TimeZone.knownTimeZoneIdentifiers.contains(bare), let zone = normalizedTimeZone(bare) {
                    evidence.append(ProfileUpdate(name: name, birthTimeZoneID: zone))
                }
            }
            guard !evidence.isEmpty || bareIdentity else { continue }
            var patch = ProfileUpdate(name: name)
            let matches = profiles.filter { normalizedName($0.resolvedName) == name }
            if let context = singleContext, contextBound { patch.id = context.id }
            else if matches.count == 1 { patch.id = matches.first?.id }
            else if let id = update.id,
                    (!bareIdentity || normalizedName(existing?.resolvedName) == name),
                    (Set(contextIDs) == Set([id]) || text.localizedCaseInsensitiveContains(id.uuidString)) { patch.id = id }

            if let family = update.familyName?.trimmingCharacters(in: .whitespacesAndNewlines),
               evidence.contains(where: { $0.familyName == family }) { patch.familyName = family }
            if let given = update.givenName?.trimmingCharacters(in: .whitespacesAndNewlines),
               evidence.contains(where: { $0.givenName == given }) { patch.givenName = given }
            if let sex = update.sex, evidence.contains(where: { normalizedSex($0.sex) == normalizedSex(sex) && $0.sex != nil }) { patch.sex = sex }
            if let date = update.birthDate, evidence.contains(where: { $0.birthDate == date }) { patch.birthDate = date }
            if let time = update.birthTime,
               let normalized = normalizedTime(time), evidence.contains(where: { canonicalClock($0.birthTime) == canonicalClock(time) }) { patch.birthTime = normalized }
            if let known = update.birthTimeKnown,
               evidence.contains(where: { known ? $0.birthTime != nil : $0.birthTimeKnown == false }) { patch.birthTimeKnown = known }
            if let zone = update.birthTimeZoneID, let normalized = normalizedTimeZone(zone),
               evidence.contains(where: { $0.birthTimeZoneID.flatMap(normalizedTimeZone) == normalized }) { patch.birthTimeZoneID = normalized }
            if let place = update.birthPlace?.trimmingCharacters(in: .whitespacesAndNewlines), !place.isEmpty {
                let proposedDistrict = ChinaDistrictCatalog.shared.matchingDistrict(for: place)
                if let supplied = evidence.compactMap(\.birthPlace).first(where: { supplied in
                    let suppliedDistrict = ChinaDistrictCatalog.shared.matchingDistrict(for: supplied)
                    if let proposedDistrict { return suppliedDistrict?.id == proposedDistrict.id }
                    if hasEnglishDistrictQualifier(supplied), suppliedDistrict == nil { return supplied == place }
                    return supplied.contains(place)
                }) {
                    // Keep the explicit district when a model repeats only its
                    // city or normalizes the same district to another language.
                    patch.birthPlace = ChinaDistrictCatalog.shared.matchingDistrict(for: supplied)?.fullName ?? place
                }
            }
            if let latitude = update.birthLatitude, evidence.contains(where: { $0.birthLatitude == latitude }) { patch.birthLatitude = latitude }
            if let longitude = update.birthLongitude, evidence.contains(where: { $0.birthLongitude == longitude }) { patch.birthLongitude = longitude }
            let explicitUnknown = Set(evidence.flatMap { $0.unknownFields ?? [] })
            let verifiedUnknown = (update.unknownFields ?? []).filter { explicitUnknown.contains($0) }
            if !verifiedUnknown.isEmpty { patch.unknownFields = verifiedUnknown }
            // A deliberate name-only declaration may create an otherwise empty
            // profile. A bare reference in a question must not become a patch.
            if hasFacts(patch) || bareIdentity || evidence.contains(where: { !hasFacts($0) }) { grounded.append(patch) }
        }
        return grounded
    }

    private static func applyFields(_ update: ProfileUpdate, to profile: inout OracleProfile, issues: inout [ProfileDirectoryIssue]) {
        let original = profile
        var explicitUnknown = Set(update.unknownFields ?? [])
        if explicitUnknown.contains(.birthPlace) { explicitUnknown.insert(.birthCoordinates) }
        let birthFields: Set<OracleField> = [.birthDate, .birthTime, .birthTimeZone]
        var patchesBirth = !explicitUnknown.isDisjoint(with: birthFields)
        func invalid(_ field: String) {
            issues.append(.init(kind: .invalidValue, name: normalizedName(profile.resolvedName), message: L10n.text("\(profile.participantLabel)的\(field)格式无效，已保留原资料。", "The \(field) format for \(profile.participantLabel) is invalid. The previous value was kept.")))
        }
        // Preserve wall-clock text from old archives before changing any zone.
        var dateText = profile.birthDateText ?? profile.birthDate.map { format($0, zone: profile.birthTimeZoneID, pattern: "yyyy-MM-dd") }
        var timeText = profile.birthTimeText ?? (profile.birthTimeKnown ? profile.birthDate.map { format($0, zone: profile.birthTimeZoneID, pattern: "HH:mm:ss") } : nil)
        var appliedFamilyName = false, appliedGivenName = false
        if let family = update.familyName?.trimmingCharacters(in: .whitespacesAndNewlines) {
            if (1...4).contains(family.count) {
                profile.familyName = family; profile.unknownFields.remove(.surname); appliedFamilyName = true
            } else { invalid(L10n.text("姓氏", "family name")) }
        }
        if let given = update.givenName?.trimmingCharacters(in: .whitespacesAndNewlines) {
            if (1...4).contains(given.count) {
                profile.givenName = given; profile.unknownFields.remove(.givenName); appliedGivenName = true
            } else { invalid(L10n.text("名字", "given name")) }
        }
        if let sex = update.sex {
            switch sex.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "男", "男性", "男生", "male": profile.sex = "男"; profile.unknownFields.remove(.gender)
            case "女", "女性", "女生", "female": profile.sex = "女"; profile.unknownFields.remove(.gender)
            case "未知", "不详", "不确定", "未提供": profile.sex = "未提供"; profile.unknownFields.insert(.gender)
            default: invalid(L10n.text("性别", "chart sex"))
            }
        }
        if let value = update.birthDate {
            if let normalized = normalizedDate(value) { dateText = normalized; profile.unknownFields.remove(.birthDate); patchesBirth = true }
            else { invalid(L10n.text("出生日期", "birth date")) }
        }
        if let value = update.birthTime {
            if let normalized = normalizedTime(value) {
                timeText = normalized; profile.birthTimeKnown = true; profile.unknownFields.remove(.birthTime)
                patchesBirth = true
            } else { invalid(L10n.text("出生时间", "birth time")) }
        }
        if let known = update.birthTimeKnown {
            if known, timeText != nil { profile.birthTimeKnown = true; profile.unknownFields.remove(.birthTime); patchesBirth = true }
            else if !known { timeText = nil; profile.birthTimeKnown = false; profile.unknownFields.insert(.birthTime); patchesBirth = true }
        }
        if let value = update.birthTimeZoneID {
            if let zone = normalizedTimeZone(value) { profile.birthTimeZoneID = zone; profile.unknownFields.remove(.birthTimeZone); patchesBirth = true }
            else { invalid(L10n.text("出生时区", "birth time zone")) }
        }
        if let place = update.birthPlace?.trimmingCharacters(in: .whitespacesAndNewlines), !place.isEmpty {
            let district = ChinaDistrictCatalog.shared.matchingDistrict(for: place)
            let canonical = district?.fullName ?? place
            if profile.birthDistrictCode != nil, profile.birthPlace != canonical {
                profile.birthDistrictCode = nil
                profile.birthLatitude = nil; profile.birthLongitude = nil
                profile.unknownFields.insert(.birthCoordinates)
            }
            if let district {
                if profile.birthDistrictCode != district.id {
                    profile.birthLatitude = district.latitude; profile.birthLongitude = district.longitude
                } else {
                    profile.birthLatitude = profile.birthLatitude ?? district.latitude
                    profile.birthLongitude = profile.birthLongitude ?? district.longitude
                }
                profile.birthDistrictCode = district.id
            }
            profile.birthPlace = canonical; profile.unknownFields.remove(.birthPlace)
        }
        if let latitude = update.birthLatitude {
            if latitude.isFinite, (-90...90).contains(latitude) { profile.birthLatitude = latitude }
            else { invalid(L10n.text("出生地纬度", "birth latitude")) }
        }
        if let longitude = update.birthLongitude {
            if longitude.isFinite, (-180...180).contains(longitude) { profile.birthLongitude = longitude }
            else { invalid(L10n.text("出生地经度", "birth longitude")) }
        }
        if profile.birthLatitude != nil, profile.birthLongitude != nil { profile.unknownFields.remove(.birthCoordinates) }
        profile.unknownFields.formUnion(explicitUnknown)
        var declared = profile.declaredUnknownFields ?? original.unknownFields
        declared.formUnion(explicitUnknown)
        if appliedFamilyName && !explicitUnknown.contains(.surname) { declared.remove(.surname) }
        if appliedGivenName && !explicitUnknown.contains(.givenName) { declared.remove(.givenName) }
        if update.sex != nil && !explicitUnknown.contains(.gender) { declared.remove(.gender) }
        if update.birthDate != nil && !explicitUnknown.contains(.birthDate) { declared.remove(.birthDate) }
        if profile.birthTimeKnown, timeText != nil, !profile.unknownFields.contains(.birthTime) { declared.remove(.birthTime) }
        if update.birthTimeKnown == false { declared.insert(.birthTime) }
        if update.birthTimeZoneID != nil && !explicitUnknown.contains(.birthTimeZone) { declared.remove(.birthTimeZone) }
        if update.birthPlace != nil && !explicitUnknown.contains(.birthPlace) { declared.remove(.birthPlace) }
        if update.birthLatitude != nil && update.birthLongitude != nil && !explicitUnknown.contains(.birthCoordinates) { declared.remove(.birthCoordinates) }
        if explicitUnknown.contains(.name) { profile.name = nil; profile.displayName = "" }
        if explicitUnknown.contains(.surname) { profile.familyName = "" }
        if explicitUnknown.contains(.givenName) { profile.givenName = "" }
        if explicitUnknown.contains(.gender) { profile.sex = "未提供" }
        if explicitUnknown.contains(.birthPlace) { profile.birthPlace = ""; profile.birthDistrictCode = nil }
        if explicitUnknown.contains(.birthCoordinates) { profile.birthLatitude = nil; profile.birthLongitude = nil }
        if explicitUnknown.contains(.currentLocation) {
            profile.currentPlace = ""
            profile.currentDistrictCode = nil
            profile.currentLatitude = nil; profile.currentLongitude = nil
            profile.currentTimeZoneID = OracleProfile.defaultChinaTimeZoneID
        }
        if patchesBirth {
            if profile.unknownFields.contains(.birthDate) { dateText = nil }
            // Older empty profiles defaulted birthTimeKnown to true even when
            // no date/time had ever been entered. Adding a birthday must not
            // turn the internal noon storage anchor into a claimed birth time.
            if timeText == nil || !profile.birthTimeKnown {
                profile.birthTimeKnown = false; profile.unknownFields.insert(.birthTime)
            }
            if profile.unknownFields.contains(.birthTime) { timeText = nil; profile.birthTimeKnown = false }
            if explicitUnknown.contains(.birthTimeZone) { profile.birthTimeZoneID = OracleProfile.defaultChinaTimeZoneID }
            profile.birthDateText = dateText
            profile.birthTimeText = timeText
            if let dateText {
                let time = profile.birthTimeKnown ? timeText : nil
                if let rebuilt = calendarDate(date: dateText, time: time ?? "12:00", zone: profile.birthTimeZoneID) { profile.birthDate = rebuilt }
                else {
                    invalid(L10n.text("出生日期与时间", "birth date and time"))
                    profile.birthDate = original.birthDate; profile.birthDateText = original.birthDateText
                    profile.birthTimeText = original.birthTimeText; profile.birthTimeKnown = original.birthTimeKnown
                    profile.birthTimeZoneID = original.birthTimeZoneID
                    profile.unknownFields.subtract(birthFields)
                    profile.unknownFields.formUnion(original.unknownFields.intersection(birthFields))
                    declared.subtract(birthFields)
                    declared.formUnion((original.declaredUnknownFields ?? original.unknownFields).intersection(birthFields))
                }
            } else { profile.birthDate = nil }
        }
        profile.declaredUnknownFields = declared
    }

    private struct NameAnchor { var name: String; var range: NSRange; var explicitName: Bool }

    private static func nameAnchors(in text: String, profiles: [OracleProfile], routing: Bool = false) -> [NameAnchor] {
        var anchors: [NameAnchor] = []
        let ns = text as NSString
        let knownNames = Set(profiles.compactMap { normalizedName($0.resolvedName) })
        for name in knownNames {
            for match in allMatches(NSRegularExpression.escapedPattern(for: name), in: text) {
                guard knownNameHasBoundaries(match.range, in: text, routing: routing) else { continue }
                anchors.append(.init(name: name, range: match.range, explicitName: false))
            }
        }
        let name = #"([\p{Han}]{2,6}?|[A-Za-z][A-Za-z' -]{0,47}?)"#
        let boundary = #"(?=$|[，,；;。！？\n\r\s0-9]|(?:的)?(?:出生|生日|性别|时区|姓氏|名字))"#
        let patterns: [(String, Bool)] = [
            (#"(?:姓名(?!\s*五格)|名字|名叫|我叫|他叫|她叫|叫做|我是|记住|记下|记录|保存|新增|添加|补充|更新)\s*(?:是|为)?\s*[:：]?\s*"# + name + boundary, true),
            (#"(?i)(?:^|[,;.!?\n\r])\s*(?:name\s*[:=]\s*|my name is\s+|i am\s+|i['’]m\s+)"# + englishName + englishFieldBoundary, true),
            (#"(?i)(?:^|[;.!?\n\r]|,\s*and\b)\s*"# + englishName
                + #"(?=\s*(?:['’]s)?\s*[:,]?\s*(?:(?:was\s+)?born\b|birth(?:day| date| time|place)?\b|date of birth\b|time of birth\b|sex\b|gender\b|time zone\b|surname\b|given name\b))"#, false),
            (#"(?:^|[，,；;。\n\r]|和|与|及)\s*"# + name + #"(?=\s*[，,:：\s]*(?:(?:的)?(?:出生|生日|性别|时区|姓氏|名字)|[男女](?:性|生)?(?:[，,；;。\s]|\d)|\d{4}[年./-]))"#, false)
        ]
        for (pattern, explicitName) in patterns {
            for match in allMatches(pattern, in: text) {
                let range = match.range(at: 1)
                guard let value = normalizedName(ns.substring(with: range)), isPlausibleName(value) else { continue }
                // Once a saved name has a verified boundary, do not swallow
                // following correction words into a longer inferred identity.
                if !explicitName, anchors.contains(where: {
                    knownNames.contains($0.name) && $0.range.location == range.location && $0.range.length < range.length
                }) { continue }
                let cue = ns.substring(with: NSRange(location: match.range.location, length: range.location - match.range.location))
                if EnglishConversation.matches(cue, #"\bi(?: am|['’]m)\s*$"#), explicitSelfName(in: text, profiles: profiles) != value { continue }
                anchors.append(.init(name: value, range: range, explicitName: explicitName))
            }
        }
        // Once a person is identified in a clause, a subsequent "名字" field
        // is the separately supplied given name, not another person's identity.
        let allAnchors = anchors
        anchors.removeAll { anchor in
            let before = ns.substring(to: anchor.range.location)
            guard let label = firstMatch(#"名字\s*(?:是|为)?\s*[:：]?\s*$"#, in: before) else { return false }
            return allAnchors.contains { earlier in
                guard NSMaxRange(earlier.range) <= label.range.location else { return false }
                let between = ns.substring(with: NSRange(location: NSMaxRange(earlier.range), length: label.range.location - NSMaxRange(earlier.range)))
                return between.rangeOfCharacter(from: CharacterSet(charactersIn: "；;。\n\r")) == nil
            }
        }
        anchors.sort { $0.range.location == $1.range.location ? $0.range.length > $1.range.length : $0.range.location < $1.range.location }
        var accepted: [NameAnchor] = []
        for anchor in anchors {
            if let last = accepted.last, NSIntersectionRange(last.range, anchor.range).length > 0 {
                if last.range == anchor.range, anchor.explicitName { accepted[accepted.count - 1].explicitName = true }
                continue
            }
            accepted.append(anchor)
        }
        return accepted
    }

    private static func knownNameHasBoundaries(_ range: NSRange, in text: String, routing: Bool) -> Bool {
        let source = text as NSString
        let before = source.substring(to: range.location)
        let after = source.substring(from: NSMaxRange(range))
        if let next = after.first, matchesPattern(#"^\p{Han}$"#, in: String(next)) {
            var cues = ["的", "和", "与", "及", "跟", "同", "出生", "生日", "生于", "性别", "时区", "时间", "工作", "事业", "感情", "婚姻", "财运", "运势", "健康", "姓名", "姓氏", "名字", "关系", "合盘", "合婚", "最近", "今年", "明年", "未来", "接下来", "能否", "是否", "怎么样", "如何", "情况", "一起", "共同", "想", "要", "是", "为", "不是", "并非"]
            if routing { cues += ["了", "呢", "下周", "这周", "下个月", "这几天", "能不能", "会不会", "合不合", "合适", "适合", "适不适合", "合伙", "相处", "这个名字", "这个笔名", "当笔名", "作为笔名", "换成", "改成", "换掉", "替换为", "先不看", "不看", "不算", "不问"] }
            let retractsOwnBirthTime = matchesPattern(#"^(?:不(?:知道|清楚|确定|记得)|记不清|忘了)(?:自己|具体|到底|当时|是|在|的){0,3}(?:几点(?:钟)?(?:出生|生的?)|出生(?:的)?(?:时间|时辰|时刻))"#, in: after)
                || matchesPattern(#"^(?:不要用|别用|不用|不能用|撤回|作废)"#, in: after)
                    && retractsBirthTime(in: after)
                    && !matchesPattern(#"^(?:不要用|别用|不用|不能用)[^，,。；;！？?\n]{0,12}(?:我|他|她|别人|朋友)的(?:出生|时间|时辰|时刻)"#, in: after)
            guard cues.contains(where: after.hasPrefix) || retractsOwnBirthTime else { return false }
        } else if let next = after.first, next.isLetter { return false }
        if let previous = before.last, matchesPattern(#"^\p{Han}$"#, in: String(previous)) {
            var cues = ["我叫", "我是", "名叫", "他叫", "她叫", "叫做", "姓名", "名字", "请看", "看看", "关于", "补充", "更新", "记录", "记住", "记下", "保存", "新增", "添加", "还有", "以及", "和", "与", "及", "跟", "同", "给", "为", "替", "对", "问", "是", "叫", "让"]
            if routing { cues += ["换成", "改成", "改看", "改问", "改算", "换", "看", "算", "看一下", "问一下", "算一下", "把", "将", "并非", "不用", "不要", "朋友", "同事", "同学", "对象", "伴侣", "家人", "爸爸", "妈妈", "父亲", "母亲", "孩子", "儿子", "女儿"] }
            guard cues.contains(where: before.hasSuffix) else { return false }
        } else if let previous = before.last, previous.isLetter { return false }
        return true
    }

    private static func isPlausibleName(_ name: String) -> Bool {
        guard (2...48).contains(name.count), !name.contains("的"),
              !["资料", "信息", "档案", "数据"].contains(name),
              !["在", "于", "是", "为", "要", "想", "会", "将", "这个", "那个"].contains(where: name.hasSuffix),
              !["补充", "更新", "新增", "添加"].contains(where: name.hasPrefix) else { return false }
        let excluded = ["本人", "自己", "朋友", "家人", "对象", "父亲", "母亲", "爸爸", "妈妈", "孩子", "同事", "同学", "老师", "先生", "女士", "小姐", "出生", "生日", "时间", "日期", "性别", "姓名", "姓氏", "名字", "笔名", "时区", "不确定", "不知道", "不详", "未知", "请", "帮我", "今年", "现在", "住在", "来自", "记住", "记录", "保存", "我叫", "我是", "他的", "她的", "我的"]
        return !excluded.contains(where: name.contains)
            && !EnglishConversation.matches(name, #"^(?:i|me|myself|my|he|she|they|was|is|were|did|could|might|maybe|birth|born|unknown|not sure|date|time|name|gender|sex|hello|thanks|thank you|yes|no)\b"#)
    }

    private static func normalizedName(_ value: String?) -> String? {
        guard let value else { return nil }
        let name = value.split(whereSeparator: \.isWhitespace).joined(separator: " ").precomposedStringWithCanonicalMapping
        return name.isEmpty || name.count > 80 || ["我", "本人", "自己", "他人", "他人资料", "我的资料", "未知", "未提供"].contains(name) ? nil : name
    }

    private static func hasFacts(_ update: ProfileUpdate) -> Bool {
        update.familyName != nil || update.givenName != nil || update.sex != nil || update.birthDate != nil || update.birthTime != nil || update.birthTimeKnown != nil || update.birthTimeZoneID != nil || update.birthPlace != nil || update.birthLatitude != nil || update.birthLongitude != nil || !(update.unknownFields ?? []).isEmpty
    }

    private static func normalizedSex(_ value: String?) -> String? {
        switch value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "男", "男性", "男生", "male": "男"
        case "女", "女性", "女生", "female": "女"
        default: value
        }
    }

    private static func normalizedDate(_ value: String) -> String? {
        guard matchesPattern(#"^\d{4}-\d{2}-\d{2}$"#, in: value),
              calendarDate(date: value, time: "12:00", zone: "UTC") != nil else { return nil }
        return value
    }

    private static func normalizedTime(_ value: String) -> String? {
        guard let match = firstMatch(#"^(\d{1,2}):([0-5]\d)(?::([0-5]\d))?$"#, in: value) else { return nil }
        let ns = value as NSString
        guard let hour = Int(ns.substring(with: match.range(at: 1))), hour < 24,
              let minute = Int(ns.substring(with: match.range(at: 2))) else { return nil }
        if match.range(at: 3).location != NSNotFound {
            return String(format: "%02d:%02d:%02d", hour, minute, Int(ns.substring(with: match.range(at: 3))) ?? 0)
        }
        return String(format: "%02d:%02d", hour, minute)
    }

    private static func canonicalClock(_ value: String?) -> String? {
        guard let value, let normalized = normalizedTime(value) else { return nil }
        return normalized.count == 5 ? normalized + ":00" : normalized
    }

    private static func normalizedTimeZone(_ value: String) -> String? {
        let raw = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if ["东八区", "北京时间"].contains(raw) { return "Asia/Shanghai" }
        if let zone = TimeZone(identifier: raw) { return zone.identifier }
        if let match = firstMatch(#"^(?:UTC|GMT)([+-])(\d{1,2})(?::?(\d{2}))?$"#, in: raw) {
            let ns = raw as NSString
            guard let hour = Int(ns.substring(with: match.range(at: 2))), hour <= 14 else { return nil }
            let minute = match.range(at: 3).location == NSNotFound ? 0 : Int(ns.substring(with: match.range(at: 3))) ?? 0
            guard minute < 60, hour < 14 || minute == 0 else { return nil }
            let sign = ns.substring(with: match.range(at: 1)) == "-" ? -1 : 1
            return TimeZone(secondsFromGMT: sign * (hour * 3600 + minute * 60))?.identifier
        }
        return nil
    }

    private static func calendarDate(date: String, time: String, zone: String) -> Date? {
        let day = date.split(separator: "-").compactMap { Int($0) }
        let clock = time.split(separator: ":").compactMap { Int($0) }
        guard day.count == 3, (1...9999).contains(day[0]), clock.count >= 2, let zone = TimeZone(identifier: zone) else { return nil }
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = zone
        let components = DateComponents(year: day[0], month: day[1], day: day[2], hour: clock[0], minute: clock[1], second: clock.count == 3 ? clock[2] : 0)
        guard let result = calendar.date(from: components) else { return nil }
        let verified = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: result)
        guard verified.year == components.year, verified.month == components.month, verified.day == components.day,
              verified.hour == components.hour, verified.minute == components.minute, verified.second == components.second else { return nil }
        return result
    }

    private static func format(_ date: Date, zone: String, pattern: String) -> String {
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(identifier: zone) ?? TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = pattern
        return formatter.string(from: date)
    }

    private static func allMatches(_ pattern: String, in text: String) -> [NSTextCheckingResult] {
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return [] }
        return expression.matches(in: text, range: NSRange(location: 0, length: (text as NSString).length))
    }
    private static func firstMatch(_ pattern: String, in text: String) -> NSTextCheckingResult? { allMatches(pattern, in: text).first }
    private static func matchesPattern(_ pattern: String, in text: String) -> Bool { firstMatch(pattern, in: text) != nil }
    private static func capture(_ pattern: String, in text: String) -> String? {
        guard let match = firstMatch(pattern, in: text), match.numberOfRanges > 1, match.range(at: 1).location != NSNotFound else { return nil }
        return (text as NSString).substring(with: match.range(at: 1))
    }
}

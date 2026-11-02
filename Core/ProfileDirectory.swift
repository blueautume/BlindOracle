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
    static func applying(_ updates: [ProfileUpdate], to profiles: [OracleProfile]) -> ProfileMergeResult {
        var result = ProfileMergeResult(profiles: profiles, appliedIDs: [], issues: [])
        for update in updates.prefix(20) {
            let suppliedName = normalizedName(update.name)
            let index: Int
            if let id = update.id {
                guard let found = result.profiles.firstIndex(where: { $0.id == id }) else {
                    result.issues.append(.init(kind: .unknownID, name: suppliedName, message: "没有找到这个档案编号，未自动新建或覆盖。"))
                    continue
                }
                index = found
            } else {
                guard let suppliedName else {
                    result.issues.append(.init(kind: .missingName, name: nil, message: "请明确这份资料对应的姓名，未自动存入任何人的档案。"))
                    continue
                }
                let matches = result.profiles.indices.filter { normalizedName(result.profiles[$0].resolvedName) == suppliedName }
                guard matches.count <= 1 else {
                    result.issues.append(.init(kind: .ambiguousName, name: suppliedName,
                        message: "有多位同名的\(suppliedName)，请先确认要补充哪一份档案。",
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
            guard suppliedName != nil || normalizedName(profile.resolvedName) != nil else {
                result.issues.append(.init(kind: .missingName, name: nil, message: "档案仍没有姓名，未写入这次补充。"))
                continue
            }
            if let suppliedName {
                if let oldName = normalizedName(profile.resolvedName), oldName != suppliedName {
                    profile.familyName = ""; profile.givenName = ""
                    profile.unknownFields.formUnion([.surname, .givenName])
                }
                profile.name = suppliedName
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
                    message: "有多位同名的\(name)，请先确认参与的是哪一位。", candidateIDs: matches.map(\.id)))
            } else {
                result.issues.append(.init(kind: .missingName, name: name, message: "还没有\(name)的档案，请先提供其姓名与所需资料。"))
            }
        }
        return result
    }

    /// Uses the same name boundaries as profile extraction. A saved 李四 is
    /// not selected merely because the question mentions 李四海.
    static func referencedNames(in text: String, profiles: [OracleProfile]) -> [String] {
        let knownNames = Set(profiles.compactMap { normalizedName($0.resolvedName) })
        var seen = Set<String>()
        return nameAnchors(in: text, profiles: profiles).compactMap { anchor in
            guard knownNames.contains(anchor.name), seen.insert(anchor.name).inserted else { return nil }
            return anchor.name
        }
    }

    /// Conservative offline grammar: named demographic statements only. It does
    /// not bind pronouns or infer sex, birth place, birth time or birth time zone.
    static func parseExplicitUpdates(in text: String, profiles: [OracleProfile]) -> [ProfileUpdate] {
        let source = text as NSString
        let anchors = nameAnchors(in: text, profiles: profiles)
        var updates: [ProfileUpdate] = []
        for (index, anchor) in anchors.enumerated() {
            let end = index + 1 < anchors.count ? anchors[index + 1].range.location : source.length
            let segment = source.substring(with: NSRange(location: NSMaxRange(anchor.range), length: max(0, end - NSMaxRange(anchor.range))))
            var patch = ProfileUpdate(name: anchor.name)
            let matches = profiles.filter { normalizedName($0.resolvedName) == anchor.name }
            if matches.count == 1 { patch.id = matches.first?.id }
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

            if let match = firstMatch(#"(\d{4})[年./-](\d{1,2})[月./-](\d{1,2})(?:日|号)?"#, in: segment) {
                let ns = segment as NSString
                let before = ns.substring(to: match.range.location)
                let after = ns.substring(from: NSMaxRange(match.range))
                let hasBirthCue = matchesPattern(#"(?:出生|生日|生于)"#, in: before) || matchesPattern(#"^\s*(?:出生|生)"#, in: after)
                let directDate = matchesPattern(#"^[\s，,:：]*(?:(?:性别\s*[:：]?\s*)?[男女](?:性|生)?[\s，,:：]*)?$"#, in: before)
                if hasBirthCue || directDate {
                    let pieces = (1...3).map { ns.substring(with: match.range(at: $0)) }
                    if let year = Int(pieces[0]), let month = Int(pieces[1]), let day = Int(pieces[2]) {
                        patch.birthDate = String(format: "%04d-%02d-%02d", year, month, day)
                    }
                }
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

            if let value = capture(#"(?:出生时区|时区)\s*(?:是|为)?\s*[:：]?\s*([A-Za-z_]+/[A-Za-z_+/-]+|(?:UTC|GMT)(?:[+-]\d{1,2}(?::?\d{2})?)?|东八区|北京时间)"#, in: segment) { patch.birthTimeZoneID = value }
            if matchesPattern(#"(?:出生时区|时区)\s*(?:是|为|也)?\s*[:：]?\s*(?:未知|不详|不确定|不知道|不清楚|不记得)"#, in: segment) { unknown.append(.birthTimeZone) }
            if let value = capture(#"(?:出生地|出生地点|出生于|出生在)\s*(?:是|为|在)?\s*[:：]?\s*([^，,；;。\n]+)"#, in: segment) {
                let place = value.trimmingCharacters(in: .whitespacesAndNewlines)
                if matchesPattern(#"^(?:未知|不详|不确定|不知道|不清楚|不记得)$"#, in: place) { unknown.append(.birthPlace) }
                else if !matchesPattern(#"^(?:经纬度|纬度|经度|坐标|\d|上午|下午|早上|晚上|凌晨|中午)"#, in: place) { patch.birthPlace = place }
            }
            if let latitude = capture(#"(?:出生地)?纬度\s*[:：]?\s*([+-]?\d{1,2}(?:\.\d+)?)"#, in: segment) { patch.birthLatitude = Double(latitude) }
            if let longitude = capture(#"(?:出生地)?经度\s*[:：]?\s*([+-]?\d{1,3}(?:\.\d+)?)"#, in: segment) { patch.birthLongitude = Double(longitude) }
            if !unknown.isEmpty { patch.unknownFields = Array(Set(unknown)).sorted { $0.rawValue < $1.rawValue } }
            if anchor.explicitName || hasFacts(patch) {
                updates.append(patch)
            }
        }
        return updates
    }

    /// A self binding requires a direct declaration and a name boundary. In
    /// particular, "我是张三的朋友" is not a declaration that the user is 张三.
    static func explicitSelfName(in text: String, profiles: [OracleProfile]) -> String? {
        let pattern = #"(?:我叫|我是)\s*([^，,；;。！？!?:：\n\r]+?)(?=$|[，,；;。！？!?:：\n\r])"#
        guard let raw = capture(pattern, in: text), let name = normalizedName(raw), isPlausibleName(name),
              matchesPattern(#"^(?:[\p{Han}]{2,6}|[A-Za-z][A-Za-z' -]{0,47})$"#, in: name),
              !name.contains("的"), !name.hasSuffix("呀"), !name.hasSuffix("啊") else { return nil }
        return name
    }

    /// Grounds model patches in this message, one named person at a time. An AI
    /// cannot fill absent facts from defaults, another person's clause or its
    /// own interpretation. Omitted names bind only to one explicit context ID.
    static func groundedUpdates(_ updates: [ProfileUpdate], in text: String, profiles: [OracleProfile], contextIDs: [UUID] = []) -> [ProfileUpdate] {
        let local = parseExplicitUpdates(in: text, profiles: profiles)
        let anchors = nameAnchors(in: text, profiles: profiles)
        let independentNameTokens = Set(text.components(separatedBy: CharacterSet(charactersIn: "、，,；;\n\r和与")).compactMap(normalizedName))
        let singleContext = Set(contextIDs).count == 1 ? profiles.first { $0.id == contextIDs.first } : nil
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
            if contextBound {
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
            if let place = update.birthPlace?.trimmingCharacters(in: .whitespacesAndNewlines), !place.isEmpty,
               evidence.contains(where: { $0.birthPlace?.contains(place) == true }) { patch.birthPlace = place }
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
        let explicitUnknown = Set(update.unknownFields ?? [])
        let birthFields: Set<OracleField> = [.birthDate, .birthTime, .birthTimeZone]
        var patchesBirth = !explicitUnknown.isDisjoint(with: birthFields)
        func invalid(_ field: String) {
            issues.append(.init(kind: .invalidValue, name: normalizedName(profile.resolvedName), message: "\(profile.resolvedName)的\(field)格式无效，已保留原资料。"))
        }
        // Preserve wall-clock text from old archives before changing any zone.
        var dateText = profile.birthDateText ?? profile.birthDate.map { format($0, zone: profile.birthTimeZoneID, pattern: "yyyy-MM-dd") }
        var timeText = profile.birthTimeText ?? (profile.birthTimeKnown ? profile.birthDate.map { format($0, zone: profile.birthTimeZoneID, pattern: "HH:mm:ss") } : nil)
        var appliedFamilyName = false, appliedGivenName = false
        if let family = update.familyName?.trimmingCharacters(in: .whitespacesAndNewlines) {
            if (1...4).contains(family.count) {
                profile.familyName = family; profile.unknownFields.remove(.surname); appliedFamilyName = true
            } else { invalid("姓氏") }
        }
        if let given = update.givenName?.trimmingCharacters(in: .whitespacesAndNewlines) {
            if (1...4).contains(given.count) {
                profile.givenName = given; profile.unknownFields.remove(.givenName); appliedGivenName = true
            } else { invalid("名字") }
        }
        if let sex = update.sex {
            switch sex.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "男", "男性", "男生", "male": profile.sex = "男"; profile.unknownFields.remove(.gender)
            case "女", "女性", "女生", "female": profile.sex = "女"; profile.unknownFields.remove(.gender)
            case "未知", "不详", "不确定", "未提供": profile.sex = "未提供"; profile.unknownFields.insert(.gender)
            default: invalid("性别")
            }
        }
        if let value = update.birthDate {
            if let normalized = normalizedDate(value) { dateText = normalized; profile.unknownFields.remove(.birthDate); patchesBirth = true }
            else { invalid("出生日期") }
        }
        if let value = update.birthTime {
            if let normalized = normalizedTime(value) {
                timeText = normalized; profile.birthTimeKnown = true; profile.unknownFields.remove(.birthTime)
                patchesBirth = true
            } else { invalid("出生时间") }
        }
        if let known = update.birthTimeKnown {
            if known, timeText != nil { profile.birthTimeKnown = true; profile.unknownFields.remove(.birthTime); patchesBirth = true }
            else if !known { timeText = nil; profile.birthTimeKnown = false; profile.unknownFields.insert(.birthTime); patchesBirth = true }
        }
        if let value = update.birthTimeZoneID {
            if let zone = normalizedTimeZone(value) { profile.birthTimeZoneID = zone; profile.unknownFields.remove(.birthTimeZone); patchesBirth = true }
            else { invalid("出生时区") }
        }
        if let place = update.birthPlace?.trimmingCharacters(in: .whitespacesAndNewlines), !place.isEmpty {
            profile.birthPlace = place; profile.unknownFields.remove(.birthPlace)
        }
        if let latitude = update.birthLatitude {
            if latitude.isFinite, (-90...90).contains(latitude) { profile.birthLatitude = latitude }
            else { invalid("出生地纬度") }
        }
        if let longitude = update.birthLongitude {
            if longitude.isFinite, (-180...180).contains(longitude) { profile.birthLongitude = longitude }
            else { invalid("出生地经度") }
        }
        if profile.birthLatitude != nil, profile.birthLongitude != nil { profile.unknownFields.remove(.birthCoordinates) }
        profile.unknownFields.formUnion(explicitUnknown)
        var declared = profile.declaredUnknownFields ?? original.unknownFields
        declared.formUnion(explicitUnknown)
        if appliedFamilyName && !explicitUnknown.contains(.surname) { declared.remove(.surname) }
        if appliedGivenName && !explicitUnknown.contains(.givenName) { declared.remove(.givenName) }
        if update.sex != nil && !explicitUnknown.contains(.gender) { declared.remove(.gender) }
        if update.birthDate != nil && !explicitUnknown.contains(.birthDate) { declared.remove(.birthDate) }
        if update.birthTime != nil && !explicitUnknown.contains(.birthTime) { declared.remove(.birthTime) }
        if update.birthTimeKnown == false { declared.insert(.birthTime) }
        if update.birthTimeZoneID != nil && !explicitUnknown.contains(.birthTimeZone) { declared.remove(.birthTimeZone) }
        if update.birthPlace != nil && !explicitUnknown.contains(.birthPlace) { declared.remove(.birthPlace) }
        if update.birthLatitude != nil && update.birthLongitude != nil && !explicitUnknown.contains(.birthCoordinates) { declared.remove(.birthCoordinates) }
        profile.declaredUnknownFields = declared
        if explicitUnknown.contains(.surname) { profile.familyName = "" }
        if explicitUnknown.contains(.givenName) { profile.givenName = "" }
        if explicitUnknown.contains(.gender) { profile.sex = "未提供" }
        if explicitUnknown.contains(.birthPlace) { profile.birthPlace = "" }
        if explicitUnknown.contains(.birthCoordinates) { profile.birthLatitude = nil; profile.birthLongitude = nil }
        if patchesBirth {
            if profile.unknownFields.contains(.birthDate) { dateText = nil }
            // Older empty profiles defaulted birthTimeKnown to true even when
            // no date/time had ever been entered. Adding a birthday must not
            // turn the internal noon storage anchor into a claimed birth time.
            if timeText == nil || !profile.birthTimeKnown {
                profile.birthTimeKnown = false; profile.unknownFields.insert(.birthTime)
            }
            if profile.unknownFields.contains(.birthTime) { timeText = nil; profile.birthTimeKnown = false }
            if profile.unknownFields.contains(.birthTimeZone) { profile.birthTimeZoneID = "UTC" }
            profile.birthDateText = dateText
            profile.birthTimeText = timeText
            if let dateText {
                let time = profile.birthTimeKnown ? timeText : nil
                if let rebuilt = calendarDate(date: dateText, time: time ?? "12:00", zone: profile.birthTimeZoneID) { profile.birthDate = rebuilt }
                else {
                    invalid("出生日期与时间")
                    profile.birthDate = original.birthDate; profile.birthDateText = original.birthDateText
                    profile.birthTimeText = original.birthTimeText; profile.birthTimeKnown = original.birthTimeKnown
                    profile.birthTimeZoneID = original.birthTimeZoneID
                    profile.unknownFields.subtract(birthFields)
                    profile.unknownFields.formUnion(original.unknownFields.intersection(birthFields))
                }
            } else { profile.birthDate = nil }
        }
    }

    private struct NameAnchor { var name: String; var range: NSRange; var explicitName: Bool }

    private static func nameAnchors(in text: String, profiles: [OracleProfile]) -> [NameAnchor] {
        var anchors: [NameAnchor] = []
        let ns = text as NSString
        for name in Set(profiles.compactMap { normalizedName($0.resolvedName) }) {
            for match in allMatches(NSRegularExpression.escapedPattern(for: name), in: text) {
                guard knownNameHasBoundaries(match.range, in: text) else { continue }
                anchors.append(.init(name: name, range: match.range, explicitName: false))
            }
        }
        let name = #"([\p{Han}]{2,6}?|[A-Za-z][A-Za-z' -]{0,47}?)"#
        let boundary = #"(?=$|[，,；;。！？\n\r\s0-9]|(?:的)?(?:出生|生日|性别|时区|姓氏|名字))"#
        let patterns: [(String, Bool)] = [
            (#"(?:姓名|名字|名叫|我叫|他叫|她叫|叫做|我是|记住|记下|记录|保存|新增|添加|补充|更新)\s*(?:是|为)?\s*[:：]?\s*"# + name + boundary, true),
            (#"(?:^|[，,；;。\n\r]|和|与|及)\s*"# + name + #"(?=\s*[，,:：\s]*(?:(?:的)?(?:出生|生日|性别|时区|姓氏|名字)|[男女](?:性|生)?(?:[，,；;。\s]|\d)|\d{4}[年./-]))"#, false)
        ]
        for (pattern, explicitName) in patterns {
            for match in allMatches(pattern, in: text) {
                let range = match.range(at: 1)
                guard let value = normalizedName(ns.substring(with: range)), isPlausibleName(value) else { continue }
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

    private static func knownNameHasBoundaries(_ range: NSRange, in text: String) -> Bool {
        let source = text as NSString
        let before = source.substring(to: range.location)
        let after = source.substring(from: NSMaxRange(range))
        if let next = after.first, matchesPattern(#"^\p{Han}$"#, in: String(next)) {
            let cues = ["的", "和", "与", "及", "跟", "同", "出生", "生日", "生于", "性别", "时区", "时间", "工作", "事业", "感情", "婚姻", "财运", "运势", "健康", "姓名", "姓氏", "名字", "关系", "合盘", "合婚", "最近", "今年", "明年", "未来", "接下来", "能否", "是否", "怎么样", "如何", "情况", "一起", "共同", "想", "要", "是", "为"]
            guard cues.contains(where: after.hasPrefix) else { return false }
        } else if let next = after.first, next.isLetter { return false }
        if let previous = before.last, matchesPattern(#"^\p{Han}$"#, in: String(previous)) {
            let cues = ["我叫", "我是", "名叫", "他叫", "她叫", "叫做", "姓名", "名字", "请看", "看看", "关于", "补充", "更新", "记录", "记住", "记下", "保存", "新增", "添加", "还有", "以及", "和", "与", "及", "跟", "同", "给", "为", "替", "对", "问", "是", "叫", "让"]
            guard cues.contains(where: before.hasSuffix) else { return false }
        } else if let previous = before.last, previous.isLetter { return false }
        return true
    }

    private static func isPlausibleName(_ name: String) -> Bool {
        guard (2...48).contains(name.count), !name.contains("的"),
              !["资料", "信息", "档案", "数据"].contains(name),
              !["在", "于", "是", "为", "要", "想", "会", "将"].contains(where: name.hasSuffix),
              !["补充", "更新", "新增", "添加"].contains(where: name.hasPrefix) else { return false }
        let excluded = ["本人", "自己", "朋友", "家人", "对象", "父亲", "母亲", "爸爸", "妈妈", "孩子", "同事", "同学", "老师", "先生", "女士", "小姐", "出生", "生日", "时间", "日期", "性别", "姓名", "姓氏", "名字", "时区", "不确定", "不知道", "不详", "未知", "请", "帮我", "今年", "现在", "住在", "来自", "记住", "记录", "保存", "我叫", "我是", "他的", "她的", "我的"]
        return !excluded.contains(where: name.contains)
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

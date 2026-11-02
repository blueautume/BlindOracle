import Foundation

enum OraclePreparationStage: String, Codable, Sendable { case collecting, confirming }

struct OracleMethodOmission: Codable, Equatable, Sendable {
    var method: OracleMethod
    var reason: String
    var participantID: UUID? = nil
    var participantName: String? = nil
}

enum PreparationGapState: String, Codable, Sendable {
    case unspecified, explicitlyUnknown, invalid
}

struct PreparationGap: Codable, Equatable, Sendable {
    var field: OracleField
    var state: PreparationGapState
    var reason: String
}

struct ReadingMethodAssessment: Codable, Equatable, Sendable {
    var method: OracleMethod
    var participantID: UUID?
    var participantName: String?
    var blocking: [PreparationGap]
    var optionalGaps: [PreparationGap]
    var limitations: [String]
    var unavailableReason: String? = nil
    var requiresUserInteraction = false
    var canExecute: Bool { blocking.isEmpty && unavailableReason == nil }
}

struct PreparationPersonMissing: Codable, Equatable, Sendable {
    var participantID: UUID?
    var participantName: String?
    var blocking: [PreparationGap] = []
    var optionalGaps: [PreparationGap] = []
    var fields: [OracleField] { blocking.map(\.field) }
    var optionalFields: [OracleField] { optionalGaps.map(\.field) }
    var explicitlyUnknownFields: [OracleField] {
        (blocking + optionalGaps).filter { $0.state == .explicitlyUnknown }.map(\.field)
    }
}

struct PreparationQuestion: Codable, Equatable, Identifiable, Sendable {
    var participantID: UUID?
    var participantName: String?
    var field: OracleField
    var text: String
    var id: String { (participantID?.uuidString ?? "unselected-person") + ":" + field.rawValue }
}

struct ReadingPreparationReport: Sendable {
    var assessments: [ReadingMethodAssessment]
    var missing: [PreparationPersonMissing]
    /// Empty while any mandatory method is blocked. Per-person feasibility is
    /// still available in assessments so an optional method can omit one person.
    var runnableMethods: [OracleMethod]
    var omissions: [OracleMethodOmission]
    var blockedMandatoryMethods: [OracleMethod]
    var questions: [PreparationQuestion]
    var summary: String
    var strictBlocked: Bool { !blockedMandatoryMethods.isEmpty }
    /// Permission to continue to review/confirmation and required interactions,
    /// not permission to bypass the existing card/coin interaction validation.
    var canProceed: Bool { !strictBlocked && !runnableMethods.isEmpty }
}

/// Pure profile readiness policy. Data and glyph-table installation, the casting
/// instant, actual card selections and coin responses remain runtime checks.
enum ReadingPreparationPolicy {
    static func evaluate(plan: OraclePlan, participants: [OracleProfile], descriptors: [OraclePluginDescriptor],
                         explicitlyUnknownFields: [UUID: Set<OracleField>] = [:]) -> ReadingPreparationReport {
        let mandatory = Set(plan.mandatoryMethods ?? [])
        // A malformed plan cannot silently drop a user-mandated method.
        let requested = Set(plan.methods).union(mandatory)
        let methods = OracleMethod.allCases.filter { requested.contains($0) }
        var seenPeople = Set<UUID>()
        let people = participants.filter { seenPeople.insert($0.id).inserted }
        var assessments: [ReadingMethodAssessment] = []
        for method in methods {
            let descriptor = descriptors.first { $0.method == method }
            let targets: [OracleProfile?] = method.usesPersonalProfile ? (people.isEmpty ? [nil] : people.map(Optional.some)) : [nil]
            for person in targets {
                let interaction = method == .tarot || method == .liuyao || (plan.interactions ?? []).contains { $0.method == method }
                var assessment = ReadingMethodAssessment(method: method, participantID: person?.id,
                    participantName: person.flatMap { $0.resolvedName.isEmpty ? nil : $0.resolvedName },
                    blocking: [], optionalGaps: [], limitations: [], requiresUserInteraction: interaction)
                guard let descriptor else {
                    assessment.unavailableReason = "\(method.progressName)尚未加载，本次不能调用。"
                    assessments.append(assessment); continue
                }
                guard method.usesPersonalProfile else {
                    assessments.append(assessment); continue
                }
                guard let person else {
                    assessment.blocking = [.init(field: .name, state: .unspecified, reason: "尚未明确要使用谁的资料。")]
                    assessments.append(assessment); continue
                }
                let declared = explicitlyUnknownFields[person.id] ?? person.declaredUnknownFields ?? person.unknownFields
                var required = hardRequirements(for: method)
                if mandatory.contains(method) { required.formUnion(descriptor.requiredFields) }
                // Named selection is an application-level identity requirement;
                // an anonymous placeholder is never substituted for a person.
                required.insert(.name)
                for field in orderedFields where required.contains(field) {
                    if let gap = gap(for: field, person: person, declaredUnknown: declared) { assessment.blocking.append(gap) }
                }
                let timeAvailable = gap(for: .birthTime, person: person, declaredUnknown: declared) == nil
                for field in optionalRequirements(for: method, timeAvailable: timeAvailable) where !required.contains(field) {
                    if let gap = gap(for: field, person: person, declaredUnknown: declared) { assessment.optionalGaps.append(gap) }
                }
                assessment.limitations = partialLimitations(method: method, person: person, optionalGaps: assessment.optionalGaps)
                assessments.append(assessment)
            }
        }
        let blockedMandatory = methods.filter { method in
            mandatory.contains(method) && assessments.contains { $0.method == method && !$0.canExecute }
        }
        let available = methods.filter { method in assessments.contains { $0.method == method && $0.canExecute } }
        let runnable = blockedMandatory.isEmpty ? available : []
        let omissions = assessments.filter { !$0.canExecute && !mandatory.contains($0.method) }.map { assessment in
            OracleMethodOmission(method: assessment.method,
                reason: assessment.unavailableReason ?? assessment.blocking.map(\.reason).joined(separator: "；"),
                participantID: assessment.participantID, participantName: assessment.participantName)
        }
        let missing = groupMissing(assessments)
        let questions = missing.flatMap { person in
            // Required questions precede improvements that allow partial output.
            (person.blocking + person.optionalGaps).filter { $0.state != .explicitlyUnknown }.map { gap in
                PreparationQuestion(participantID: person.participantID, participantName: person.participantName,
                    field: gap.field, text: question(for: gap, name: person.participantName))
            }
        }
        let summary = summary(plan: plan, people: people, assessments: assessments, runnable: runnable,
                              omissions: omissions, blockedMandatory: blockedMandatory)
        return ReadingPreparationReport(assessments: assessments, missing: missing, runnableMethods: runnable,
            omissions: omissions, blockedMandatoryMethods: blockedMandatory, questions: questions, summary: summary)
    }

    private static let orderedFields: [OracleField] = [.name, .birthDate, .birthTimeZone, .birthTime, .gender,
        .surname, .givenName, .birthCoordinates, .birthPlace, .currentLocation, .numbers]

    /// Mirrors the actual calculate guards rather than treating every catalog
    /// field or AI-requested plan.requiredFields value as an absolute blocker.
    private static func hardRequirements(for method: OracleMethod) -> Set<OracleField> {
        switch method {
        case .bazi, .chenggu, .astrology: [.birthDate, .birthTimeZone]
        case .ziwei: [.birthDate, .birthTime, .gender, .birthTimeZone]
        case .xingming: [.surname, .givenName]
        default: []
        }
    }

    private static func optionalRequirements(for method: OracleMethod, timeAvailable: Bool) -> [OracleField] {
        switch method {
        case .bazi: timeAvailable ? [.birthTime, .gender] : [.birthTime]
        case .chenggu: [.birthTime]
        case .astrology: timeAvailable ? [.birthTime, .birthCoordinates] : [.birthTime]
        // Place text is not used by Ziwei's numerical guards. Asking for it
        // cannot replace the separately confirmed time zone.
        default: []
        }
    }

    private static func gap(for field: OracleField, person: OracleProfile, declaredUnknown: Set<OracleField>) -> PreparationGap? {
        if declaredUnknown.contains(field) { return .init(field: field, state: .explicitlyUnknown, reason: "\(field.title)已明确为不确定。") }
        if person.unknownFields.contains(field) { return .init(field: field, state: .unspecified, reason: "\(field.title)尚未确认。") }
        func missing() -> PreparationGap { .init(field: field, state: .unspecified, reason: "\(field.title)尚未提供。") }
        func invalid(_ reason: String) -> PreparationGap { .init(field: field, state: .invalid, reason: reason) }
        switch field {
        case .name: return person.resolvedName.isEmpty ? missing() : nil
        case .birthDate:
            guard let date = person.birthDate else { return missing() }
            guard date.timeIntervalSince1970.isFinite else { return invalid("出生日期无效，尚不能排盘。") }
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(identifier: person.birthTimeZoneID) ?? TimeZone(secondsFromGMT: 0)!
            return (1900...2100).contains(calendar.component(.year, from: date)) ? nil : invalid("出生日期超出当前支持的1900–2100年范围。")
        case .birthTimeZone:
            guard !person.birthTimeZoneID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return missing() }
            return TimeZone(identifier: person.birthTimeZoneID) == nil ? invalid("出生地时区无效，不能用出生地名称或默认时区代替。") : nil
        case .birthTime:
            guard person.birthTimeKnown else { return missing() }
            if let text = person.birthTimeText {
                guard let expression = try? NSRegularExpression(pattern: #"^(?:[01]\d|2[0-3]):[0-5]\d(?::[0-5]\d)?$"#),
                      expression.firstMatch(in: text, range: NSRange(location: 0, length: (text as NSString).length)) != nil else {
                    return invalid("出生时间格式无效，请使用00:00至23:59的当地时间。")
                }
                return nil
            }
            return person.birthDate == nil ? missing() : nil // Legacy Date includes a known local time.
        case .gender:
            if ["男", "女"].contains(person.sex) { return nil }
            return ["", "未提供", "未知", "不确定"].contains(person.sex) ? missing() : invalid("排盘性别尚未确认成当前算法支持的值。")
        case .surname, .givenName:
            let value = (field == .surname ? person.familyName : person.givenName).trimmingCharacters(in: .whitespacesAndNewlines)
            if value.isEmpty { return missing() }
            return value.count <= 4 ? nil : invalid("\(field.title)需分别提供1至4个字，未自动拆分统一姓名。")
        case .birthCoordinates:
            guard let latitude = person.birthLatitude, let longitude = person.birthLongitude else { return missing() }
            return latitude.isFinite && longitude.isFinite && (-90...90).contains(latitude) && (-180...180).contains(longitude)
                ? nil : invalid("出生经纬度无效，只能保留不依赖宫位的星位结果。")
        case .birthPlace: return person.birthPlace.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? missing() : nil
        case .currentLocation: return person.currentPlace.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? missing() : nil
        case .numbers: return missing() // Collected by the existing interaction session, not the profile.
        }
    }

    private static func partialLimitations(method: OracleMethod, person: OracleProfile, optionalGaps: [PreparationGap]) -> [String] {
        let missing = Set(optionalGaps.map(\.field))
        switch method {
        case .bazi:
            var limits: [String] = []
            if missing.contains(.birthTime) { limits.append("出生时辰未确定，仅保留前三柱及必要候选，不输出起运与大运。") }
            else if missing.contains(.gender) { limits.append("排盘性别未确定，本次不输出起运与大运。") }
            return limits
        case .chenggu:
            return missing.contains(.birthTime) ? ["出生时辰未确定，只列可能骨重范围，不选定某一首评诗。"] : []
        case .astrology:
            if missing.contains(.birthTime) { return ["出生时刻未确定，只列全天星位区间，不输出宫位、上升点与精确相位。"] }
            if missing.contains(.birthCoordinates) { return ["出生坐标未完整确认，保留星位及相位，不计算上升点与宫位。"] }
            if let latitude = person.birthLatitude, abs(latitude) >= 66 { return ["出生地位于高纬度，本版本不计算宫位。"] }
            return []
        default: return []
        }
    }

    private static func groupMissing(_ assessments: [ReadingMethodAssessment]) -> [PreparationPersonMissing] {
        var groups: [PreparationPersonMissing] = []
        for assessment in assessments where !assessment.blocking.isEmpty || !assessment.optionalGaps.isEmpty {
            let index: Int
            if let found = groups.firstIndex(where: { $0.participantID == assessment.participantID }) { index = found }
            else {
                groups.append(.init(participantID: assessment.participantID, participantName: assessment.participantName))
                index = groups.count - 1
            }
            for gap in assessment.blocking {
                if !groups[index].blocking.contains(where: { $0.field == gap.field }) { groups[index].blocking.append(gap) }
                groups[index].optionalGaps.removeAll { $0.field == gap.field }
            }
            for gap in assessment.optionalGaps where !groups[index].blocking.contains(where: { $0.field == gap.field }) && !groups[index].optionalGaps.contains(where: { $0.field == gap.field }) {
                groups[index].optionalGaps.append(gap)
            }
        }
        for index in groups.indices {
            groups[index].blocking.sort { fieldIndex($0.field) < fieldIndex($1.field) }
            groups[index].optionalGaps.sort { fieldIndex($0.field) < fieldIndex($1.field) }
        }
        return groups
    }

    private static func fieldIndex(_ field: OracleField) -> Int { orderedFields.firstIndex(of: field) ?? orderedFields.count }

    private static func question(for gap: PreparationGap, name: String?) -> String {
        let subject = name.map { $0 + "的" } ?? "这次要使用资料的人的"
        switch gap.field {
        case .name: return "这次要为谁问事？请先告诉我姓名。"
        case .birthDate: return "\(subject)公历出生日期是哪一天？"
        case .birthTimeZone: return "\(subject)出生地采用哪个时区？请明确时区；不确定也可以直接说明。"
        case .birthTime: return "\(subject)当地出生时间是几点？不记得具体时刻也可以说明。"
        case .gender: return "\(subject)排盘性别是男还是女？不确定可说明。"
        case .surname: return "请确认\(subject)姓氏部分，先不自动拆姓名。"
        case .givenName: return "请确认\(subject)名字部分。"
        case .birthCoordinates: return "\(subject)出生地经纬度是否已知？不确定时可以只保留不依赖宫位的部分。"
        default: return "请补充或确认\(subject)\(gap.field.title)。"
        }
    }

    private static func summary(plan: OraclePlan, people: [OracleProfile], assessments: [ReadingMethodAssessment], runnable: [OracleMethod],
                                omissions: [OracleMethodOmission], blockedMandatory: [OracleMethod]) -> String {
        var lines = ["所问：\(plan.question)"]
        for person in people {
            let gaps = assessments.filter { $0.participantID == person.id }.flatMap { $0.blocking + $0.optionalGaps }
            let unavailableFields = Set(gaps.map(\.field))
            let date = person.unknownFields.contains(.birthDate) || unavailableFields.contains(.birthDate) ? "出生日期未确定" : (person.birthDateText ?? person.birthDate.map { dateText($0, zone: person.birthTimeZoneID) } ?? "出生日期未提供")
            let time = person.birthTimeKnown && !person.unknownFields.contains(.birthTime) && !unavailableFields.contains(.birthTime)
                ? (person.birthTimeText ?? person.birthDate.map { dateText($0, zone: person.birthTimeZoneID, format: "HH:mm") } ?? "出生时间未提供") : "出生时间未确定"
            let zone = person.unknownFields.contains(.birthTimeZone) || unavailableFields.contains(.birthTimeZone) ? "出生时区未确定" : person.birthTimeZoneID
            let gender = ["男", "女"].contains(person.sex) && !person.unknownFields.contains(.gender) && !unavailableFields.contains(.gender) ? person.sex : "排盘性别未确定"
            let place = person.birthPlace.isEmpty || person.unknownFields.contains(.birthPlace) || unavailableFields.contains(.birthPlace) ? "" : "，出生地\(person.birthPlace)"
            lines.append("\(person.resolvedName.isEmpty ? "姓名未确认" : person.resolvedName)：\(date)，\(time)，\(zone)，\(gender)\(place)。")
        }
        if !blockedMandatory.isEmpty { lines.append("指定的\(blockedMandatory.map(\.progressName).joined(separator: "、"))资料尚未齐全，暂不开始，也不改用其他方法。") }
        else if !runnable.isEmpty { lines.append("可使用：\(runnable.map(\.progressName).joined(separator: "、"))。") }
        for assessment in assessments where assessment.canExecute {
            for limitation in assessment.limitations { lines.append((assessment.participantName.map { $0 + " · " } ?? "") + assessment.method.progressName + "：" + limitation) }
        }
        for omission in omissions { lines.append("暂不纳入" + (omission.participantName.map { $0 + "的" } ?? "") + omission.method.progressName + "：" + omission.reason) }
        return lines.joined(separator: "\n")
    }

    private static func dateText(_ date: Date, zone: String, format: String = "yyyy-MM-dd") -> String {
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: zone) ?? TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = format
        return formatter.string(from: date)
    }
}

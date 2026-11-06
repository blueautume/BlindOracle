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
                         explicitlyUnknownFields: [UUID: Set<OracleField>] = [:],
                         castingProfile: OracleProfile? = nil, numbers: [Int]? = nil) -> ReadingPreparationReport {
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
                    participantName: person?.participantLabel,
                    blocking: [], optionalGaps: [], limitations: [], requiresUserInteraction: interaction)
                guard let descriptor else {
                    assessment.unavailableReason = L10n.text("\(method.progressName)尚未加载，本次不能调用。", "\(method.progressName) is unavailable.")
                    assessments.append(assessment); continue
                }
                guard method.usesPersonalProfile else {
                    if requiresCastingLocation(method: method, numbers: numbers ?? plan.draftNumbers ?? []),
                       let gap = castingLocationGap(castingProfile ?? plan.castingProfile) {
                        assessment.blocking.append(gap)
                    }
                    assessments.append(assessment); continue
                }
                guard let person else {
                    assessment.blocking = [.init(field: .name, state: .unspecified, reason: L10n.text("尚未明确要使用谁的资料。", "Choose whose details to use for this reading."))]
                    assessments.append(assessment); continue
                }
                let declared = explicitlyUnknownFields[person.id] ?? person.declaredUnknownFields ?? person.unknownFields
                var required = hardRequirements(for: method)
                if mandatory.contains(method) { required.formUnion(descriptor.requiredFields) }
                for field in orderedFields where required.contains(field) {
                    if [.bazi, .ziwei, .chenggu].contains(method), field == .birthCoordinates {
                        if let gap = birthCoordinateGap(person: person, declaredUnknown: declared) { assessment.blocking.append(gap) }
                        continue
                    }
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
        var available = methods.filter { method in assessments.contains { $0.method == method && $0.canExecute } }
        if mandatory.isEmpty, available.isEmpty, descriptors.contains(where: { $0.method == .xiaoliuren }) {
            let gaps = castingLocationGap(castingProfile ?? plan.castingProfile).map { [$0] } ?? []
            if gaps.isEmpty { available.append(.xiaoliuren) }
            if !assessments.contains(where: { $0.method == .xiaoliuren }) {
                assessments.append(.init(method: .xiaoliuren, participantID: nil, participantName: nil,
                    blocking: gaps, optionalGaps: [], limitations: [], requiresUserInteraction: false))
            }
        }
        let runnable = blockedMandatory.isEmpty ? available : []
        let omissions = assessments.filter { !$0.canExecute && !mandatory.contains($0.method) }.map { assessment in
            OracleMethodOmission(method: assessment.method,
                reason: assessment.unavailableReason ?? assessment.blocking.map(\.reason).joined(separator: L10n.text("；", "; ")),
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
        case .bazi, .chenggu: [.birthDate, .birthTimeZone, .birthCoordinates]
        case .astrology: [.birthDate, .birthTimeZone]
        case .ziwei: [.birthDate, .birthTime, .gender, .birthTimeZone, .birthCoordinates]
        case .xingming: [.surname, .givenName]
        default: []
        }
    }

    private static func optionalRequirements(for method: OracleMethod, timeAvailable: Bool) -> [OracleField] {
        switch method {
        case .bazi: timeAvailable ? [.birthTime, .gender] : [.birthTime]
        case .chenggu: [.birthTime]
        case .astrology: timeAvailable ? [.birthTime, .birthCoordinates] : [.birthTime]
        default: []
        }
    }

    static func requiresCastingLocation(method: OracleMethod, numbers: [Int]) -> Bool {
        method == .qimen || method == .xiaoliuren || (method == .meihua && numbers.count < 3)
    }

    private static func castingLocationGap(_ profile: OracleProfile?) -> PreparationGap? {
        guard let profile else {
            return .init(field: .currentLocation, state: .unspecified,
                         reason: TrueSolarClock.ClockError.castingLocation.localizedDescription)
        }
        let declared = profile.declaredUnknownFields ?? []
        if declared.contains(.currentLocation) {
            return .init(field: .currentLocation, state: .explicitlyUnknown,
                         reason: L10n.text("起卦地点已标为不确定，暂不能校正真太阳时。", "The casting place is marked unknown, so apparent solar time is unavailable."))
        }
        if TrueSolarClock.castingCoordinates(profile: profile) != nil,
           TimeZone(identifier: profile.currentTimeZoneID) != nil { return nil }
        let invalid = profile.currentLatitude.map { !$0.isFinite || !(-90...90).contains($0) } == true
            || profile.currentLongitude.map { !$0.isFinite || !(-180...180).contains($0) } == true
            || TimeZone(identifier: profile.currentTimeZoneID) == nil
        return .init(field: .currentLocation, state: invalid ? .invalid : .unspecified,
                     reason: TrueSolarClock.ClockError.castingLocation.localizedDescription)
    }

    private static func birthCoordinateGap(person: OracleProfile, declaredUnknown: Set<OracleField>) -> PreparationGap? {
        let fields: Set<OracleField> = [.birthPlace, .birthCoordinates]
        if !declaredUnknown.isDisjoint(with: fields) {
            return .init(field: .birthCoordinates, state: .explicitlyUnknown,
                         reason: L10n.text("出生地已明确为不确定，暂不能校正真太阳时。", "The birthplace was marked unknown, so true solar time cannot be calculated."))
        }
        if BaziBirthLocation.coordinates(for: person) != nil { return nil }
        let invalid = person.birthLatitude.map { !$0.isFinite || !(-90...90).contains($0) } == true
            || person.birthLongitude.map { !$0.isFinite || !(-180...180).contains($0) } == true
        return .init(field: .birthCoordinates, state: invalid ? .invalid : .unspecified,
                     reason: L10n.text("请选择有效出生地，用于本地真太阳时排盘。", "Choose a valid birthplace to calculate the apparent-solar chart on device."))
    }

    private static func gap(for field: OracleField, person: OracleProfile, declaredUnknown: Set<OracleField>) -> PreparationGap? {
        if declaredUnknown.contains(field) { return .init(field: field, state: .explicitlyUnknown, reason: L10n.text("\(field.title)已明确为不确定。", "\(field.title) was marked unknown.")) }
        if person.unknownFields.contains(field) { return .init(field: field, state: .unspecified, reason: L10n.text("\(field.title)尚未确认。", "\(field.title) has not been confirmed.")) }
        func missing() -> PreparationGap { .init(field: field, state: .unspecified, reason: L10n.text("\(field.title)尚未提供。", "\(field.title) was not provided.")) }
        func invalid(_ reason: String) -> PreparationGap { .init(field: field, state: .invalid, reason: reason) }
        switch field {
        case .name: return person.resolvedName.isEmpty ? missing() : nil
        case .birthDate:
            guard let date = person.birthDate else { return missing() }
            guard date.timeIntervalSince1970.isFinite else { return invalid(L10n.text("出生日期无效，尚不能排盘。", "The date of birth is invalid, so a chart cannot be drawn.")) }
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(identifier: person.birthTimeZoneID) ?? TimeZone(secondsFromGMT: 0)!
            return (1900...2100).contains(calendar.component(.year, from: date)) ? nil : invalid(L10n.text("出生日期超出当前支持的1900–2100年范围。", "The date of birth is outside the supported range of 1900–2100."))
        case .birthTimeZone:
            guard !person.birthTimeZoneID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return missing() }
            return TimeZone(identifier: person.birthTimeZoneID) == nil ? invalid(L10n.text("出生地时区无效，不能用出生地名称或默认时区代替。", "The birth time zone is invalid. A place name or default time zone cannot substitute for it.")) : nil
        case .birthTime:
            guard person.birthTimeKnown else { return missing() }
            if let text = person.birthTimeText {
                guard let expression = try? NSRegularExpression(pattern: #"^(?:[01]\d|2[0-3]):[0-5]\d(?::[0-5]\d)?$"#),
                      expression.firstMatch(in: text, range: NSRange(location: 0, length: (text as NSString).length)) != nil else {
                    return invalid(L10n.text("出生时间格式无效，请使用00:00至23:59的当地时间。", "Enter the local time of birth from 00:00 to 23:59."))
                }
                return nil
            }
            return person.birthDate == nil ? missing() : nil // Legacy Date includes a known local time.
        case .gender:
            if ["男", "女"].contains(person.sex) { return nil }
            return ["", "未提供", "未知", "不确定"].contains(person.sex) ? missing() : invalid(L10n.text("排盘性别尚未确认成当前算法支持的值。", "The chart gender has not been confirmed as a supported value."))
        case .surname, .givenName:
            let value = (field == .surname ? person.familyName : person.givenName).trimmingCharacters(in: .whitespacesAndNewlines)
            if value.isEmpty { return missing() }
            return value.count <= 4 ? nil : invalid(L10n.text("\(field.title)需分别提供1至4个字，未自动拆分统一姓名。", "Enter \(field.title.lowercased()) separately in one to four characters. A full name is not split automatically."))
        case .birthCoordinates:
            guard let latitude = person.birthLatitude, let longitude = person.birthLongitude else { return missing() }
            return latitude.isFinite && longitude.isFinite && (-90...90).contains(latitude) && (-180...180).contains(longitude)
                ? nil : invalid(L10n.text("出生地坐标无效，请重新选择出生地。", "The birth coordinates are invalid. Choose the birthplace again."))
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
            if missing.contains(.birthTime) { limits.append(L10n.text("出生时辰未确定，仅保留年、月、日柱的必要候选；真太阳时可能跨日，不固定日柱，不输出时柱、起运与大运。", "The birth hour is unknown. Possible year, month and day pillars are shown; true solar time can cross midnight. No unique day or hour pillar, or luck cycles, is assumed.")) }
            else if missing.contains(.gender) { limits.append(L10n.text("排盘性别未确定，本次不输出起运与大运。", "The chart gender is unknown, so luck cycles are unavailable.")) }
            return limits
        case .chenggu:
            return missing.contains(.birthTime) ? [L10n.text("出生时辰未确定，只列可能骨重范围，不选定某一首评诗。", "The birth hour is unknown. Only the possible weight range is shown, without selecting a verse.")] : []
        case .astrology:
            if missing.contains(.birthTime) { return [L10n.text("出生时刻未确定，只列全天星位区间，不输出宫位、上升点与精确相位。", "The time of birth is unknown. Only the range of planetary positions over the day is shown. Houses, the ascendant, and precise aspects are unavailable.")] }
            if missing.contains(.birthCoordinates) { return [L10n.text("出生坐标未完整确认，保留星位及相位，不计算上升点与宫位。", "The birth coordinates are incomplete. Planetary positions and aspects are available; the ascendant and houses are not.")] }
            if let latitude = person.birthLatitude, abs(latitude) >= 66 { return [L10n.text("出生地位于高纬度，本版本不计算宫位。", "The birthplace is at a high latitude, where this version does not calculate houses.")] }
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
        let owner = name.map { $0 + "’s" } ?? "this person’s"
        switch gap.field {
        case .name: return L10n.text("这次要使用谁的资料？可以选用匿名档案。", "Whose details should this reading use? You can choose an anonymous profile.")
        case .birthDate: return L10n.text("\(subject)公历出生日期是哪一天？", "What is \(owner) Gregorian date of birth?")
        case .birthTimeZone: return L10n.text("\(subject)出生地采用哪个时区？请明确时区；不确定也可以直接说明。", "What was the time zone at \(owner) birthplace? It’s okay to say if you don’t know.")
        case .birthTime: return L10n.text("\(subject)当地出生时间是几点？不记得具体时刻也可以说明。", "What was \(owner) local time of birth? It’s okay to leave the exact time unknown.")
        case .gender: return L10n.text("\(subject)排盘性别是男还是女？不确定可说明。", "Which chart gender should be used for \(name ?? "this person")? You can leave it unknown.")
        case .surname: return L10n.text("请确认\(subject)姓氏部分，先不自动拆姓名。", "Confirm \(owner) family name separately.")
        case .givenName: return L10n.text("请确认\(subject)名字部分。", "Confirm \(owner) given name separately.")
        case .birthCoordinates: return L10n.text("请选择\(subject)出生地的省、市和区县，或确认已有出生坐标。", "Choose \(owner) birth province, city and district, or confirm the saved birth coordinates.")
        case .currentLocation: return L10n.text("请选择这次问事的起卦地点，用于当地真太阳时计算。", "Choose the casting place for this question to calculate local apparent solar time.")
        default: return L10n.text("请补充或确认\(subject)\(gap.field.title)。", "Please provide or confirm \(owner) \(gap.field.title.lowercased()).")
        }
    }

    private static func summary(plan: OraclePlan, people: [OracleProfile], assessments: [ReadingMethodAssessment], runnable: [OracleMethod],
                                omissions: [OracleMethodOmission], blockedMandatory: [OracleMethod]) -> String {
        var lines = [L10n.text("所问：\(plan.question)", "Question: \(plan.question)")]
        for person in people {
            let gaps = assessments.filter { $0.participantID == person.id }.flatMap { $0.blocking + $0.optionalGaps }
            let unavailableFields = Set(gaps.map(\.field))
            let date = person.unknownFields.contains(.birthDate) || unavailableFields.contains(.birthDate) ? L10n.text("出生日期未确定", "date of birth unknown") : (person.birthDateText ?? person.birthDate.map { dateText($0, zone: person.birthTimeZoneID) } ?? L10n.text("出生日期未提供", "date of birth not provided"))
            let time = person.birthTimeKnown && !person.unknownFields.contains(.birthTime) && !unavailableFields.contains(.birthTime)
                ? (person.birthTimeText ?? person.birthDate.map { dateText($0, zone: person.birthTimeZoneID, format: "HH:mm") } ?? L10n.text("出生时间未提供", "time of birth not provided")) : L10n.text("出生时间未确定", "time of birth unknown")
            let zone = person.unknownFields.contains(.birthTimeZone) || unavailableFields.contains(.birthTimeZone) ? L10n.text("出生时区未确定", "birth time zone unknown") : person.birthTimeZoneID
            let gender = ["男", "女"].contains(person.sex) && !person.unknownFields.contains(.gender) && !unavailableFields.contains(.gender) ? L10n.text(person.sex, person.sex == "男" ? "male" : "female") : L10n.text("排盘性别未确定", "chart gender unknown")
            let place = person.birthPlace.isEmpty || person.unknownFields.contains(.birthPlace) || unavailableFields.contains(.birthPlace) ? "" : L10n.text("，出生地\(person.birthPlace)", ", birthplace: \(ChinaDistrictCatalog.shared.displayName(for: person.birthDistrictCode, canonical: person.birthPlace))")
            lines.append(L10n.text("\(person.participantLabel)：\(date)，\(time)，\(zone)，\(gender)\(place)。", "\(person.participantLabel): \(date), \(time), \(zone), \(gender)\(place)."))
        }
        if !blockedMandatory.isEmpty { lines.append(L10n.text("指定的\(blockedMandatory.map(\.progressName).joined(separator: "、"))资料尚未齐全，暂不开始，也不改用其他方法。", "More details are needed for \(blockedMandatory.map(\.progressName).formatted(.list(type: .and))). The reading will wait rather than switch methods.")) }
        else if !runnable.isEmpty { lines.append(L10n.text("可使用：\(runnable.map(\.progressName).joined(separator: "、"))。", "Available: \(runnable.map(\.progressName).formatted(.list(type: .and))).")) }
        for assessment in assessments where assessment.canExecute {
            for limitation in assessment.limitations { lines.append((assessment.participantName.map { $0 + " · " } ?? "") + assessment.method.progressName + L10n.text("：", ": ") + limitation) }
        }
        for omission in omissions {
            let label = omission.participantName.map { "\($0) · " } ?? ""
            lines.append(L10n.text(
                "暂不纳入" + (omission.participantName.map { $0 + "的" } ?? "") + omission.method.progressName + "：" + omission.reason,
                "Omitted: \(label)\(omission.method.progressName) — \(omission.reason)"
            ))
        }
        return lines.joined(separator: "\n")
    }

    private static func dateText(_ date: Date, zone: String, format: String = "yyyy-MM-dd") -> String {
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: zone) ?? TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = format
        return formatter.string(from: date)
    }
}

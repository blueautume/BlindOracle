import Foundation

/// A solar clock face is a calculation coordinate, never a replacement for the
/// physical instant used by ephemerides and solar-term comparisons.
struct TrueSolarClock: Sendable {
    let instant: Date
    let zoneID: String
    let longitude: Double
    let apparentClockDate: Date

    var civilSolar: Solar { Self.solar(instant, zone: TimeZone(identifier: zoneID)!) }
    var apparentSolar: Solar { Self.solar(apparentClockDate, zone: Self.utc) }
    /// LunarSwift's solar-term table is expressed at fixed UTC+08, including
    /// dates on which the birthplace's civil clock observed daylight saving.
    var physicalSolar: Solar { Self.solar(instant, zone: Self.termZone) }
    var equationMinutes: Double { TrueSolarTime.equationOfTimeMinutes(at: instant) }
    var longitudeCorrectionMinutes: Double {
        longitude * 4 - Double(TimeZone(identifier: zoneID)!.secondsFromGMT(for: instant)) / 60
    }
    var totalCorrectionMinutes: Double { longitudeCorrectionMinutes + equationMinutes }

    static func birth(profile: OracleProfile) throws -> Self {
        let unknown = profile.unknownFields.union(profile.declaredUnknownFields ?? [])
        guard !unknown.contains(.birthDate), let instant = profile.birthDate else { throw ClockError.birthDate }
        guard !unknown.contains(.birthTimeZone) else { throw ClockError.birthZone }
        guard let point = BaziBirthLocation.coordinates(for: profile) else { throw ClockError.birthLocation }
        return try make(instant: instant, zoneID: profile.birthTimeZoneID, longitude: point.longitude)
    }

    static func casting(input: OracleInput) throws -> Self {
        guard let point = castingCoordinates(profile: input.profile) else { throw ClockError.castingLocation }
        return try make(instant: input.castingDate, zoneID: input.profile.currentTimeZoneID, longitude: point.longitude)
    }

    static func castingCoordinates(profile: OracleProfile) -> (latitude: Double, longitude: Double)? {
        let unknown = profile.unknownFields.union(profile.declaredUnknownFields ?? [])
        guard !unknown.contains(.currentLocation) else { return nil }
        if let latitude = profile.currentLatitude, let longitude = profile.currentLongitude {
            guard valid(latitude: latitude, longitude: longitude) else { return nil }
            return (latitude, longitude)
        }
        // A selected legacy directory entry can restore a wholly absent pair;
        // a partial/invalid pair must be corrected rather than silently replaced.
        guard profile.currentLatitude == nil, profile.currentLongitude == nil,
              let code = profile.currentDistrictCode,
              let place = districtsByID[code],
              let latitude = place.latitude, let longitude = place.longitude,
              valid(latitude: latitude, longitude: longitude) else { return nil }
        return (latitude, longitude)
    }

    static func make(instant: Date, zoneID: String, longitude: Double) throws -> Self {
        guard instant.timeIntervalSince1970.isFinite, longitude.isFinite,
              (-180...180).contains(longitude), let zone = TimeZone(identifier: zoneID) else { throw ClockError.invalidTime }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        guard (1900...2100).contains(calendar.component(.year, from: instant)) else { throw ClockError.range }
        return Self(instant: instant, zoneID: zoneID, longitude: longitude,
                    apparentClockDate: TrueSolarTime.apparentDate(at: instant, longitude: longitude))
    }

    /// Enumerate every possible solar hour/date for an unknown birth clock.
    /// Endpoints plus each intervening whole solar hour cover all two-hour
    /// branches, including partial edge days and historical 23/25-hour days.
    static func birthHourCandidates(profile: OracleProfile) throws -> [Solar] {
        let clock = try birth(profile: profile)
        var civil = Calendar(identifier: .gregorian)
        civil.timeZone = TimeZone(identifier: clock.zoneID)!
        guard let interval = civil.dateInterval(of: .day, for: clock.instant) else { throw ClockError.invalidTime }
        let first = TrueSolarTime.apparentDate(at: interval.start, longitude: clock.longitude)
        let last = TrueSolarTime.apparentDate(at: interval.end.addingTimeInterval(-0.001), longitude: clock.longitude)
        guard first <= last else { throw ClockError.invalidTime }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = utc
        var dates = [first, last]
        var next = calendar.dateInterval(of: .hour, for: first)!.end
        while next < last {
            dates.append(next)
            next = next.addingTimeInterval(3600)
        }
        var seen = Set<String>()
        return dates.sorted().compactMap { date in
            let value = solar(date, zone: utc)
            let key = "\(value.year)-\(value.month)-\(value.day)-\(value.lunar.timeZhiIndex)"
            return seen.insert(key).inserted ? value : nil
        }
    }

    var rows: [OracleRow] {
        [
            .init(L10n.text("原始钟表时间", "Original civil time"), civilSolar.ymdhms + " · " + zoneID),
            .init(L10n.text("真太阳时", "Apparent solar time"), apparentSolar.ymdhms),
            .init(L10n.text("计算经度", "Calculation longitude"), String(format: "%.6f°", longitude)),
            .init(L10n.text("经度及时制校正", "Longitude and civil-offset correction"), String(format: "%+.3f min", longitudeCorrectionMinutes)),
            .init(L10n.text("均时差", "Equation of time"), String(format: "%+.3f min", equationMinutes)),
            .init(L10n.text("总校正", "Total correction"), String(format: "%+.3f min", totalCorrectionMinutes))
        ]
    }

    static var calendarRule: String {
        L10n.text("本项目以当地真太阳钟面取时辰，太阳钟面零点纪日并映射农历日期；节气按真实时刻独立判定。", "This implementation uses the local apparent-solar clock for hours, maps its midnight-based date to the lunar calendar, and determines solar terms independently from the physical instant.")
    }

    static var coordinateLimitation: String {
        L10n.text("地区坐标是代表点；接近时辰、换日或交节边界时，请核对实际地点与原始钟表记录。", "Area coordinates are representative points. Verify the actual place and original clock record near hour, date or solar-term boundaries.")
    }

    enum ClockError: LocalizedError {
        case birthDate, birthZone, birthLocation, castingLocation, invalidTime, range
        var errorDescription: String? {
            switch self {
            case .birthDate: L10n.text("出生日期未确定，暂不能校正真太阳时。", "A confirmed birth date is required for apparent solar time.")
            case .birthZone: L10n.text("出生时区未确定，暂不能校正真太阳时。", "A confirmed birth time zone is required for apparent solar time.")
            case .birthLocation: L10n.text("请选择有效出生地，用于真太阳时计算。", "Choose a valid birthplace for apparent solar time.")
            case .castingLocation: L10n.text("请选择有效当前所在地作为起卦地点，用于真太阳时计算。", "Choose a valid current location as the casting place for apparent solar time.")
            case .invalidTime: L10n.text("时间、时区或经度无效，暂不能校正真太阳时。", "The time, time zone or longitude is invalid.")
            case .range: L10n.text("原始日期须在1900–2100年范围内。", "The original date must be in1900–2100.")
            }
        }
    }

    private static let utc = TimeZone(secondsFromGMT: 0)!
    private static let termZone = TimeZone(secondsFromGMT: 28_800)!
    private static let districtsByID: [String: ChinaDistrict] = {
        let catalog = ChinaDistrictCatalog.shared
        var pending = catalog.provinces
        var result: [String: ChinaDistrict] = [:]
        while let place = pending.popLast() {
            result[place.id] = place
            pending.append(contentsOf: catalog.children(of: place))
        }
        return result
    }()
    private static func valid(latitude: Double, longitude: Double) -> Bool {
        latitude.isFinite && longitude.isFinite && (-90...90).contains(latitude) && (-180...180).contains(longitude)
    }
    private static func solar(_ date: Date, zone: TimeZone) -> Solar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        return Solar(year: parts.year!, month: parts.month!, day: parts.day!, hour: parts.hour!, minute: parts.minute!, second: parts.second!)
    }
}

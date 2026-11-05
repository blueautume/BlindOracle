import Foundation
import CoreLocation
import Combine
import MapKit

struct LocalPlace: Identifiable, Equatable, Sendable {
    var id: String { name }
    let name: String
    let latitude: Double
    let longitude: Double
    let timeZone: String

    var displayName: String { ChinaDistrictCatalog.shared.displayName(for: nil, canonical: name) }
}

struct ChinaDistrict: Hashable, Identifiable, Sendable {
    let id: String
    let name: String
    let countryCode: String
    let components: [String]
    fileprivate let hasChildren: Bool
    let latitude: Double?
    let longitude: Double?

    var fullName: String { components.joined() }
    var displayName: String { L10n.text(name, ChinaPlaceNames.english(name)) }
    var fullDisplayName: String {
        L10n.text(fullName, components.reversed().map(ChinaPlaceNames.english).joined(separator: ", "))
    }
    var timeZone: String {
        ChinaDistrictCatalog.timeZoneID(forCountryCode: countryCode) ?? OracleProfile.defaultChinaTimeZoneID
    }

    var wholeAreaSelectionTitle: String? {
        guard hasChildren else { return nil }
        switch countryCode {
        case "CN":
            if name.hasSuffix("市") { return L10n.text("全市", "Entire city") }
            guard components.count == 2 else { return nil }
            if name.hasSuffix("州") { return L10n.text("全州", "Entire prefecture") }
            if name.hasSuffix("盟") { return L10n.text("全盟", "Entire league") }
            if name.hasSuffix("地区") { return L10n.text("全地区", "Entire region") }
        case "TW":
            guard components.count == 2 else { return nil }
            if name.hasSuffix("市") { return L10n.text("全市", "Entire city") }
            if name.hasSuffix("縣") { return L10n.text("全縣", "Entire county") }
        case "HK" where components.count == 1 && localPlace != nil: return L10n.text("香港全境", "All of Hong Kong")
        case "MO" where components.count == 1 && localPlace != nil: return L10n.text("澳门全境", "All of Macao")
        default: break
        }
        return nil
    }

    var localPlace: LocalPlace? {
        guard let latitude, let longitude,
              CLLocationCoordinate2DIsValid(.init(latitude: latitude, longitude: longitude)) else { return nil }
        return LocalPlace(name: fullName, latitude: latitude, longitude: longitude, timeZone: timeZone)
    }

    private var lookupComponents: ArraySlice<String> {
        // Reverse and forward geocoders return the region code separately.
        // Only the selected local subdivisions must occur in their address.
        countryCode == "CN" || components.count == 1 ? components[...] : components.dropFirst()
    }

    func matchesGeocodedAddress(_ address: String, regionCode: String?) -> Bool {
        guard regionCode == countryCode else { return false }
        let normalized = Self.normalizedAddress(address)
        if wholeAreaSelectionTitle != nil {
            // A city result must describe the selected area itself. A district
            // or street inside it may repeat the exact same city in its address.
            let path = Self.normalizedAddress(lookupComponents.joined())
            if normalized == path || normalized == "中国" + path { return true }
            if countryCode == "CN", components.count == 1, name.hasSuffix("市") {
                let municipality = String(path.dropLast())
                return normalized == municipality || normalized == "中国" + municipality
            }
            return false
        }
        var remainder = normalized[...]
        for component in lookupComponents {
            guard let range = remainder.range(of: Self.normalizedAddress(component)) else { return false }
            remainder = remainder[range.upperBound...]
        }
        return true
    }

    func acceptsLookupQuery(_ query: String) -> Bool {
        guard query.count <= 120 else { return false }
        let normalized = Self.normalizedAddress(query)
        let fullName = Self.normalizedAddress(fullName)
        let localName = Self.normalizedAddress(lookupComponents.joined())
        // Accept spelling/punctuation variants of the selected path and no appended street or landmark.
        return [fullName, "中国" + fullName, localName].contains(normalized)
    }

    private static func normalizedAddress(_ value: String) -> String {
        let simplified = value.applyingTransform(StringTransform("Traditional-Simplified"), reverse: false) ?? value
        return String(simplified.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) })
    }
}

struct ChinaDistrictCatalog: Sendable {
    static let shared: ChinaDistrictCatalog = {
        guard let url = Bundle.main.url(forResource: "china-districts", withExtension: "json", subdirectory: "Locations"),
              let data = try? Data(contentsOf: url),
              let catalog = try? ChinaDistrictCatalog(data: data) else {
            return ChinaDistrictCatalog(provinces: [], childrenByParent: [:], byID: [:])
        }
        return catalog
    }()

    // Present-day UTC offsets happen to match, but the historical DST and
    // local-time rules must follow the selected region when resolving a birth.
    private static let timeZoneIDsByCountryCode = [
        "CN": OracleProfile.defaultChinaTimeZoneID,
        "HK": "Asia/Hong_Kong",
        "MO": "Asia/Macau",
        "TW": "Asia/Taipei"
    ]
    static let supportedCountryCodes = Set(timeZoneIDsByCountryCode.keys)

    static func timeZoneID(forCountryCode code: String) -> String? {
        timeZoneIDsByCountryCode[code]
    }
    let provinces: [ChinaDistrict]
    private let childrenByParent: [String: [ChinaDistrict]]
    private let byID: [String: ChinaDistrict]
    private let byFullName: [String: ChinaDistrict]
    private let districtIDByPlace: [String: String]

    func children(of district: ChinaDistrict) -> [ChinaDistrict] {
        childrenByParent[district.id] ?? []
    }

    func displayName(for districtID: String?, canonical: String) -> String {
        guard AppLanguage.current.isEnglish else { return canonical }
        let district = districtID.flatMap { byID[$0] } ?? byFullName[canonical]
        return district?.fullDisplayName ?? ChinaPlaceNames.english(canonical)
    }

    /// Accept a complete local district path, never a city-only name, partial
    /// match or address. Duplicate district names require their actual parent.
    /// English aliases are independent of the app's current display language.
    func matchingDistrict(for place: String) -> ChinaDistrict? {
        guard let key = Self.normalizedPlaceKey(place), let id = districtIDByPlace[key] else { return nil }
        return byID[id]
    }

    private init(provinces: [ChinaDistrict], childrenByParent: [String: [ChinaDistrict]], byID: [String: ChinaDistrict]) {
        self.provinces = provinces
        self.childrenByParent = childrenByParent
        self.byID = byID
        self.byFullName = Dictionary(byID.values.sorted { $0.id < $1.id }.map { ($0.fullName, $0) },
                                     uniquingKeysWith: { first, _ in first })
        self.districtIDByPlace = Self.districtPlaceIndex(for: byID)
    }

    private static func districtPlaceIndex(for districts: [String: ChinaDistrict]) -> [String: String] {
        var idsByPlace: [String: Set<String>] = [:]
        var englishAliasesByName: [String: [String]] = [:]
        func englishAliases(_ name: String) -> [String] {
            if let cached = englishAliasesByName[name] { return cached }
            var aliases = [ChinaPlaceNames.english(name)]
            // Keep the previous pinyin display spelling as a supported alias.
            if name == "浦东新区" { aliases.append("Pudong New Area") }
            // Foundation transliterates the polyphonic 都 as "dou" here.
            if name == "成都市" { aliases.append("Chengdu") }
            englishAliasesByName[name] = aliases
            return aliases
        }
        func add(_ place: String, id: String) {
            guard let key = normalizedPlaceKey(place) else { return }
            idsByPlace[key, default: []].insert(id)
        }
        for district in districts.values {
            let isDistrictLevel: Bool
            switch district.countryCode {
            case "CN": isDistrictLevel = district.id.count == 6 && !district.id.hasSuffix("00")
            case "HK", "MO": isDistrictLevel = district.components.count == 2
            case "TW": isDistrictLevel = district.components.count == 3
            default: isDistrictLevel = false
            }
            guard isDistrictLevel, district.components.count >= 2, !district.hasChildren else { continue }
            add(district.fullName, id: district.id)
            if district.countryCode == "CN" { add("中国" + district.fullName, id: district.id) }

            // A province is optional when the district's city is supplied. A
            // municipality already has just two components and loses none.
            var paths = [district.components]
            if district.components.count >= 3 { paths.append(Array(district.components.dropFirst())) }
            for path in paths {
                let variants = path.reduce([[]] as [[String]]) { partial, component in
                    partial.flatMap { prefix in englishAliases(component).map { prefix + [$0] } }
                }
                for variant in variants {
                    for ordered in [variant, Array(variant.reversed())] {
                        let place = ordered.joined(separator: ", ")
                        add(place, id: district.id)
                        if district.countryCode == "CN" {
                            add(place + ", China", id: district.id)
                            add("China, " + place, id: district.id)
                        }
                    }
                }
            }
        }
        // An alias shared by distinct complete paths is deliberately unusable.
        return idsByPlace.compactMapValues { $0.count == 1 ? $0.first : nil }
    }

    private static func normalizedPlaceKey(_ value: String) -> String? {
        guard !value.isEmpty, value.count <= 160 else { return nil }
        let simplified = value.applyingTransform(StringTransform("Traditional-Simplified"), reverse: false) ?? value
        let folded = simplified.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
        let separators = CharacterSet(charactersIn: " \t,，-'’")
        guard folded.unicodeScalars.allSatisfy({ CharacterSet.letters.contains($0) || separators.contains($0) }) else { return nil }
        let key = String(folded.unicodeScalars.filter { CharacterSet.letters.contains($0) })
        return key.isEmpty ? nil : key
    }

    init(data: Data) throws {
        let source = try JSONDecoder().decode(Source.self, from: data)
        guard source.version == 1 else { throw LocationLookupError.unavailable }
        let parentIDs = Set(source.districts.compactMap(\.parent))
        var provinces: [ChinaDistrict] = []
        var childrenByParent: [String: [ChinaDistrict]] = [:]
        var byID: [String: ChinaDistrict] = [:]
        for record in source.districts {
            let parent = record.parent.flatMap { byID[$0] }
            guard !record.id.isEmpty, !record.name.isEmpty, byID[record.id] == nil,
                  record.parent == nil || parent != nil,
                  let country = parent?.countryCode ?? record.country,
                  Self.supportedCountryCodes.contains(country),
                  (record.latitude == nil) == (record.longitude == nil) else {
                throw LocationLookupError.unavailable
            }
            let district = ChinaDistrict(id: record.id, name: record.name, countryCode: country,
                components: (parent?.components ?? []) + [record.name],
                hasChildren: parentIDs.contains(record.id), latitude: record.latitude, longitude: record.longitude)
            guard record.latitude == nil || district.localPlace != nil else { throw LocationLookupError.unavailable }
            byID[district.id] = district
            if let parent { childrenByParent[parent.id, default: []].append(district) }
            else { provinces.append(district) }
        }
        self.init(provinces: provinces, childrenByParent: childrenByParent, byID: byID)
    }

    private struct Source: Decodable {
        let version: Int
        let districts: [Record]
    }

    private struct Record: Decodable {
        let id: String
        let name: String
        let parent: String?
        let country: String?
        let latitude: Double?
        let longitude: Double?
    }
}

private enum ChinaPlaceNames {
    private static let conventional: [String: String] = [
        "北京": "Beijing", "天津": "Tianjin", "上海": "Shanghai", "重庆": "Chongqing",
        "内蒙古自治区": "Inner Mongolia", "广西壮族自治区": "Guangxi", "西藏自治区": "Tibet",
        "宁夏回族自治区": "Ningxia", "新疆维吾尔自治区": "Xinjiang",
        "香港特别行政区": "Hong Kong", "香港": "Hong Kong",
        "澳门特别行政区": "Macao", "澳门": "Macao", "台湾地区": "Taiwan", "台湾": "Taiwan",
        "陕西": "Shaanxi", "山西": "Shanxi", "厦门": "Xiamen", "西安": "Xi'an", "长安": "Chang'an",
        "长春": "Changchun", "长沙": "Changsha", "长治": "Changzhi", "长乐": "Changle",
        "朝阳": "Chaoyang", "六安": "Lu'an", "六盘水": "Liupanshui", "蚌埠": "Bengbu",
        "台北": "Taipei", "新北": "New Taipei", "桃园": "Taoyuan", "台中": "Taichung",
        "台南": "Tainan", "高雄": "Kaohsiung", "基隆": "Keelung", "新竹": "Hsinchu",
        "嘉义": "Chiayi", "彰化": "Changhua", "南投": "Nantou", "宜兰": "Yilan",
        "云林": "Yunlin", "屏东": "Pingtung", "花莲": "Hualien", "台东": "Taitung",
        "苗栗": "Miaoli", "澎湖": "Penghu", "金门": "Kinmen", "连江": "Lienchiang",
        "九龙": "Kowloon", "新界": "New Territories", "香港岛": "Hong Kong Island",
        "尖沙咀": "Tsim Sha Tsui", "深水埗": "Sham Shui Po", "黄大仙": "Wong Tai Sin",
        "荃湾": "Tsuen Wan", "沙田": "Sha Tin", "屯门": "Tuen Mun", "元朗": "Yuen Long",
        "西贡": "Sai Kung", "葵青": "Kwai Tsing", "大埔": "Tai Po", "离岛": "Islands",
        "油尖旺": "Yau Tsim Mong", "观塘": "Kwun Tong", "湾仔": "Wan Chai", "中西": "Central and Western",
        "氹仔": "Taipa", "路环": "Coloane"
    ]

    static func english(_ name: String) -> String {
        guard name.unicodeScalars.contains(where: { (0x3400...0x9FFF).contains($0.value) }) else { return name }
        let simplified = name.applyingTransform(StringTransform("Traditional-Simplified"), reverse: false) ?? name
        if let exact = conventional[simplified] { return exact }
        // English names for administrative divisions; transliterate the name
        // while keeping the Chinese catalog entry and district ID unchanged.
        let suffixes = [("特别行政区", " SAR"), ("自治县", " Autonomous County"),
                        ("自治州", " Autonomous Prefecture"), ("自治区", " Autonomous Region"),
                        ("地区", " Prefecture"), ("市", ""), ("省", ""), ("区", " District"),
                        ("县", " County"), ("盟", " League"), ("旗", " Banner")]
        let match = suffixes.first { simplified.count > $0.0.count && simplified.hasSuffix($0.0) }
        let stem = match.map { String(simplified.dropLast($0.0.count)) } ?? simplified
        let suffix = match?.1 ?? ""
        if let exact = conventional[stem] { return exact + suffix }
        let latin = stem.applyingTransform(.mandarinToLatin, reverse: false) ?? stem
        let plain = latin.applyingTransform(.stripDiacritics, reverse: false) ?? latin
        return plain.split(whereSeparator: \.isWhitespace).joined().capitalized + suffix
    }
}

enum LocationLookupError: LocalizedError {
    case unavailable, districtCoordinatesUnavailable, outsideChina

    var errorDescription: String? {
        switch self {
        case .unavailable: L10n.text("暂时无法确认当前位置，请重试或从地区列表选择。", "Your location couldn't be confirmed. Try again or choose a place from the list.")
        case .districtCoordinatesUnavailable: L10n.text("已保留所选地区，暂时无法核实经纬度。可以重试或另选地区。", "Your selection was kept, but its coordinates couldn't be confirmed. Try again or choose another place.")
        case .outsideChina: L10n.text("当前定位仅支持中国地区。可以重试或从地区列表选择。", "Your current location is outside the supported regions. Try again or choose a place from the list.")
        }
    }
}

enum LocationPurpose { case birth, current }

extension LocalPlace {
    /// A location is applied only after the user explicitly chooses its target.
    /// Its timezone comes from the resolved place, never the device settings.
    @discardableResult func apply(to profile: inout OracleProfile, purpose: LocationPurpose) -> Bool {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              latitude.isFinite, longitude.isFinite,
              (-90...90).contains(latitude), (-180...180).contains(longitude),
              TimeZone(identifier: timeZone) != nil else { return false }
        let fields: Set<OracleField>
        switch purpose {
        case .birth:
            profile.birthPlace = name; profile.birthLatitude = latitude; profile.birthLongitude = longitude
            profile.birthTimeZoneID = timeZone
            profile.birthDistrictCode = nil
            fields = [.birthPlace, .birthCoordinates, .birthTimeZone]
        case .current:
            profile.currentPlace = name; profile.currentLatitude = latitude; profile.currentLongitude = longitude
            profile.currentTimeZoneID = timeZone
            profile.currentDistrictCode = nil
            fields = [.currentLocation]
        }
        profile.unknownFields.subtract(fields)
        profile.declaredUnknownFields?.subtract(fields)
        return true
    }
}

@MainActor final class LocationService: NSObject, ObservableObject, @preconcurrency CLLocationManagerDelegate {
    @Published private(set) var place: LocalPlace?
    @Published private(set) var message: String?
    @Published private(set) var isLocating = false
    private var manager: CLLocationManager?
    private let managerFactory: () -> CLLocationManager
    private let servicesEnabled: () -> Bool
    private var requestID: UUID?
    private var awaitingCoordinate = false
    private var geocodingTask: Task<Void, Never>?
    private var cancelGeocoding: (() -> Void)?

    override convenience init() {
        self.init(managerFactory: { CLLocationManager() },
                  servicesEnabled: { CLLocationManager.locationServicesEnabled() })
    }

    init(managerFactory: @escaping () -> CLLocationManager, servicesEnabled: @escaping () -> Bool) {
        self.managerFactory = managerFactory
        self.servicesEnabled = servicesEnabled
        super.init()
    }

    static func resolveChinaDistrict(_ district: ChinaDistrict, using client: DeepSeekClient? = nil) async throws -> LocalPlace {
        if let place = district.localPlace { return place }
        guard let client else { throw LocationLookupError.districtCoordinatesUnavailable }
        do {
            let query = try await client.districtGeocodingQuery(for: district)
            try Task.checkCancellation()
            let coordinate: CLLocationCoordinate2D?
            if #available(iOS 26.0, *) {
                coordinate = try await geocodeDistrict(query, district: district)
            } else {
                coordinate = try await geocodeDistrictLegacy(query, district: district)
            }
            try Task.checkCancellation()
            guard let coordinate, CLLocationCoordinate2DIsValid(coordinate) else {
                throw LocationLookupError.districtCoordinatesUnavailable
            }
            return LocalPlace(name: district.fullName, latitude: coordinate.latitude,
                longitude: coordinate.longitude, timeZone: district.timeZone)
        } catch {
            try Task.checkCancellation()
            throw LocationLookupError.districtCoordinatesUnavailable
        }
    }

    @available(iOS 26.0, *)
    private static func geocodeDistrict(_ query: String, district: ChinaDistrict) async throws -> CLLocationCoordinate2D? {
        guard let request = MKGeocodingRequest(addressString: query) else { return nil }
        request.preferredLocale = Locale(identifier: "zh_CN")
        let items = try await withTaskCancellationHandler {
            try await request.mapItems
        } onCancel: {
            Task { @MainActor in request.cancel() }
        }
        let match = items.first { item in
            let code = item.addressRepresentations?.region?.identifier
            let addresses = district.wholeAreaSelectionTitle == nil
                ? [item.address?.fullAddress, item.address?.shortAddress] : [item.address?.fullAddress]
            return addresses.compactMap { $0 }.contains {
                district.matchesGeocodedAddress($0, regionCode: code)
            }
        }
        return match?.location.coordinate
    }

    @available(iOS, introduced: 17.0, deprecated: 26.0, message: "Older iOS forward-geocoding fallback")
    private static func geocodeDistrictLegacy(_ query: String, district: ChinaDistrict) async throws -> CLLocationCoordinate2D? {
        let geocoder = CLGeocoder()
        let values = try await withTaskCancellationHandler {
            try await geocoder.geocodeAddressString(query, in: nil, preferredLocale: Locale(identifier: "zh_CN"))
        } onCancel: {
            Task { @MainActor in geocoder.cancelGeocode() }
        }
        return values.first { placemark in
            if district.wholeAreaSelectionTitle != nil,
               placemark.thoroughfare != nil || placemark.subThoroughfare != nil { return false }
            let components = [placemark.administrativeArea, placemark.locality, placemark.subLocality, placemark.name]
                .compactMap { $0 }.reduce(into: [String]()) { parts, part in
                    if parts.last != part { parts.append(part) }
                }
            return district.matchesGeocodedAddress(components.joined(), regionCode: placemark.isoCountryCode)
        }?.location?.coordinate
    }

    func request() {
        guard !isLocating else { return }
        cancel()
        message = nil; place = nil; isLocating = true
        let id = UUID(); requestID = id
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--ui-testing-local"),
           ProcessInfo.processInfo.arguments.contains("--ui-testing-location-fixture") {
            // Deterministic, permission-free UI coverage; excluded from Release.
            geocodingTask = Task { [weak self] in
                await Task.yield()
                guard let self, self.requestID == id, !Task.isCancelled else { return }
                let coordinate = CLLocationCoordinate2D(latitude: 40.03102, longitude: 116.22108)
                if let place = try? Self.currentPlace(name: "北京市海淀区", regionCode: "CN", coordinate: coordinate) {
                    self.finish(place, id: id)
                }
            }
            return
        }
        #endif
        guard servicesEnabled() else {
            fail(L10n.text("定位未开启，可以在系统设置中开启后重试，或从地区列表选择。", "Location Services are off. Turn them on in Settings or choose a place from the list."), id: id); return
        }
        // A delegate callback carries its manager, not the UUID of requestLocation.
        // Give each request its own manager so queued callbacks from a cancelled
        // request cannot be accepted as coordinates or errors for its replacement.
        let manager = managerFactory()
        self.manager = manager
        manager.desiredAccuracy = kCLLocationAccuracyKilometer
        manager.delegate = self
        updateAuthorization()
    }

    func cancel() {
        requestID = nil; awaitingCoordinate = false; isLocating = false
        stopLocationUpdates()
        geocodingTask?.cancel(); geocodingTask = nil
        cancelGeocoding?(); cancelGeocoding = nil
    }

    private func updateAuthorization() {
        guard let manager, let id = requestID, geocodingTask == nil, !awaitingCoordinate else { return }
        switch manager.authorizationStatus {
        case .notDetermined: manager.requestWhenInUseAuthorization()
        case .authorizedAlways, .authorizedWhenInUse:
            awaitingCoordinate = true; manager.requestLocation()
        default: fail(L10n.text("未获得定位权限，可以在系统设置中允许后重试，或从地区列表选择。", "Location access is off. Allow it in Settings or choose a place from the list."), id: id)
        }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        guard manager === self.manager else { return }
        updateAuthorization()
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard manager === self.manager, let id = requestID, awaitingCoordinate else { return }
        awaitingCoordinate = false
        guard let location = locations.last, location.horizontalAccuracy >= 0,
              CLLocationCoordinate2DIsValid(location.coordinate) else {
            fail(L10n.text("暂时未能取得位置，请重试或从地区列表选择。", "Couldn't get your location. Try again or choose a place from the list."), id: id); return
        }
        geocodingTask = Task { [weak self] in
            guard let self, self.requestID == id, !Task.isCancelled else { return }
            do {
                let resolved = try await self.resolve(location)
                guard !Task.isCancelled else { return }
                self.finish(resolved, id: id)
            } catch {
                guard !Task.isCancelled else { return }
                self.fail((error as? LocationLookupError)?.localizedDescription ?? LocationLookupError.unavailable.localizedDescription, id: id)
            }
        }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        guard manager === self.manager, let id = requestID, awaitingCoordinate else { return }
        fail(L10n.text("暂时未能取得位置，请重试或从地区列表选择。", "Couldn't get your location. Try again or choose a place from the list."), id: id)
    }

    private func resolve(_ location: CLLocation) async throws -> LocalPlace {
        if #available(iOS 26.0, *) {
            guard let request = MKReverseGeocodingRequest(location: location) else { throw LocationLookupError.unavailable }
            request.preferredLocale = Locale(identifier: "zh_CN")
            cancelGeocoding = { request.cancel() }
            let items = try await request.mapItems
            guard let item = items.first else { throw LocationLookupError.unavailable }
            return try Self.currentPlace(name: item.addressRepresentations?.cityWithContext,
                regionCode: item.addressRepresentations?.region?.identifier, coordinate: location.coordinate)
        } else {
            return try await resolveLegacy(location)
        }
    }

    @available(iOS, introduced: 17.0, deprecated: 26.0, message: "Older iOS reverse-geocoding fallback")
    private func resolveLegacy(_ location: CLLocation) async throws -> LocalPlace {
        let geocoder = CLGeocoder()
        cancelGeocoding = { geocoder.cancelGeocode() }
        let values = try await geocoder.reverseGeocodeLocation(location, preferredLocale: Locale(identifier: "zh_CN"))
        guard let placemark = values.first else { throw LocationLookupError.unavailable }
        let name = [placemark.administrativeArea, placemark.locality, placemark.subLocality]
            .compactMap { $0 }.reduce(into: [String]()) { parts, part in
                if parts.last != part { parts.append(part) }
            }.joined()
        return try Self.currentPlace(name: name, regionCode: placemark.isoCountryCode, coordinate: location.coordinate)
    }

    static func currentPlace(name: String?, regionCode: String?, coordinate: CLLocationCoordinate2D) throws -> LocalPlace {
        guard let regionCode else { throw LocationLookupError.unavailable }
        guard let timeZone = ChinaDistrictCatalog.timeZoneID(forCountryCode: regionCode) else { throw LocationLookupError.outsideChina }
        guard let name = name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty,
              CLLocationCoordinate2DIsValid(coordinate) else { throw LocationLookupError.unavailable }
        return LocalPlace(name: name, latitude: coordinate.latitude, longitude: coordinate.longitude,
            timeZone: timeZone)
    }

    private func finish(_ value: LocalPlace, id: UUID) {
        guard requestID == id else { return }
        requestID = nil; awaitingCoordinate = false; cancelGeocoding = nil; geocodingTask = nil
        stopLocationUpdates()
        isLocating = false; place = value
    }

    private func fail(_ text: String, id: UUID) {
        guard requestID == id else { return }
        requestID = nil; awaitingCoordinate = false; cancelGeocoding = nil; geocodingTask = nil
        stopLocationUpdates()
        message = text; isLocating = false
    }

    private func stopLocationUpdates() {
        manager?.delegate = nil
        manager?.stopUpdatingLocation()
        manager = nil
    }

}

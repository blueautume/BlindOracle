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
    var timeZone: String { OracleProfile.defaultChinaTimeZoneID }

    var wholeAreaSelectionTitle: String? {
        guard hasChildren else { return nil }
        switch countryCode {
        case "CN":
            if name.hasSuffix("市") { return "全市" }
            guard components.count == 2 else { return nil }
            if name.hasSuffix("州") { return "全州" }
            if name.hasSuffix("盟") { return "全盟" }
            if name.hasSuffix("地区") { return "全地区" }
        case "TW":
            guard components.count == 2 else { return nil }
            if name.hasSuffix("市") { return "全市" }
            if name.hasSuffix("縣") { return "全縣" }
        case "HK" where components.count == 1 && localPlace != nil: return "香港全境"
        case "MO" where components.count == 1 && localPlace != nil: return "澳门全境"
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
            return ChinaDistrictCatalog(provinces: [], childrenByParent: [:])
        }
        return catalog
    }()

    static let supportedCountryCodes: Set<String> = ["CN", "HK", "MO", "TW"]
    let provinces: [ChinaDistrict]
    private let childrenByParent: [String: [ChinaDistrict]]

    func children(of district: ChinaDistrict) -> [ChinaDistrict] {
        childrenByParent[district.id] ?? []
    }

    private init(provinces: [ChinaDistrict], childrenByParent: [String: [ChinaDistrict]]) {
        self.provinces = provinces
        self.childrenByParent = childrenByParent
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
        self.init(provinces: provinces, childrenByParent: childrenByParent)
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

enum LocationLookupError: LocalizedError {
    case unavailable, districtCoordinatesUnavailable, outsideChina

    var errorDescription: String? {
        switch self {
        case .unavailable: "暂时无法确认当前位置，请重试或从地区列表选择。"
        case .districtCoordinatesUnavailable: "已保留所选地区，暂时无法核实经纬度。可以重试或另选地区。"
        case .outsideChina: "当前定位仅支持中国地区。可以重试或从地区列表选择。"
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
            fail("定位未开启，可以在系统设置中开启后重试，或从地区列表选择。", id: id); return
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
        default: fail("未获得定位权限，可以在系统设置中允许后重试，或从地区列表选择。", id: id)
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
            fail("暂时未能取得位置，请重试或从地区列表选择。", id: id); return
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
        fail("暂时未能取得位置，请重试或从地区列表选择。", id: id)
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
        guard ChinaDistrictCatalog.supportedCountryCodes.contains(regionCode) else { throw LocationLookupError.outsideChina }
        guard let name = name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty,
              CLLocationCoordinate2DIsValid(coordinate) else { throw LocationLookupError.unavailable }
        return LocalPlace(name: name, latitude: coordinate.latitude, longitude: coordinate.longitude,
            timeZone: OracleProfile.defaultChinaTimeZoneID)
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

import Foundation
import CoreLocation
import Combine
import MapKit

struct LocalPlace: Identifiable, Equatable {
    var id: String { name }
    let name: String
    let latitude: Double
    let longitude: Double
    let timeZone: String
    static let catalog: [LocalPlace] = [
        .init(name: "北京", latitude: 39.9042, longitude: 116.4074, timeZone: "Asia/Shanghai"),
        .init(name: "上海", latitude: 31.2304, longitude: 121.4737, timeZone: "Asia/Shanghai"),
        .init(name: "广州", latitude: 23.1291, longitude: 113.2644, timeZone: "Asia/Shanghai"),
        .init(name: "深圳", latitude: 22.5431, longitude: 114.0579, timeZone: "Asia/Shanghai"),
        .init(name: "杭州", latitude: 30.2741, longitude: 120.1551, timeZone: "Asia/Shanghai"),
        .init(name: "南京", latitude: 32.0603, longitude: 118.7969, timeZone: "Asia/Shanghai"),
        .init(name: "成都", latitude: 30.5728, longitude: 104.0668, timeZone: "Asia/Shanghai"),
        .init(name: "重庆", latitude: 29.5630, longitude: 106.5516, timeZone: "Asia/Shanghai"),
        .init(name: "武汉", latitude: 30.5928, longitude: 114.3055, timeZone: "Asia/Shanghai"),
        .init(name: "西安", latitude: 34.3416, longitude: 108.9398, timeZone: "Asia/Shanghai"),
        .init(name: "长沙", latitude: 28.2282, longitude: 112.9388, timeZone: "Asia/Shanghai"),
        .init(name: "郑州", latitude: 34.7466, longitude: 113.6254, timeZone: "Asia/Shanghai"),
        .init(name: "天津", latitude: 39.3434, longitude: 117.3616, timeZone: "Asia/Shanghai"),
        .init(name: "苏州", latitude: 31.2989, longitude: 120.5853, timeZone: "Asia/Shanghai"),
        .init(name: "沈阳", latitude: 41.8057, longitude: 123.4315, timeZone: "Asia/Shanghai"),
        .init(name: "哈尔滨", latitude: 45.8038, longitude: 126.5350, timeZone: "Asia/Shanghai"),
        .init(name: "昆明", latitude: 25.0389, longitude: 102.7183, timeZone: "Asia/Shanghai"),
        .init(name: "乌鲁木齐", latitude: 43.8256, longitude: 87.6168, timeZone: "Asia/Shanghai"),
        .init(name: "香港", latitude: 22.3193, longitude: 114.1694, timeZone: "Asia/Hong_Kong"),
        .init(name: "台北", latitude: 25.0330, longitude: 121.5654, timeZone: "Asia/Taipei"),
        .init(name: "新加坡", latitude: 1.3521, longitude: 103.8198, timeZone: "Asia/Singapore"),
        .init(name: "东京", latitude: 35.6762, longitude: 139.6503, timeZone: "Asia/Tokyo"),
        .init(name: "伦敦", latitude: 51.5074, longitude: -0.1278, timeZone: "Europe/London"),
        .init(name: "纽约", latitude: 40.7128, longitude: -74.0060, timeZone: "America/New_York"),
        .init(name: "洛杉矶", latitude: 34.0522, longitude: -118.2437, timeZone: "America/Los_Angeles"),
        .init(name: "悉尼", latitude: -33.8688, longitude: 151.2093, timeZone: "Australia/Sydney")
    ]
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
            fields = [.birthPlace, .birthCoordinates, .birthTimeZone]
        case .current:
            profile.currentPlace = name; profile.currentLatitude = latitude; profile.currentLongitude = longitude
            profile.currentTimeZoneID = timeZone
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
    private let manager = CLLocationManager()
    private var requestID: UUID?
    private var awaitingCoordinate = false
    private var geocodingTask: Task<Void, Never>?
    private var cancelGeocoding: (() -> Void)?

    override init() {
        super.init(); manager.delegate = self; manager.desiredAccuracy = kCLLocationAccuracyKilometer
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
                self.finish(.init(name: "日本东京都", latitude: 35.6762, longitude: 139.6503, timeZone: "Asia/Tokyo"), id: id)
            }
            return
        }
        #endif
        guard CLLocationManager.locationServicesEnabled() else {
            fail("定位未开启，可以在系统设置中开启后重试，或手动填写。", id: id); return
        }
        updateAuthorization()
    }

    func cancel() {
        requestID = nil; awaitingCoordinate = false; isLocating = false
        manager.stopUpdatingLocation()
        geocodingTask?.cancel(); geocodingTask = nil
        cancelGeocoding?(); cancelGeocoding = nil
    }

    private func updateAuthorization() {
        guard let id = requestID, geocodingTask == nil, !awaitingCoordinate else { return }
        switch manager.authorizationStatus {
        case .notDetermined: manager.requestWhenInUseAuthorization()
        case .authorizedAlways, .authorizedWhenInUse:
            awaitingCoordinate = true; manager.requestLocation()
        default: fail("未获得定位权限，可以在系统设置中允许后重试，或手动填写。", id: id)
        }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) { updateAuthorization() }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let id = requestID, awaitingCoordinate else { return }
        awaitingCoordinate = false
        guard let location = locations.last, location.horizontalAccuracy >= 0,
              CLLocationCoordinate2DIsValid(location.coordinate) else {
            fail("暂时未能取得位置，请重试或手动填写。", id: id); return
        }
        geocodingTask = Task { [weak self] in
            guard let self else { return }
            do {
                let resolved = try await self.resolve(location)
                guard !Task.isCancelled else { return }
                self.finish(resolved, id: id)
            } catch {
                guard !Task.isCancelled else { return }
                self.fail("暂时未能取得地名和时区，请重试或手动填写。", id: id)
            }
        }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        guard let id = requestID, awaitingCoordinate else { return }
        fail("暂时未能取得位置，请重试或手动填写。", id: id)
    }

    private func resolve(_ location: CLLocation) async throws -> LocalPlace {
        if #available(iOS 26.0, *) {
            guard let request = MKReverseGeocodingRequest(location: location) else { throw LookupError.unavailable }
            request.preferredLocale = Locale(identifier: "zh_CN")
            cancelGeocoding = { request.cancel() }
            let items = try await request.mapItems
            guard let item = items.first,
                  let name = item.addressRepresentations?.cityWithContext ?? item.address?.shortAddress ?? item.address?.fullAddress,
                  !name.isEmpty, let zone = item.timeZone else { throw LookupError.unavailable }
            return LocalPlace(name: name, latitude: location.coordinate.latitude, longitude: location.coordinate.longitude, timeZone: zone.identifier)
        } else {
            return try await resolveLegacy(location)
        }
    }

    @available(iOS, introduced: 17.0, deprecated: 26.0, message: "Older iOS reverse-geocoding fallback")
    private func resolveLegacy(_ location: CLLocation) async throws -> LocalPlace {
        let geocoder = CLGeocoder()
        cancelGeocoding = { geocoder.cancelGeocode() }
        let values = try await geocoder.reverseGeocodeLocation(location, preferredLocale: Locale(identifier: "zh_CN"))
        guard let placemark = values.first,
              let name = placemark.locality ?? placemark.administrativeArea ?? placemark.name,
              !name.isEmpty, let zone = placemark.timeZone else { throw LookupError.unavailable }
        return LocalPlace(name: name, latitude: location.coordinate.latitude, longitude: location.coordinate.longitude, timeZone: zone.identifier)
    }

    private func finish(_ value: LocalPlace, id: UUID) {
        guard requestID == id else { return }
        requestID = nil; awaitingCoordinate = false; cancelGeocoding = nil; geocodingTask = nil
        isLocating = false; place = value
    }

    private func fail(_ text: String, id: UUID) {
        guard requestID == id else { return }
        requestID = nil; awaitingCoordinate = false; cancelGeocoding = nil; geocodingTask = nil
        message = text; isLocating = false
    }

    private enum LookupError: Error { case unavailable }
}

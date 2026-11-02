import Foundation
import CoreLocation
import Combine

struct LocalPlace: Identifiable {
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

@MainActor final class LocationService: NSObject, ObservableObject, @preconcurrency CLLocationManagerDelegate {
    @Published var coordinate: CLLocationCoordinate2D?
    @Published var message: String?
    @Published var isLocating = false
    private let manager = CLLocationManager()
    override init() { super.init(); manager.delegate = self; manager.desiredAccuracy = kCLLocationAccuracyKilometer }
    func request() {
        message = nil
        guard CLLocationManager.locationServicesEnabled() else { message = "定位未开启，可以手动填写。"; return }
        switch manager.authorizationStatus {
        case .notDetermined: manager.requestWhenInUseAuthorization()
        case .authorizedAlways, .authorizedWhenInUse: isLocating = true; manager.requestLocation()
        default: message = "未获得定位权限，可以手动填写。"
        }
    }
    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        if manager.authorizationStatus == .authorizedWhenInUse || manager.authorizationStatus == .authorizedAlways {
            isLocating = true; manager.requestLocation()
        }
    }
    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        coordinate = locations.last?.coordinate; isLocating = false
    }
    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        isLocating = false; message = "暂时未能取得位置，可以手动填写。"
    }
}

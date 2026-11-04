import XCTest
import CoreLocation
@testable import BlindOracle

final class LocationServiceTests: XCTestCase {
    private let tokyo = LocalPlace(name: "日本东京都", latitude: 35.6762, longitude: 139.6503, timeZone: "Asia/Tokyo")

    func testEnglishDistrictDisplayDoesNotChangeCanonicalLookupOrSavedPlace() throws {
        let catalog = ChinaDistrictCatalog.shared
        let beijing = try XCTUnwrap(catalog.provinces.first { $0.id == "110000" })
        let haidian = try XCTUnwrap(catalog.children(of: beijing).first { $0.id == "110108" })
        let place = try XCTUnwrap(haidian.localPlace)
        AppLanguage.$override.withValue(.english) {
            XCTAssertEqual(beijing.displayName, "Beijing")
            XCTAssertEqual(beijing.wholeAreaSelectionTitle, "Entire city")
            XCTAssertEqual(place.displayName, "Haidian District, Beijing")
            XCTAssertEqual(catalog.displayName(for: haidian.id, canonical: place.name), place.displayName)
            XCTAssertTrue(haidian.matchesGeocodedAddress("北京市海淀区", regionCode: "CN"))
            XCTAssertFalse(haidian.acceptsLookupQuery(place.displayName))
            var profile = OracleProfile()
            XCTAssertTrue(place.apply(to: &profile, purpose: .birth))
            XCTAssertEqual(profile.birthPlace, "北京市海淀区")
            XCTAssertEqual(profile.birthTimeZoneID, "Asia/Shanghai")
            XCTAssertEqual(profile.birthLatitude, place.latitude)
        }
    }

    func testBundledDistrictsPreserveHierarchyAndDisambiguateDuplicateNames() throws {
        let catalog = ChinaDistrictCatalog.shared
        XCTAssertEqual(catalog.provinces.count, 34)
        let beijing = try XCTUnwrap(catalog.provinces.first { $0.id == "110000" })
        let haidian = try XCTUnwrap(catalog.children(of: beijing).first { $0.id == "110108" })
        XCTAssertEqual(haidian.fullName, "北京市海淀区")
        XCTAssertEqual(haidian.latitude, 40.03102)
        XCTAssertTrue(catalog.children(of: haidian).isEmpty)
        XCTAssertFalse(catalog.children(of: beijing).contains { $0.name == "市辖区" })

        let hebei = try XCTUnwrap(catalog.provinces.first { $0.id == "130000" })
        let shijiazhuang = try XCTUnwrap(catalog.children(of: hebei).first { $0.id == "130100" })
        let hebeiChangan = try XCTUnwrap(catalog.children(of: shijiazhuang).first { $0.name == "长安区" })
        let shaanxi = try XCTUnwrap(catalog.provinces.first { $0.id == "610000" })
        let xian = try XCTUnwrap(catalog.children(of: shaanxi).first { $0.id == "610100" })
        let shaanxiChangan = try XCTUnwrap(catalog.children(of: xian).first { $0.name == "长安区" })
        XCTAssertEqual(hebeiChangan.localPlace?.longitude, 114.58333)
        XCTAssertEqual(shaanxiChangan.localPlace?.longitude, 108.93366)
        XCTAssertFalse(catalog.children(of: shijiazhuang).contains { $0.id == "130171" })
        XCTAssertTrue(shaanxiChangan.matchesGeocodedAddress("中国，陝西省西安市長安區", regionCode: "CN"))
        XCTAssertFalse(shaanxiChangan.matchesGeocodedAddress(hebeiChangan.fullName, regionCode: "CN"))
        XCTAssertFalse(shaanxiChangan.matchesGeocodedAddress(shaanxiChangan.fullName, regionCode: nil))
        XCTAssertFalse(shaanxiChangan.acceptsLookupQuery(hebeiChangan.fullName))
        XCTAssertFalse(shaanxiChangan.acceptsLookupQuery(shaanxiChangan.fullName + "某路"))
    }

    func testRegionalDistrictsAndCountylessCityAreSelectable() throws {
        let catalog = ChinaDistrictCatalog.shared
        let hongKong = try XCTUnwrap(catalog.provinces.first { $0.countryCode == "HK" })
        let macao = try XCTUnwrap(catalog.provinces.first { $0.countryCode == "MO" })
        let taiwan = try XCTUnwrap(catalog.provinces.first { $0.countryCode == "TW" })
        XCTAssertEqual(catalog.children(of: hongKong).count, 18)
        XCTAssertEqual(catalog.children(of: macao).count, 8)
        let counties = catalog.children(of: taiwan)
        XCTAssertEqual(counties.count, 22)
        XCTAssertEqual(counties.flatMap { catalog.children(of: $0) }.count, 368)
        let taipei = try XCTUnwrap(counties.first { $0.name == "臺北市" })
        let daan = try XCTUnwrap(catalog.children(of: taipei).first { $0.name == "大安區" })
        XCTAssertEqual(daan.localPlace?.timeZone, OracleProfile.defaultChinaTimeZoneID)
        XCTAssertTrue(daan.matchesGeocodedAddress("台北市大安区", regionCode: "TW"))
        XCTAssertFalse(daan.matchesGeocodedAddress("台中市大安区", regionCode: "TW"))

        let guangdong = try XCTUnwrap(catalog.provinces.first { $0.id == "440000" })
        let dongguan = try XCTUnwrap(catalog.children(of: guangdong).first { $0.id == "441900" })
        XCTAssertEqual(dongguan.fullName, "广东省东莞市")
        XCTAssertTrue(catalog.children(of: dongguan).isEmpty)
        XCTAssertNil(dongguan.wholeAreaSelectionTitle)
        XCTAssertNotNil(dongguan.localPlace)
    }

    func testWholeAreaTitlesFollowTheExistingAdministrativeHierarchy() throws {
        let catalog = ChinaDistrictCatalog.shared
        func root(_ code: String) throws -> ChinaDistrict {
            try XCTUnwrap(catalog.provinces.first { $0.id == code })
        }
        func child(_ code: String, of parent: ChinaDistrict) throws -> ChinaDistrict {
            try XCTUnwrap(catalog.children(of: parent).first { $0.id == code })
        }

        let beijing = try root("110000")
        let guangdong = try root("440000")
        let guangzhou = try child("440100", of: guangdong)
        XCTAssertNil(guangdong.wholeAreaSelectionTitle)
        XCTAssertEqual(beijing.wholeAreaSelectionTitle, "全市")
        XCTAssertEqual(guangzhou.wholeAreaSelectionTitle, "全市")
        XCTAssertEqual(guangzhou.localPlace?.name, "广东省广州市")
        XCTAssertNotNil(guangzhou.localPlace)
        XCTAssertNil(try child("440106", of: guangzhou).wholeAreaSelectionTitle)
        XCTAssertEqual(try child("222400", of: root("220000")).wholeAreaSelectionTitle, "全州")
        XCTAssertEqual(try child("152500", of: root("150000")).wholeAreaSelectionTitle, "全盟")
        XCTAssertEqual(try child("542500", of: root("540000")).wholeAreaSelectionTitle, "全地区")

        let taiwan = try root("TW:1668284")
        XCTAssertNil(taiwan.wholeAreaSelectionTitle)
        XCTAssertEqual(try child("TW:1668338", of: taiwan).wholeAreaSelectionTitle, "全市")
        XCTAssertEqual(try child("TW:1674197", of: taiwan).wholeAreaSelectionTitle, "全縣")
        XCTAssertEqual(try root("HK:1819730").wholeAreaSelectionTitle, "香港全境")
        XCTAssertEqual(try root("MO:1821275").wholeAreaSelectionTitle, "澳门全境")
    }

    func testCityGeocodingRejectsDistrictStreetAndUnverifiedProvince() throws {
        let catalog = ChinaDistrictCatalog.shared
        let hubei = try XCTUnwrap(catalog.provinces.first { $0.id == "420000" })
        let xiangyang = try XCTUnwrap(catalog.children(of: hubei).first { $0.id == "420600" })
        XCTAssertNil(xiangyang.localPlace)
        XCTAssertTrue(xiangyang.matchesGeocodedAddress("中国湖北省襄阳市", regionCode: "CN"))
        XCTAssertFalse(xiangyang.matchesGeocodedAddress("中国湖北省襄阳市襄城区", regionCode: "CN"))
        XCTAssertFalse(xiangyang.matchesGeocodedAddress("中国湖北省襄阳市长虹路 1 号", regionCode: "CN"))
        XCTAssertFalse(xiangyang.matchesGeocodedAddress("襄阳市", regionCode: "CN"))
        XCTAssertFalse(xiangyang.matchesGeocodedAddress("中国湖北省襄阳市", regionCode: nil))

        let beijing = try XCTUnwrap(catalog.provinces.first { $0.id == "110000" })
        XCTAssertTrue(beijing.matchesGeocodedAddress("中国北京", regionCode: "CN"))
        XCTAssertFalse(beijing.matchesGeocodedAddress("北京市东城区", regionCode: "CN"))
    }

    @MainActor
    func testOfflineCoordinatesResolveAndMissingCoordinatesRemainUnavailable() async throws {
        let catalog = ChinaDistrictCatalog.shared
        let beijing = try XCTUnwrap(catalog.provinces.first { $0.id == "110000" })
        let districts = catalog.children(of: beijing)
        let haidian = try XCTUnwrap(districts.first { $0.id == "110108" })
        let resolved = try await LocationService.resolveChinaDistrict(haidian)
        XCTAssertEqual(resolved, haidian.localPlace)
        let miyun = try XCTUnwrap(districts.first { $0.id == "110118" })
        XCTAssertNil(miyun.localPlace)
        do {
            _ = try await LocationService.resolveChinaDistrict(miyun)
            XCTFail("No coordinates can be saved without a source")
        } catch LocationLookupError.districtCoordinatesUnavailable {
            XCTAssertEqual(miyun.fullName, "北京市密云区")
        }
    }

    @MainActor
    func testGPSRequiresDomesticPlacemarkAndKeepsDeviceCoordinates() throws {
        let point = CLLocationCoordinate2D(latitude: 22.3193, longitude: 114.1694)
        for code in ["CN", "HK", "MO", "TW"] {
            let resolved = try LocationService.currentPlace(name: "定位结果", regionCode: code, coordinate: point)
            XCTAssertEqual(resolved.latitude, point.latitude)
            XCTAssertEqual(resolved.longitude, point.longitude)
            XCTAssertEqual(resolved.timeZone, OracleProfile.defaultChinaTimeZoneID)
        }
        XCTAssertThrowsError(try LocationService.currentPlace(name: "东京都", regionCode: "JP", coordinate: point)) {
            guard case LocationLookupError.outsideChina = $0 else { return XCTFail("Unexpected error: \($0)") }
        }
        XCTAssertThrowsError(try LocationService.currentPlace(name: "位置未确认", regionCode: nil, coordinate: point))
        XCTAssertThrowsError(try LocationService.currentPlace(name: "   ", regionCode: "CN", coordinate: point))
    }

    @MainActor
    func testCancelledManagerCallbacksCannotAffectReplacementRequest() {
        let first = StubLocationManager()
        let second = StubLocationManager()
        var managers = [first, second]
        let service = LocationService(managerFactory: { managers.removeFirst() }, servicesEnabled: { true })

        service.request()
        XCTAssertEqual(first.requestCount, 1)
        service.cancel()
        XCTAssertEqual(first.stopCount, 1)
        XCTAssertNil(first.delegate)

        service.request()
        XCTAssertEqual(second.requestCount, 1)
        XCTAssertTrue(service.isLocating)

        // Simulate callbacks already queued before the first manager was detached.
        // An invalid old coordinate must not fail the still-pending second request.
        let invalid = CLLocation(coordinate: .init(latitude: 35.6, longitude: 139.6), altitude: 0,
                                 horizontalAccuracy: -1, verticalAccuracy: -1, timestamp: Date())
        service.locationManager(first, didUpdateLocations: [invalid])
        service.locationManager(first, didFailWithError: CLError(.locationUnknown))
        service.locationManagerDidChangeAuthorization(first)
        XCTAssertTrue(service.isLocating)
        XCTAssertNil(service.message)
        XCTAssertNil(service.place)
        XCTAssertEqual(second.requestCount, 1)

        // A callback belonging to the active manager still completes its request.
        service.locationManager(second, didFailWithError: CLError(.locationUnknown))
        XCTAssertFalse(service.isLocating)
        XCTAssertNotNil(service.message)
        XCTAssertEqual(second.stopCount, 1)
        XCTAssertNil(second.delegate)
    }

    @MainActor
    func testCancelledManagerCallbacksCannotRestartOrPublishLocation() {
        let manager = StubLocationManager()
        let service = LocationService(managerFactory: { manager }, servicesEnabled: { true })
        service.request()
        service.cancel()

        service.locationManagerDidChangeAuthorization(manager)
        service.locationManager(manager, didUpdateLocations: [CLLocation(latitude: 35.6, longitude: 139.6)])
        service.locationManager(manager, didFailWithError: CLError(.locationUnknown))
        XCTAssertFalse(service.isLocating)
        XCTAssertNil(service.place)
        XCTAssertNil(service.message)
        XCTAssertEqual(manager.requestCount, 1)
    }

    func testBirthLocationResolvesOnlyBirthUnknownsAndPreservesCurrentPlace() {
        var profile = OracleProfile()
        profile.birthDateText = "1990-01-02"; profile.birthTimeText = "08:30"
        profile.birthDistrictCode = "310106"; profile.currentDistrictCode = "110000"
        profile.currentPlace = "伦敦"; profile.currentLatitude = 51.5074; profile.currentLongitude = -0.1278
        profile.currentTimeZoneID = "Europe/London"
        profile.unknownFields = [.birthPlace, .birthCoordinates, .birthTimeZone, .birthTime, .currentLocation]
        profile.declaredUnknownFields = profile.unknownFields
        let before = profile
        XCTAssertTrue(tokyo.apply(to: &profile, purpose: .birth))
        XCTAssertEqual(profile.birthPlace, "日本东京都")
        XCTAssertEqual(profile.birthTimeZoneID, "Asia/Tokyo")
        XCTAssertEqual(profile.birthLatitude, 35.6762)
        XCTAssertEqual(profile.birthLongitude, 139.6503)
        XCTAssertNil(profile.birthDistrictCode)
        XCTAssertEqual(profile.currentDistrictCode, before.currentDistrictCode)
        XCTAssertEqual(profile.currentPlace, before.currentPlace)
        XCTAssertEqual(profile.currentLatitude, before.currentLatitude)
        XCTAssertEqual(profile.currentLongitude, before.currentLongitude)
        XCTAssertEqual(profile.currentTimeZoneID, before.currentTimeZoneID)
        XCTAssertEqual(profile.birthDateText, before.birthDateText)
        XCTAssertEqual(profile.birthTimeText, before.birthTimeText)
        XCTAssertEqual(profile.unknownFields, [.birthTime, .currentLocation])
        XCTAssertEqual(profile.declaredUnknownFields, [.birthTime, .currentLocation])
    }

    func testCurrentLocationDoesNotBecomeBirthLocationOrBirthTimezone() {
        var profile = OracleProfile()
        profile.birthPlace = "上海"; profile.birthLatitude = 31.2304; profile.birthLongitude = 121.4737
        profile.birthDistrictCode = "310000"; profile.currentDistrictCode = "110108"
        profile.birthTimeZoneID = "Asia/Shanghai"
        profile.unknownFields = [.birthCoordinates, .birthTimeZone, .currentLocation]
        profile.declaredUnknownFields = profile.unknownFields
        let before = profile
        XCTAssertTrue(tokyo.apply(to: &profile, purpose: .current))
        XCTAssertEqual(profile.currentPlace, "日本东京都")
        XCTAssertEqual(profile.currentTimeZoneID, "Asia/Tokyo")
        XCTAssertEqual(profile.currentLatitude, 35.6762)
        XCTAssertEqual(profile.currentLongitude, 139.6503)
        XCTAssertNil(profile.currentDistrictCode)
        XCTAssertEqual(profile.birthDistrictCode, before.birthDistrictCode)
        XCTAssertEqual(profile.birthPlace, before.birthPlace)
        XCTAssertEqual(profile.birthLatitude, before.birthLatitude)
        XCTAssertEqual(profile.birthLongitude, before.birthLongitude)
        XCTAssertEqual(profile.birthTimeZoneID, before.birthTimeZoneID)
        XCTAssertEqual(profile.unknownFields, [.birthCoordinates, .birthTimeZone])
        XCTAssertEqual(profile.declaredUnknownFields, [.birthCoordinates, .birthTimeZone])
    }

    func testInvalidLocationCannotPartiallyOverwriteSavedProfile() {
        for invalid in [
            LocalPlace(name: "", latitude: 35.6, longitude: 139.6, timeZone: "Asia/Tokyo"),
            LocalPlace(name: "无效", latitude: .nan, longitude: 139.6, timeZone: "Asia/Tokyo"),
            LocalPlace(name: "无效", latitude: 91, longitude: 139.6, timeZone: "Asia/Tokyo"),
            LocalPlace(name: "无效", latitude: 35.6, longitude: 181, timeZone: "Asia/Tokyo"),
            LocalPlace(name: "无效", latitude: 35.6, longitude: 139.6, timeZone: "Invalid/Zone")
        ] {
            var profile = OracleProfile(); profile.birthPlace = "保留原地点"
            let before = profile
            XCTAssertFalse(invalid.apply(to: &profile, purpose: .birth))
            XCTAssertEqual(profile, before)
            XCTAssertFalse(invalid.apply(to: &profile, purpose: .current))
            XCTAssertEqual(profile, before)
        }
    }
}

private final class StubLocationManager: CLLocationManager {
    var requestCount = 0
    var stopCount = 0

    override var authorizationStatus: CLAuthorizationStatus { .authorizedWhenInUse }
    override func requestLocation() { requestCount += 1 }
    override func stopUpdatingLocation() { stopCount += 1 }
}

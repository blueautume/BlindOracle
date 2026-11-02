import XCTest
@testable import BlindOracle

final class LocationServiceTests: XCTestCase {
    private let tokyo = LocalPlace(name: "日本东京都", latitude: 35.6762, longitude: 139.6503, timeZone: "Asia/Tokyo")

    func testBirthLocationResolvesOnlyBirthUnknownsAndPreservesCurrentPlace() {
        var profile = OracleProfile()
        profile.birthDateText = "1990-01-02"; profile.birthTimeText = "08:30"
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
        profile.birthTimeZoneID = "Asia/Shanghai"
        profile.unknownFields = [.birthCoordinates, .birthTimeZone, .currentLocation]
        profile.declaredUnknownFields = profile.unknownFields
        let before = profile
        XCTAssertTrue(tokyo.apply(to: &profile, purpose: .current))
        XCTAssertEqual(profile.currentPlace, "日本东京都")
        XCTAssertEqual(profile.currentTimeZoneID, "Asia/Tokyo")
        XCTAssertEqual(profile.currentLatitude, 35.6762)
        XCTAssertEqual(profile.currentLongitude, 139.6503)
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

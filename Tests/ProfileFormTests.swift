import XCTest
@testable import BlindOracle

final class ProfileFormTests: XCTestCase {
    func testEverySystemTimezoneCanBeSelectedAndChineseCitiesCanBeSearched() {
        let ids = Set(TimeZoneCatalog.options.map(\.id))
        XCTAssertTrue(Set(TimeZone.knownTimeZoneIdentifiers).isSubset(of: ids))
        XCTAssertTrue(ids.contains("UTC"))
        XCTAssertTrue(TimeZoneCatalog.matching("巴黎").contains { $0.id == "Europe/Paris" })
        XCTAssertTrue(TimeZoneCatalog.matching("东京").contains { $0.id == "Asia/Tokyo" })
        XCTAssertTrue(TimeZoneCatalog.matching("洛杉矶").contains { $0.id == "America/Los_Angeles" })
        XCTAssertEqual(TimeZoneCatalog.matching("america/new_york").map(\.id), ["America/New_York"])
        XCTAssertTrue(TimeZoneCatalog.matching("不存在的城市xyz").isEmpty)
        XCTAssertFalse(TimeZoneCatalog.label(for: "UTC").contains("未知"))
    }

    func testNameOnlyValidationPreservesPreciseBirthdayAndDoesNotInventMissingFacts() throws {
        var profile = OracleProfile(); profile.name = "陈平"
        profile.birthDate = Date(timeIntervalSince1970: 1_000_000_037)
        profile.birthDateText = "2001-09-09"; profile.birthTimeText = "09:46:37"
        profile.birthTimeKnown = true; profile.birthTimeZoneID = "Asia/Shanghai"
        profile.unknownFields = [.birthCoordinates, .birthPlace]
        var draft = ProfileFormDraft(profile: profile)
        draft.profile.name = "陈平安"
        let saved = try draft.validatedProfile()
        XCTAssertEqual(saved.birthDate, profile.birthDate)
        XCTAssertEqual(saved.birthDateText, profile.birthDateText)
        XCTAssertEqual(saved.birthTimeText, profile.birthTimeText)
        XCTAssertEqual(saved.birthTimeZoneID, profile.birthTimeZoneID)
        XCTAssertNil(saved.birthLatitude); XCTAssertNil(saved.birthLongitude)
        XCTAssertTrue(saved.unknownFields.contains(.birthPlace))
    }

    func testUnknownDatesRemainUnknownAndTwoDraftsNeverShareClockState() throws {
        var first = ProfileFormDraft(profile: OracleProfile())
        var second = ProfileFormDraft(profile: OracleProfile())
        first.profile.name = "甲"; second.profile.name = "乙"
        first.birthDateKnown = true; first.birthDateChoiceChanged = true
        first.birthClockEdited = true
        first.profile.birthTimeZoneID = "Asia/Tokyo"
        first.profile.unknownFields.remove(.birthTimeZone)
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        first.birthDate = calendar.date(from: DateComponents(year: 1990, month: 1, day: 2, hour: 12))!
        let savedFirst = try first.validatedProfile()
        let savedSecond = try second.validatedProfile()
        XCTAssertEqual(savedFirst.birthDateText, "1990-01-02")
        XCTAssertNotNil(savedFirst.birthDate)
        XCTAssertNil(savedSecond.birthDate); XCTAssertNil(savedSecond.birthDateText)
        XCTAssertFalse(savedSecond.birthTimeKnown)
        XCTAssertTrue(savedSecond.unknownFields.contains(.birthDate))
        XCTAssertTrue(savedSecond.unknownFields.contains(.birthTimeZone))
        XCTAssertNotEqual(savedFirst.id, savedSecond.id)
    }

    func testCanceledDraftRetainsClockEditsAlongsideInvalidCoordinatesAndMissingName() throws {
        var draft = ProfileFormDraft(profile: OracleProfile())
        draft.birthDateKnown = true; draft.birthDateChoiceChanged = true
        draft.profile.birthTimeKnown = true; draft.birthTimeChoiceChanged = true
        draft.birthClockEdited = true
        draft.profile.birthTimeZoneID = "Asia/Tokyo"
        draft.profile.unknownFields.remove(.birthTimeZone)
        draft.profile.currentLatitude = 91
        draft.profile.birthLongitude = 181
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        draft.birthDate = calendar.date(from: DateComponents(year: 1992, month: 6, day: 15, hour: 8, minute: 30))!
        XCTAssertThrowsError(try draft.validatedProfile())
        XCTAssertThrowsError(try draft.validatedProfile(requireName: false))
        let snapshot = draft.draftProfile
        XCTAssertEqual(snapshot.birthDateText, "1992-06-15")
        XCTAssertEqual(snapshot.birthTimeText, "08:30")
        XCTAssertEqual(snapshot.birthDate, draft.birthDate)
        XCTAssertEqual(snapshot.currentLatitude, 91)
        XCTAssertEqual(snapshot.birthLongitude, 181)
        XCTAssertFalse(snapshot.unknownFields.contains(.birthDate))
        XCTAssertFalse(snapshot.unknownFields.contains(.birthTime))
        XCTAssertFalse(snapshot.declaredUnknownFields?.contains(.birthDate) == true)
        XCTAssertEqual(snapshot.resolvedName, "")
        let restored = ProfileFormDraft(profile: snapshot)
        XCTAssertEqual(restored.birthDate, draft.birthDate)
        XCTAssertTrue(restored.birthDateKnown)
        XCTAssertTrue(restored.profile.birthTimeKnown)
    }

    func testInvalidCoordinatesAndMissingNamePreventFinalSubmission() {
        var draft = ProfileFormDraft(profile: OracleProfile())
        XCTAssertThrowsError(try draft.validatedProfile())
        draft.profile.name = "甲"; draft.profile.currentLatitude = 91
        XCTAssertThrowsError(try draft.validatedProfile())
        draft.profile.currentLatitude = nil; draft.profile.currentTimeZoneID = "Invalid/Timezone"
        XCTAssertThrowsError(try draft.validatedProfile())
        draft.profile.currentTimeZoneID = "Asia/Shanghai"; draft.profile.birthLatitude = 91
        XCTAssertThrowsError(try draft.validatedProfile())
        XCTAssertEqual(draft.draftProfile.birthLatitude, 91)
    }
}

import XCTest
@testable import BlindOracle

final class CastingLocationRequestStateTests: XCTestCase {
    func testNewTimeCastingRequestsAutomaticallyOnlyOnce() throws {
        var state = CastingLocationRequestState()
        let id = try XCTUnwrap(state.beginAutomatic(needsLocation: true, isSupplement: false,
                                                    hasLocation: false, explicitlyCleared: false))
        XCTAssertTrue(state.isWaiting)
        XCTAssertNil(state.beginAutomatic(needsLocation: true, isSupplement: false,
                                           hasLocation: false, explicitlyCleared: false))
        XCTAssertTrue(state.finish(requestID: id))
        XCTAssertFalse(state.isWaiting)
        // An error/repeated onAppear must leave the retry decision to the user.
        XCTAssertNil(state.beginAutomatic(needsLocation: true, isSupplement: false,
                                           hasLocation: false, explicitlyCleared: false))
        XCTAssertNotNil(state.beginManual(needsLocation: true))
    }

    func testSupplementSavedLocationAndExplicitClearSuppressAutomaticPermission() {
        for (supplement, saved, cleared) in [(true, false, false), (false, true, false), (false, false, true)] {
            var state = CastingLocationRequestState()
            XCTAssertNil(state.beginAutomatic(needsLocation: true, isSupplement: supplement,
                                               hasLocation: saved, explicitlyCleared: cleared))
            XCTAssertFalse(state.isWaiting)
            // An explicit button remains available without overriding that choice automatically.
            XCTAssertNotNil(state.beginManual(needsLocation: true))
        }
    }

    func testThreeNumberOrNonLocationMethodDoesNotAskForPermission() {
        var state = CastingLocationRequestState()
        XCTAssertNil(state.beginAutomatic(needsLocation: false, isSupplement: false,
                                           hasLocation: false, explicitlyCleared: false))
        XCTAssertNil(state.beginManual(needsLocation: false))
        XCTAssertFalse(state.automaticAttempted)
        // If two-number/time casting is chosen later, it gets its first request.
        XCTAssertNotNil(state.beginAutomatic(needsLocation: true, isSupplement: false,
                                              hasLocation: false, explicitlyCleared: false))
    }

    func testCancelRejectsLateSuccessOrFailureAndReplacementHasNewIdentity() throws {
        var state = CastingLocationRequestState()
        let old = try XCTUnwrap(state.beginManual(needsLocation: true))
        state.cancel() // Manual picker, clear, dismissal, successful submit or no-location mode.
        XCTAssertFalse(state.finish(requestID: old))
        XCTAssertFalse(state.isWaiting)
        let replacement = try XCTUnwrap(state.beginManual(needsLocation: true))
        XCTAssertNotEqual(old, replacement)
        XCTAssertFalse(state.finish(requestID: old))
        XCTAssertEqual(state.requestID, replacement)
        XCTAssertTrue(state.finish(requestID: replacement))
        XCTAssertFalse(state.finish(requestID: replacement))
    }

    func testCancelledAutomaticRequestDoesNotRestartOnRepeatedAppearance() throws {
        var state = CastingLocationRequestState()
        _ = try XCTUnwrap(state.beginAutomatic(needsLocation: true, isSupplement: false,
                                               hasLocation: false, explicitlyCleared: false))
        state.cancel()
        XCTAssertNil(state.beginAutomatic(needsLocation: true, isSupplement: false,
                                           hasLocation: false, explicitlyCleared: false))
        XCTAssertFalse(state.isWaiting)
    }
}

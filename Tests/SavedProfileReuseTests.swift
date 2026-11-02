import XCTest
@testable import BlindOracle

final class SavedProfileReuseTests: XCTestCase {
    private func temporaryVault() throws -> LocalVault {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("saved-profile-reuse-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return LocalVault(directory: directory)
    }

    private func person(_ name: String = "陈平", date: String = "1992-06-15") throws -> OracleProfile {
        let patch = ProfileUpdate(name: name, sex: "男", birthDate: date, birthTime: "08:30", birthTimeZoneID: "Asia/Tokyo", birthPlace: "东京")
        return try XCTUnwrap(ProfileDirectory.applying([patch], to: []).profiles.first)
    }

    private func plan(subject: String = "本人", ids: [UUID]? = nil, names: [String]? = nil) -> OraclePlan {
        var plan = OraclePlan(intent: "资料复用", subject: subject, methods: [.bazi], requiredFields: [], note: "", question: "只用八字看看明年的财运")
        plan.mandatoryMethods = [.bazi]
        plan.participantIDs = ids; plan.participantNames = names
        return plan
    }

    @MainActor private func waitUntilIdle(_ store: OracleStore) async throws {
        let deadline = Date().addingTimeInterval(5)
        while store.isBusy && Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertFalse(store.isBusy)
    }

    private func assertKnownFacts(_ actual: OracleProfile, match expected: OracleProfile, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(actual.id, expected.id, file: file, line: line)
        XCTAssertEqual(actual.resolvedName, expected.resolvedName, file: file, line: line)
        XCTAssertEqual(actual.birthDateText, expected.birthDateText, file: file, line: line)
        XCTAssertEqual(actual.birthTimeText, expected.birthTimeText, file: file, line: line)
        XCTAssertEqual(actual.birthTimeZoneID, "Asia/Tokyo", file: file, line: line)
        XCTAssertEqual(actual.birthPlace, "东京", file: file, line: line)
        XCTAssertTrue(actual.birthTimeKnown, file: file, line: line)
        XCTAssertTrue(actual.unknownFields.isDisjoint(with: [.name, .birthDate, .birthTime, .birthTimeZone]), file: file, line: line)
    }

    @MainActor func testSoleSavedNamedProfilePrefillsAsCandidateAndCanSubmitWithoutRetypingFacts() async throws {
        let store = OracleStore(vault: try temporaryVault(), bootstrapCredential: false)
        let saved = try person(); store.saveProfile(saved)
        XCTAssertNil(store.selfProfileID)
        store.send("只用八字看看我明年的财运")
        try await waitUntilIdle(store)
        XCTAssertTrue(store.showIntake)
        XCTAssertEqual(store.intakeParticipants.count, 1)
        let candidate = try XCTUnwrap(store.intakeParticipants.first)
        assertKnownFacts(candidate, match: saved)
        XCTAssertNil(store.pendingPlan?.requestedFields)
        XCTAssertEqual(store.messages.filter { $0.kind == .intake }.count, 1)
        XCTAssertNil(store.selfProfileID, "预填候选不应悄悄将此人绑定为用户本人")
        XCTAssertTrue(store.confirmGroupIntake(profiles: [candidate], numbers: [], save: true, sessionID: store.intakeSessionID))
        try await waitUntilIdle(store)
        XCTAssertEqual(store.runs.count, 1)
        XCTAssertNil(store.pendingInteraction)
        XCTAssertFalse(store.showIntake)
        assertKnownFacts(try XCTUnwrap(store.runs.first?.input.readingParticipants.first), match: saved)
        XCTAssertNil(store.selfProfileID)
        XCTAssertEqual(store.profiles.map(\.id), [saved.id])
    }

    @MainActor func testMentioningAnExistingNameResolvesItsCompleteRecordRatherThanCreatingABlankPerson() async throws {
        let store = OracleStore(vault: try temporaryVault(), bootstrapCredential: false)
        let saved = try person(); store.saveProfile(saved)
        store.send("只用八字看看陈平明年的运势")
        try await waitUntilIdle(store)
        XCTAssertTrue(store.showIntake)
        XCTAssertEqual(store.intakeParticipants.map(\.id), [saved.id])
        assertKnownFacts(try XCTUnwrap(store.intakeParticipants.first), match: saved)
        XCTAssertEqual(store.profiles.count, 1)
        XCTAssertTrue(store.confirmGroupIntake(profiles: store.intakeParticipants, numbers: [], save: true, sessionID: store.intakeSessionID))
        try await waitUntilIdle(store)
        XCTAssertEqual(store.runs.first?.results.filter { $0.status == .complete || $0.status == .partial }.map(\.method), [.bazi])
        XCTAssertEqual(store.profiles.map(\.id), [saved.id])
    }

    @MainActor func testSavedFactsAndCandidateSelectionSurviveAppRelaunch() async throws {
        let vault = try temporaryVault()
        let store = OracleStore(vault: vault, bootstrapCredential: false)
        let saved = try person(); store.saveProfile(saved)
        let restarted = OracleStore(vault: vault, bootstrapCredential: false)
        XCTAssertNil(restarted.selfProfileID)
        restarted.send("只用八字看看我明年的财运")
        try await waitUntilIdle(restarted)
        assertKnownFacts(try XCTUnwrap(restarted.intakeParticipants.first), match: saved)
        let reopened = OracleStore(vault: vault, bootstrapCredential: false)
        XCTAssertTrue(reopened.showIntake)
        assertKnownFacts(try XCTUnwrap(reopened.intakeParticipants.first), match: saved)
        XCTAssertNil(reopened.selfProfileID)
        XCTAssertTrue(reopened.runs.isEmpty)
    }

    @MainActor func testDuplicateNamesNeverSelectAnArbitraryRecord() async throws {
        let store = OracleStore(vault: try temporaryVault(), bootstrapCredential: false)
        let first = try person(), second = try person(date: "1998-01-02")
        store.saveProfile(first); store.saveProfile(second)
        store.send("只用八字看看陈平明年的运势")
        try await waitUntilIdle(store)
        XCTAssertTrue(store.showIntake)
        XCTAssertTrue(store.intakeParticipants.isEmpty)
        XCTAssertEqual(Set(store.profiles.map(\.id)), [first.id, second.id])
        XCTAssertNil(store.selfProfileID)
        XCTAssertTrue(store.runs.isEmpty)
    }

    @MainActor func testAskingAboutAnotherPersonNeverDefaultsToTheSoleSavedProfile() async throws {
        let store = OracleStore(vault: try temporaryVault(), bootstrapCredential: false)
        let saved = try person(); store.saveProfile(saved)
        store.send("只用八字看看朋友明年的事业")
        try await waitUntilIdle(store)
        XCTAssertEqual(store.pendingPlan?.subject, "他人")
        XCTAssertTrue(store.showIntake)
        XCTAssertTrue(store.intakeParticipants.isEmpty)
        XCTAssertFalse(store.confirmGroupIntake(profiles: [], numbers: [], save: true))
        XCTAssertTrue(store.runs.isEmpty)
        XCTAssertEqual(store.profiles.map(\.id), [saved.id])
    }

    @MainActor func testSeveralSavedPeopleRequireSelectionUnlessOneWasExplicitlyBoundAsSelf() throws {
        let store = OracleStore(vault: try temporaryVault(), bootstrapCredential: false)
        let first = try person(), second = try person("李四", date: "1998-01-02")
        store.saveProfile(first); store.saveProfile(second)
        XCTAssertTrue(store.defaultParticipants(for: plan()).isEmpty)
        store.selfProfileID = second.id
        XCTAssertEqual(store.defaultParticipants(for: plan()).map(\.id), [second.id])
        XCTAssertTrue(store.defaultParticipants(for: plan(subject: "他人")).isEmpty)
    }

    @MainActor func testEmptyModelIDsCannotHideAnExplicitSelfBindingOrAnExplicitNamedParticipant() throws {
        let store = OracleStore(vault: try temporaryVault(), bootstrapCredential: false)
        let first = try person(), second = try person("李四", date: "1998-01-02")
        store.saveProfile(first); store.saveProfile(second); store.selfProfileID = first.id
        XCTAssertEqual(store.defaultParticipants(for: plan(ids: [])).map(\.id), [first.id])
        XCTAssertEqual(store.defaultParticipants(for: plan(ids: [], names: [second.resolvedName])).map(\.id), [second.id])
        XCTAssertTrue(store.defaultParticipants(for: plan(subject: "他人", ids: [])).isEmpty)
    }

    @MainActor func testGroundedNameOverridesEmptyOrContradictoryAISelectors() throws {
        let store = OracleStore(vault: try temporaryVault(), bootstrapCredential: false)
        let named = try person(), other = try person("李四", date: "1998-01-02")
        store.saveProfile(named); store.saveProfile(other)
        for modelIDs in [[], [other.id]] {
            var proposed = plan(ids: modelIDs, names: [])
            proposed.action = "intake"
            let question = "只用八字看看陈平明年的运势"
            store.resolveParticipants(in: &proposed, question: question)
            XCTAssertEqual(proposed.participantIDs, [named.id])
            XCTAssertEqual(proposed.participantNames, [named.resolvedName])
            assertKnownFacts(try XCTUnwrap(store.defaultParticipants(for: proposed).first), match: named)
        }
        XCTAssertEqual(Set(store.profiles.map(\.id)), [named.id, other.id])
    }

    @MainActor func testAIEmptySelectorsResolveTheAlreadyBoundSelfWithoutAskingForNameAgain() throws {
        let store = OracleStore(vault: try temporaryVault(), bootstrapCredential: false)
        let own = try person(), other = try person("李四", date: "1998-01-02")
        store.saveProfile(own); store.saveProfile(other); store.selfProfileID = own.id
        var proposed = plan(ids: [], names: [])
        proposed.action = "intake"
        store.resolveParticipants(in: &proposed, question: "只用八字看看我明年的财运")
        XCTAssertEqual(proposed.participantIDs, [own.id])
        XCTAssertEqual(proposed.participantNames, [own.resolvedName])
        assertKnownFacts(try XCTUnwrap(store.defaultParticipants(for: proposed).first), match: own)
    }

    func testRestoringKnownFieldsPreservesDeclaredUnknownsIntentionalEditsAndLocalBirthClock() throws {
        let saved = try person()
        var staleZone = saved
        staleZone.birthTimeZoneID = "UTC"
        staleZone.birthDate = ISO8601DateFormatter().date(from: "1992-06-15T08:30:00Z")!
        staleZone.unknownFields.insert(.birthTimeZone)
        staleZone.declaredUnknownFields = []
        let restored = ProfileDirectory.restoringKnownFields(in: staleZone, from: saved)
        XCTAssertEqual(restored.birthTimeZoneID, "Asia/Tokyo")
        XCTAssertEqual(restored.birthDateText, "1992-06-15")
        XCTAssertEqual(restored.birthTimeText, "08:30")
        XCTAssertEqual(restored.birthDate, saved.birthDate)
        XCTAssertFalse(restored.unknownFields.contains(.birthTimeZone))

        var explicitlyUnknown = staleZone
        explicitlyUnknown.declaredUnknownFields = [.birthTimeZone]
        let keptUnknown = ProfileDirectory.restoringKnownFields(in: explicitlyUnknown, from: saved)
        XCTAssertEqual(keptUnknown.birthTimeZoneID, "UTC")
        XCTAssertTrue(keptUnknown.unknownFields.contains(.birthTimeZone))
        XCTAssertTrue(keptUnknown.declaredUnknownFields?.contains(.birthTimeZone) == true)
        XCTAssertEqual(keptUnknown.birthDate, explicitlyUnknown.birthDate)

        let edits = ProfileUpdate(id: saved.id, birthTime: "11:45", birthTimeZoneID: "Europe/London", birthPlace: "伦敦")
        let edited = try XCTUnwrap(ProfileDirectory.applying([edits], to: [saved]).profiles.first)
        let preserved = ProfileDirectory.restoringKnownFields(in: edited, from: saved)
        XCTAssertEqual(preserved.birthTimeText, "11:45")
        XCTAssertEqual(preserved.birthTimeZoneID, "Europe/London")
        XCTAssertEqual(preserved.birthPlace, "伦敦")
        XCTAssertEqual(preserved.birthDate, edited.birthDate)
    }

    @MainActor func testShortExistingNameSelectsSavedUUIDForThePendingQuestionWithoutRecreatingIt() async throws {
        let store = OracleStore(vault: try temporaryVault(), bootstrapCredential: false)
        let selected = try person("王安"), other = try person()
        store.saveProfile(selected); store.saveProfile(other)
        let question = "只用八字看看我明年的事业"
        store.send(question)
        try await waitUntilIdle(store)
        XCTAssertTrue(store.showIntake)
        XCTAssertTrue(store.intakeParticipants.isEmpty)
        store.saveIntakeDraft(profiles: [], numbers: [], sessionID: store.intakeSessionID)
        store.showIntake = false
        store.send("王安")
        try await waitUntilIdle(store)
        XCTAssertTrue(store.showIntake)
        XCTAssertEqual(store.pendingPlan?.question, question)
        XCTAssertEqual(store.pendingPlan?.methods, [.bazi])
        XCTAssertEqual(store.pendingPlan?.participantIDs, [selected.id])
        XCTAssertEqual(store.intakeParticipants.map(\.id), [selected.id])
        assertKnownFacts(try XCTUnwrap(store.intakeParticipants.first), match: selected)
        XCTAssertEqual(Set(store.profiles.map(\.id)), [selected.id, other.id])
        XCTAssertNil(store.pendingPlan?.requestedFields)
        XCTAssertTrue(store.runs.isEmpty)
    }

    @MainActor func testStaleBlankDraftCannotHideNewlySavedNameAndKnownBirthTimezone() throws {
        let vault = try temporaryVault()
        let store = OracleStore(vault: vault, bootstrapCredential: false)
        let saved = try person(); store.saveProfile(saved)
        store.pendingPlan = plan(ids: [saved.id])
        var stale = saved
        stale.name = ""; stale.birthTimeZoneID = "UTC"
        stale.unknownFields.formUnion([.name, .birthTimeZone])
        stale.declaredUnknownFields = []
        store.saveIntakeDraft(profiles: [stale], numbers: [], sessionID: store.intakeSessionID)
        store.showIntake = false
        store.saveProfile(saved)
        store.confirmPendingIntake()
        assertKnownFacts(try XCTUnwrap(store.intakeParticipants.first), match: saved)
        let restarted = OracleStore(vault: vault, bootstrapCredential: false)
        assertKnownFacts(try XCTUnwrap(restarted.intakeParticipants.first), match: saved)
        XCTAssertNil(restarted.selfProfileID)
        XCTAssertTrue(restarted.runs.isEmpty)
    }
}

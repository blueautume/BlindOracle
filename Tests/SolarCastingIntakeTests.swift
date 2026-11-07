import XCTest
@testable import BlindOracle

final class SolarCastingIntakeTests: XCTestCase {
    private func temporaryVault() throws -> LocalVault {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("solar-casting-intake-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return LocalVault(directory: directory)
    }

    private func place(_ name: String = "上海", latitude: Double = 31.2304, longitude: Double = 121.4737,
                       zone: String = "Asia/Shanghai") -> OracleProfile {
        var profile = OracleProfile()
        profile.currentPlace = name
        profile.currentLatitude = latitude; profile.currentLongitude = longitude
        profile.currentTimeZoneID = zone
        return profile
    }

    private func person(_ name: String, longitude: Double) -> OracleProfile {
        var profile = place(name + "的所在地", longitude: longitude)
        profile.name = name; profile.sex = "男"
        profile.birthDate = Date(timeIntervalSince1970: 788_918_400)
        profile.birthTimeKnown = true; profile.birthTimeZoneID = "Asia/Shanghai"
        profile.birthDateText = "1995-01-01"; profile.birthTimeText = "08:30"
        profile.birthPlace = name + "的出生地"; profile.birthLatitude = 30; profile.birthLongitude = longitude - 1
        return profile
    }

    private func plan(_ method: OracleMethod = .xiaoliuren, people: [OracleProfile] = [], numbersRequested: Bool = false) -> OraclePlan {
        var plan = OraclePlan(intent: "起卦地点验收", subject: people.count > 1 ? "多人" : "事件", methods: [method],
                              requiredFields: numbersRequested ? [.numbers] : [], note: "", question: "这次出行怎样安排？")
        plan.mandatoryMethods = [method]
        plan.participantIDs = people.map(\.id); plan.participantNames = people.map(\.participantLabel)
        return plan
    }

    @MainActor private func waitUntilIdle(_ store: OracleStore) async throws {
        let deadline = Date().addingTimeInterval(5)
        while store.isBusy && Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertFalse(store.isBusy)
    }

    func testProjectionCopiesOnlyCastingLocationAndPreservesBirthDetails() {
        var target = person("甲", longitude: 116.4)
        target.unknownFields.insert(.gender); target.declaredUnknownFields = [.birthTime]
        var source = person("地点不是参与人", longitude: 114.2)
        source.currentPlace = "香港"; source.currentTimeZoneID = "Asia/Hong_Kong"; source.currentDistrictCode = "HK-test"
        source.birthDate = Date(timeIntervalSince1970: 0)
        let result = CastingLocationDraft.applying(source, to: target)
        XCTAssertEqual(result.id, target.id)
        XCTAssertEqual(result.name, target.name)
        XCTAssertEqual(result.birthDate, target.birthDate)
        XCTAssertEqual(result.birthTimeText, target.birthTimeText)
        XCTAssertEqual(result.birthTimeZoneID, target.birthTimeZoneID)
        XCTAssertEqual(result.birthPlace, target.birthPlace)
        XCTAssertEqual(result.birthLongitude, target.birthLongitude)
        XCTAssertEqual(result.unknownFields, target.unknownFields)
        XCTAssertEqual(result.declaredUnknownFields, target.declaredUnknownFields)
        XCTAssertEqual(result.currentPlace, "香港")
        XCTAssertEqual(result.currentLongitude, source.currentLongitude)
        XCTAssertEqual(result.currentTimeZoneID, "Asia/Hong_Kong")
        XCTAssertEqual(result.currentDistrictCode, "HK-test")
    }

    func testDirectorySelectionAndClearMaintainBothUnknownMarkers() throws {
        let catalog = ChinaDistrictCatalog.shared
        let province = try XCTUnwrap(catalog.provinces.first { $0.id == "110000" })
        // Municipalities expose districts directly; there is no 110100 city node.
        let district = try XCTUnwrap(catalog.children(of: province).first { $0.id == "110101" })
        var draft = CastingLocationDraft(profile: OracleProfile())
        draft.clear()
        XCTAssertTrue(draft.profile.unknownFields.contains(.currentLocation))
        XCTAssertTrue(draft.profile.declaredUnknownFields?.contains(.currentLocation) == true)
        draft.select(district)
        XCTAssertEqual(draft.profile.currentDistrictCode, district.id)
        XCTAssertEqual(draft.profile.currentLongitude, district.longitude)
        XCTAssertEqual(draft.profile.currentTimeZoneID, district.timeZone)
        XCTAssertFalse(draft.profile.unknownFields.contains(.currentLocation))
        XCTAssertFalse(draft.profile.declaredUnknownFields?.contains(.currentLocation) == true)
        XCTAssertNotNil(TrueSolarClock.castingCoordinates(profile: draft.profile))
        XCTAssertNil(draft.profile.birthDate)
        draft.clear()
        XCTAssertNil(draft.profile.currentLatitude); XCTAssertNil(draft.profile.currentLongitude)
        XCTAssertNil(draft.profile.currentDistrictCode)
        XCTAssertNil(TrueSolarClock.castingCoordinates(profile: draft.profile))
    }

    @MainActor func testNewPreparationDoesNotBorrowSavedSelfOrOtherPersonsPlace() async throws {
        let store = OracleStore(vault: try temporaryVault(), bootstrapCredential: false)
        let own = person("本人", longitude: 121.4737), other = person("另一个人", longitude: 87.6)
        store.saveProfile(other); store.saveProfile(own); store.selfProfileID = own.id
        store.send("只用小六壬问这次出行怎样安排")
        try await waitUntilIdle(store)
        let casting = try XCTUnwrap(store.pendingPlan?.castingProfile)
        XCTAssertNil(casting.currentLongitude)
        XCTAssertNil(casting.currentLatitude)
        XCTAssertNil(casting.currentDistrictCode)
        XCTAssertTrue(casting.currentPlace.isEmpty)
        XCTAssertNil(casting.birthDate)
        XCTAssertTrue(casting.resolvedName.isEmpty)
        XCTAssertTrue(store.runs.isEmpty)
        XCTAssertFalse(store.canConfirmIntake)
        // A denied/failed GPS request therefore cannot silently use an old point.
        XCTAssertFalse(store.confirmGroupIntake(profiles: [], numbers: [], save: false))
        XCTAssertEqual(store.profile.currentLongitude, own.currentLongitude)
    }

    @MainActor func testUnresolvedNewCastingDraftPersistsEmptyWhileSavedSelfKeepsItsLocation() throws {
        let vault = try temporaryVault()
        let store = OracleStore(vault: vault, bootstrapCredential: false)
        let own = person("本人", longitude: 121.4737)
        store.saveProfile(own); store.selfProfileID = own.id
        store.pendingPlan = plan()
        store.saveIntakeDraft(profiles: [], numbers: [], sessionID: store.intakeSessionID)
        let restarted = OracleStore(vault: vault, bootstrapCredential: false)
        let saved = try XCTUnwrap(restarted.intakeCastingProfile)
        XCTAssertNil(TrueSolarClock.castingCoordinates(profile: saved))
        XCTAssertTrue(saved.currentPlace.isEmpty)
        XCTAssertEqual(restarted.profile.currentLongitude, own.currentLongitude)
        XCTAssertFalse(restarted.canConfirmIntake)
    }

    @MainActor func testGPSPlaceKeepsExactCoordinatesAndSavesIndependentDraftForReopening() throws {
        let vault = try temporaryVault()
        let store = OracleStore(vault: vault, bootstrapCredential: false)
        let own = person("本人", longitude: 121.4737)
        store.saveProfile(own); store.selfProfileID = own.id
        store.pendingPlan = plan()
        var draft = CastingLocationDraft(profile: OracleProfile())
        draft.clear()
        let gps = LocalPlace(name: "北京市海淀区", latitude: 40.03102, longitude: 116.22108, timeZone: "Asia/Shanghai")
        XCTAssertTrue(gps.apply(to: &draft.profile, purpose: .current))
        store.saveIntakeDraft(profiles: [], numbers: [], castingProfile: draft.profile, sessionID: store.intakeSessionID)
        let restarted = OracleStore(vault: vault, bootstrapCredential: false)
        let saved = try XCTUnwrap(restarted.intakeCastingProfile)
        XCTAssertEqual(saved.currentPlace, gps.name)
        XCTAssertEqual(saved.currentLatitude, gps.latitude)
        XCTAssertEqual(saved.currentLongitude, gps.longitude)
        XCTAssertEqual(saved.currentTimeZoneID, gps.timeZone)
        XCTAssertNil(saved.currentDistrictCode) // GPS is not converted to a catalog representative point.
        XCTAssertFalse(saved.unknownFields.contains(.currentLocation))
        XCTAssertFalse(saved.declaredUnknownFields?.contains(.currentLocation) == true)
        XCTAssertTrue(restarted.canConfirmIntake)
        XCTAssertEqual(restarted.profile.currentLongitude, own.currentLongitude)
    }

    @MainActor func testCastingDraftAndTwoNumbersPersistWithoutPeopleOrChangingSavedSelf() throws {
        let vault = try temporaryVault()
        let store = OracleStore(vault: vault, bootstrapCredential: false)
        let own = person("本人", longitude: 116.4)
        store.saveProfile(own); store.selfProfileID = own.id
        store.pendingPlan = plan(.meihua, numbersRequested: true)
        let casting = place("香港", latitude: 22.3, longitude: 114.2, zone: "Asia/Hong_Kong")
        store.saveIntakeDraft(profiles: [], numbers: [12, 23], castingProfile: casting, sessionID: store.intakeSessionID)
        XCTAssertEqual(store.profile.currentLongitude, 116.4)
        let restarted = OracleStore(vault: vault, bootstrapCredential: false)
        XCTAssertEqual(restarted.intakeCastingProfile?.currentPlace, "香港")
        XCTAssertEqual(restarted.intakeCastingProfile?.currentTimeZoneID, "Asia/Hong_Kong")
        XCTAssertEqual(restarted.intakeNumbers, [12, 23])
        XCTAssertTrue(restarted.intakeParticipants.isEmpty)
        XCTAssertEqual(restarted.profile.currentLongitude, 116.4)
    }

    @MainActor func testClearedCastingLocationStaysClearedAfterRestart() throws {
        let vault = try temporaryVault()
        let store = OracleStore(vault: vault, bootstrapCredential: false)
        let own = person("本人", longitude: 121.4)
        store.saveProfile(own); store.selfProfileID = own.id
        var pending = plan(); pending.castingProfile = place()
        store.pendingPlan = pending
        var cleared = CastingLocationDraft(profile: place()); cleared.clear()
        store.saveIntakeDraft(profiles: [], numbers: [], castingProfile: cleared.profile, sessionID: store.intakeSessionID)
        let restarted = OracleStore(vault: vault, bootstrapCredential: false)
        let saved = try XCTUnwrap(restarted.intakeCastingProfile)
        XCTAssertTrue(saved.currentPlace.isEmpty)
        XCTAssertNil(saved.currentLongitude)
        XCTAssertTrue(saved.unknownFields.contains(.currentLocation))
        XCTAssertTrue(saved.declaredUnknownFields?.contains(.currentLocation) == true)
        XCTAssertFalse(restarted.confirmGroupIntake(profiles: [], numbers: [], save: false))
        XCTAssertTrue(restarted.runs.isEmpty)
    }

    @MainActor func testStaleFormCannotOverwriteCastingDraft() throws {
        let store = OracleStore(vault: try temporaryVault(), bootstrapCredential: false)
        var pending = plan(); pending.castingProfile = place("原地点", longitude: 121.4)
        store.pendingPlan = pending
        store.saveIntakeDraft(profiles: [], numbers: [], castingProfile: place("错误地点", longitude: 87.6), sessionID: UUID())
        XCTAssertEqual(store.intakeCastingProfile?.currentPlace, "原地点")
    }

    @MainActor func testNoParticipantTimeCastingUsesOnlyGlobalLocation() async throws {
        let store = OracleStore(vault: try temporaryVault(), bootstrapCredential: false)
        store.pendingPlan = plan()
        let casting = place()
        XCTAssertTrue(store.confirmGroupIntake(profiles: [], numbers: [], save: false, castingProfile: casting))
        try await waitUntilIdle(store)
        let input = try XCTUnwrap(store.runs.last?.input)
        XCTAssertTrue(input.readingParticipants.isEmpty)
        XCTAssertEqual(input.profile.currentLongitude, casting.currentLongitude)
        XCTAssertNil(input.profile.birthDate)
        XCTAssertTrue(store.profiles.isEmpty)
    }

    @MainActor func testMultiPersonCurrentPlacesCannotSubstituteForClearedGlobalLocation() throws {
        let store = OracleStore(vault: try temporaryVault(), bootstrapCredential: false)
        let people = [person("甲", longitude: 116.4), person("乙", longitude: 87.6)]
        var cleared = CastingLocationDraft(profile: place()); cleared.clear()
        var pending = plan(people: people); pending.castingProfile = cleared.profile
        store.pendingPlan = pending
        XCTAssertFalse(store.confirmGroupIntake(profiles: people, numbers: [], save: false))
        XCTAssertTrue(store.runs.isEmpty)
        XCTAssertTrue(store.pendingPlan?.castingProfile?.unknownFields.contains(.currentLocation) == true)
    }

    @MainActor func testReadinessDoesNotBorrowFirstPersonPlaceWhenGlobalSnapshotIsAbsent() throws {
        let store = OracleStore(vault: try temporaryVault(), bootstrapCredential: false)
        let people = [person("甲", longitude: 116.4), person("乙", longitude: 87.6)]
        store.pendingPlan = plan(people: people)
        let report = try XCTUnwrap(store.intakePreparationReport(for: people))
        XCTAssertFalse(report.canProceed)
        XCTAssertTrue(report.assessments.flatMap(\.blocking).contains { $0.field == .currentLocation })
    }

    @MainActor func testMultiPersonReadingUsesExplicitGlobalPlaceAndRetainsFirstPersonsBirthData() async throws {
        let store = OracleStore(vault: try temporaryVault(), bootstrapCredential: false)
        let people = [person("甲", longitude: 116.4), person("乙", longitude: 87.6)]
        store.pendingPlan = plan(people: people)
        let casting = place("独立起卦地点", longitude: 114.2, zone: "Asia/Hong_Kong")
        XCTAssertTrue(store.confirmGroupIntake(profiles: people, numbers: [], save: false, castingProfile: casting))
        try await waitUntilIdle(store)
        let input = try XCTUnwrap(store.runs.last?.input)
        XCTAssertEqual(input.profile.currentLongitude, 114.2)
        XCTAssertEqual(input.profile.currentTimeZoneID, "Asia/Hong_Kong")
        XCTAssertEqual(input.profile.birthDate, people[0].birthDate)
        XCTAssertEqual(input.profile.birthLongitude, people[0].birthLongitude)
        XCTAssertEqual(input.readingParticipants.map(\.currentLongitude), people.map(\.currentLongitude))
    }

    @MainActor func testLegacyMeihuaTwoNumberModeNeedsLocationWithoutANewNumberRequest() async throws {
        let store = OracleStore(vault: try temporaryVault(), bootstrapCredential: false)
        store.pendingPlan = plan(.meihua)
        XCTAssertFalse(store.confirmGroupIntake(profiles: [], numbers: [12, 23], save: false))
        XCTAssertTrue(store.confirmGroupIntake(profiles: [], numbers: [12, 23], save: false, castingProfile: place()))
        XCTAssertNil(store.pendingInteraction)
        try await waitUntilIdle(store)
        XCTAssertEqual(store.runs.last?.input.numbers, [12, 23])
        XCTAssertEqual(store.runs.count, 1)
    }

    @MainActor func testMeihuaThreeNumbersNeedNoCastingPlace() async throws {
        let store = OracleStore(vault: try temporaryVault(), bootstrapCredential: false)
        store.pendingPlan = plan(.meihua, numbersRequested: true)
        XCTAssertTrue(store.confirmGroupIntake(profiles: [], numbers: [12, 23, 6], save: false))
        try await waitUntilIdle(store)
        XCTAssertEqual(store.runs.last?.input.numbers, [12, 23, 6])
        XCTAssertNil(store.runs.last?.input.profile.currentLongitude)
    }

    @MainActor func testExplicitNumbersOverrideParticipantUnknownNumberMarkers() async throws {
        let store = OracleStore(vault: try temporaryVault(), bootstrapCredential: false)
        var person = person("甲", longitude: 116.4)
        person.unknownFields.insert(.numbers); person.declaredUnknownFields = [.numbers]
        store.pendingPlan = plan(.meihua, people: [person], numbersRequested: true)
        XCTAssertTrue(store.confirmGroupIntake(profiles: [person], numbers: [12, 23, 6], save: false))
        try await waitUntilIdle(store)
        let run = try XCTUnwrap(store.runs.last)
        XCTAssertFalse(run.input.profile.unknownFields.contains(.numbers))
        XCTAssertFalse(run.input.profile.declaredUnknownFields?.contains(.numbers) == true)
        XCTAssertTrue(run.results.contains { $0.method == .meihua && [.complete, .partial].contains($0.status) })
    }

    @MainActor func testMeihuaTimeModeIsSeparateFromThePendingNumberInteraction() async throws {
        let store = OracleStore(vault: try temporaryVault(), bootstrapCredential: false)
        store.pendingPlan = plan(.meihua, numbersRequested: true)
        XCTAssertTrue(store.confirmGroupIntake(profiles: [], numbers: [], save: false, castingProfile: place()))
        XCTAssertEqual(store.pendingInteraction?.currentRequest?.kind, .numbers)
        XCTAssertTrue(store.runs.isEmpty)
        store.cancelPendingReading()
        store.pendingPlan = plan(.meihua)
        XCTAssertTrue(store.confirmGroupIntake(profiles: [], numbers: [], save: false, castingProfile: place()))
        try await waitUntilIdle(store)
        XCTAssertEqual(store.runs.last?.input.numbers, [])
    }

    @MainActor func testSingleDiscontinuousOrOutOfRangeNumbersCannotStartCalculationBeforeCorrection() throws {
        for numbers in [[12], [0, 23], [12, 0, 6], [12, 23, 1000], [-1, 2]] {
            let store = OracleStore(vault: try temporaryVault(), bootstrapCredential: false)
            store.pendingPlan = plan(.meihua, numbersRequested: true)
            XCTAssertTrue(store.confirmGroupIntake(profiles: [], numbers: numbers, save: false, castingProfile: place()), "\(numbers)")
            let session = try XCTUnwrap(store.pendingInteraction)
            XCTAssertEqual(session.currentRequest?.kind, .numbers)
            store.completeInteraction(.init(requestID: "meihua", numbers: numbers), sessionID: session.id)
            XCTAssertEqual(store.pendingInteraction?.id, session.id)
            XCTAssertTrue(store.runs.isEmpty)
            store.cancelPendingReading()
        }
    }

    @MainActor private func supplementStore() throws -> (OracleStore, OracleRun, OracleProfile) {
        let store = OracleStore(vault: try temporaryVault(), bootstrapCredential: false)
        let person = person("甲", longitude: 116.4)
        let global = place("原起卦地点", longitude: 121.4737)
        let originalProfile = CastingLocationDraft.applying(global, to: person)
        let input = OracleInput(question: "这次出行怎样安排？", profile: originalProfile,
                                castingDate: Date(timeIntervalSince1970: 1_730_000_000), seed: 73,
                                subject: "事件", participants: [person])
        let original = OracleRun(input: input, plan: plan(people: [person]), results: [])
        store.runs = [original]
        var pending = plan(people: [person]); pending.baseRunID = original.id
        store.pendingPlan = pending
        return (store, original, person)
    }

    @MainActor func testSupplementPreservesOriginalGlobalPlaceInstantAndSeedWhenPersonChanges() async throws {
        let (store, original, person) = try supplementStore()
        var changed = person
        changed.currentPlace = "参与人更新的所在地"; changed.currentLongitude = 87.6
        changed.birthDate = person.birthDate?.addingTimeInterval(3600)
        XCTAssertTrue(store.confirmGroupIntake(profiles: [changed], numbers: [], save: false))
        try await waitUntilIdle(store)
        let input = try XCTUnwrap(store.runs.last?.input)
        XCTAssertEqual(input.castingDate, original.input.castingDate)
        XCTAssertEqual(input.seed, original.input.seed)
        XCTAssertEqual(input.profile.currentPlace, original.input.profile.currentPlace)
        XCTAssertEqual(input.profile.currentLongitude, original.input.profile.currentLongitude)
        XCTAssertEqual(input.profile.birthDate, changed.birthDate)
        XCTAssertEqual(store.runs.first?.input.profile.currentPlace, original.input.profile.currentPlace)
    }

    @MainActor func testSupplementExplicitPlaceEditChangesLocationWithoutRecastingTimeOrSeed() async throws {
        let (store, original, person) = try supplementStore()
        let edited = place("用户明确修改地点", longitude: 114.2, zone: "Asia/Hong_Kong")
        XCTAssertTrue(store.confirmGroupIntake(profiles: [person], numbers: [], save: false, castingProfile: edited))
        try await waitUntilIdle(store)
        let input = try XCTUnwrap(store.runs.last?.input)
        XCTAssertEqual(input.profile.currentPlace, edited.currentPlace)
        XCTAssertEqual(input.profile.currentTimeZoneID, edited.currentTimeZoneID)
        XCTAssertEqual(input.castingDate, original.input.castingDate)
        XCTAssertEqual(input.seed, original.input.seed)
        XCTAssertEqual(input.profile.birthDate, original.input.profile.birthDate)
    }

    @MainActor private func completedRun(methods: [OracleMethod], people: [OracleProfile], casting: OracleProfile,
                                         numbers: [Int] = []) async throws -> OracleRun {
        let firstMethod = try XCTUnwrap(methods.first)
        var proposal = plan(firstMethod, people: people)
        proposal.methods = methods; proposal.mandatoryMethods = methods
        proposal.castingProfile = CastingLocationDraft(profile: casting).profile
        let input = OracleInput(question: proposal.question,
                                profile: CastingLocationDraft.applying(casting, to: people.first ?? OracleProfile()),
                                castingDate: Date(timeIntervalSince1970: 1_730_000_000), numbers: numbers,
                                seed: 73, subject: proposal.subject, participants: people)
        let results = await PluginRegistry().calculate(input, methods: methods) { _ in }
        XCTAssertEqual(results.count, methods.reduce(0) { $0 + ($1.usesPersonalProfile ? people.count : 1) })
        XCTAssertTrue(results.allSatisfy { [.complete, .partial].contains($0.status) })
        return OracleRun(input: input, plan: proposal, results: results)
    }

    @MainActor func testSavedPersonCurrentPlaceCannotInvalidateFrozenEventCastingPoint() async throws {
        let originalPerson = person("甲", longitude: 116.4)
        let casting = place("香港起卦", latitude: 22.3, longitude: 114.2, zone: "Asia/Hong_Kong")
        for method in [OracleMethod.qimen, .xiaoliuren, .meihua] {
            let store = OracleStore(vault: try temporaryVault(), bootstrapCredential: false)
            let run = try await completedRun(methods: [method], people: [originalPerson], casting: casting,
                                             numbers: method == .meihua ? [12, 23] : [])
            var moved = originalPerson
            moved.currentPlace = "参与人迁居后未确认地点"; moved.currentLongitude = 87.6
            moved.currentTimeZoneID = "Asia/Urumqi"
            moved.unknownFields.insert(.currentLocation); moved.declaredUnknownFields = [.currentLocation]
            store.saveProfile(moved)
            XCTAssertTrue(store.calculationInputsAreCurrent(for: run), method.rawValue)
            XCTAssertEqual(run.input.profile.currentLongitude, 114.2)
            XCTAssertEqual(run.input.profile.currentTimeZoneID, "Asia/Hong_Kong")
            XCTAssertFalse(run.input.profile.unknownFields.contains(.currentLocation))
        }
    }

    @MainActor func testRefreshingCastingPointDoesNotHideChangedPersonalBirthInputs() async throws {
        let store = OracleStore(vault: try temporaryVault(), bootstrapCredential: false)
        let originalPerson = person("甲", longitude: 116.4)
        let run = try await completedRun(methods: [.bazi], people: [originalPerson], casting: place())
        var moved = originalPerson
        moved.currentPlace = "参与人新的所在地"; moved.currentLongitude = 87.6
        store.saveProfile(moved)
        XCTAssertTrue(store.calculationInputsAreCurrent(for: run))
        moved.birthDate = try XCTUnwrap(originalPerson.birthDate).addingTimeInterval(86_400)
        store.saveProfile(moved)
        XCTAssertFalse(store.calculationInputsAreCurrent(for: run))
    }

    @MainActor func testOtherParticipantFocusKeepsGlobalPointAndTheirBirthProfile() async throws {
        let store = OracleStore(vault: try temporaryVault(), bootstrapCredential: false)
        let own = person("自己", longitude: 116.4)
        var other = person("乙", longitude: 87.6)
        other.unknownFields.insert(.currentLocation); other.declaredUnknownFields = [.currentLocation]
        let casting = place("香港起卦", latitude: 22.3, longitude: 114.2, zone: "Asia/Hong_Kong")
        var run = try await completedRun(methods: [.bazi, .xiaoliuren], people: [own, other], casting: casting)
        run.plan.castingProfile = nil // Existing saved runs may predate the plan snapshot.
        store.saveProfile(own); store.saveProfile(other); store.selfProfileID = own.id
        let transcript = [ChatMessage(role: .user, content: run.input.question),
                          ChatMessage(role: .assistant, content: "已完成双方推演。", kind: .reading, runID: run.id)]
        let references = ConversationPlanningReference.candidates(in: transcript, runs: [run])
        let focused = try XCTUnwrap(store.singleOtherParticipantFocus("只看他不看我", references: references, transcript: transcript)?.0)
        XCTAssertEqual(focused.input.readingParticipants.map(\.id), [other.id])
        XCTAssertEqual(focused.input.profile.id, other.id)
        XCTAssertEqual(focused.input.profile.birthDate, other.birthDate)
        XCTAssertEqual(focused.input.profile.birthLongitude, other.birthLongitude)
        XCTAssertEqual(focused.input.profile.currentPlace, casting.currentPlace)
        XCTAssertEqual(focused.input.profile.currentLongitude, casting.currentLongitude)
        XCTAssertEqual(focused.input.profile.currentTimeZoneID, casting.currentTimeZoneID)
        XCTAssertFalse(focused.input.profile.unknownFields.contains(.currentLocation))
        XCTAssertFalse(focused.input.profile.declaredUnknownFields?.contains(.currentLocation) == true)
        XCTAssertEqual(focused.plan.castingProfile?.currentLongitude, casting.currentLongitude)
        XCTAssertEqual(focused.input.castingDate, run.input.castingDate)
        XCTAssertEqual(focused.input.seed, run.input.seed)
        XCTAssertEqual(Set(focused.results.map(\.id)), Set(run.results.filter {
            !$0.method.usesPersonalProfile || $0.participantID == other.id
        }.map(\.id)))
        XCTAssertTrue(focused.results.contains { $0.method == .xiaoliuren })
        XCTAssertFalse(focused.results.contains { $0.participantID == own.id })
        XCTAssertTrue(store.calculationInputsAreCurrent(for: focused))
    }

    @MainActor func testNarrowedLiuyaoAndMeihuaDoNotKeepMixedRequiredLocation() async throws {
        for (method, name) in [(OracleMethod.liuyao, "六爻"), (.meihua, "梅花易数")] {
            let store = OracleStore(vault: try temporaryVault(), bootstrapCredential: false)
            store.send("用\(name)计算这次出行安排")
            try await waitUntilIdle(store)
            let pending = try XCTUnwrap(store.pendingPlan)
            let descriptor = try XCTUnwrap(store.registry.plugin(method)?.descriptor)
            XCTAssertEqual(pending.methods, [method])
            XCTAssertEqual(Set(pending.requiredFields), Set(descriptor.requiredFields))
            let report = try XCTUnwrap(store.intakePreparationReport(for: []))
            XCTAssertEqual(report.canProceed, method == .liuyao)
            XCTAssertEqual(report.assessments.flatMap(\.blocking).contains { $0.field == .currentLocation }, method == .meihua)
        }
    }
}

import XCTest
@testable import BlindOracle

@MainActor
final class ManualProfileWorkflowTests: XCTestCase {
    func testChatAndGroundedPlannerNamesDoNotCreatePermanentProfiles() async throws {
        let vault = try temporaryVault()
        let store = OracleStore(vault: vault, bootstrapCredential: false)

        store.send("请保存档案，姓名：林舟，出生日期：1993-06-12。先不算。")
        try await waitUntilIdle(store)
        XCTAssertTrue(store.profiles.isEmpty)
        XCTAssertNil(store.selfProfileID)

        let question = "只用八字看看林舟明年的事业。"
        XCTAssertTrue(ProfileDirectory.isAffirmativeParticipantReference("林舟", in: question, profiles: []))
        var proposal = OraclePlan(intent: "个人事业", subject: "他人", methods: [.bazi],
                                  requiredFields: [.birthDate], note: "", question: question)
        proposal.participantNames = ["林舟"]
        proposal.participantIDs = [UUID()]
        store.resolveParticipants(in: &proposal, question: question)
        XCTAssertTrue(proposal.participantIDs?.isEmpty != false)
        XCTAssertTrue(store.profiles.isEmpty)
        XCTAssertTrue(vault.load([OracleProfile].self, from: "profiles", fallback: []).isEmpty)
    }

    func testChatDoesNotBindSelfAndExplicitSelectionPersistsTheChosenProfile() async throws {
        let vault = try temporaryVault()
        let store = OracleStore(vault: vault, bootstrapCredential: false)
        let first = try person("陈平")
        let second = try person("李岚", date: "1995-03-11")
        store.saveProfile(first, creating: true)
        store.saveProfile(second, creating: true)

        store.send("我叫陈平。")
        try await waitUntilIdle(store)
        XCTAssertNil(store.selfProfileID)
        store.setSelfProfile(id: second.id)

        let restarted = OracleStore(vault: vault, bootstrapCredential: false)
        XCTAssertEqual(restarted.selfProfileID, second.id)
        XCTAssertEqual(restarted.profiles.map(\.id), [first.id, second.id])
    }

    func testAmbiguousChatCorrectionOnlyPersistsTheManuallySelectedAndEditedProfile() async throws {
        let first = try person("陈平")
        let second = try person("陈平", date: "1995-03-11", clock: "10:30")
        let (store, vault) = try fixture(with: [first, second])
        let originalProfiles = store.profiles

        store.send("陈平的出生时间更正为16:30，请保存。")
        try await waitUntilIdle(store)
        XCTAssertTrue(store.showIntake)
        XCTAssertTrue(store.intakeParticipants.isEmpty, "同名档案必须由用户选择")
        XCTAssertEqual(store.profiles, originalProfiles)
        XCTAssertEqual(vault.load([OracleProfile].self, from: "profiles", fallback: []), originalProfiles)

        let selected = try XCTUnwrap(store.profiles.first { $0.id == second.id })
        let edited = try changingBirthTime(of: selected, to: "18:45")
        XCTAssertTrue(store.confirmGroupIntake(profiles: [edited], numbers: [],
                                               editedFields: [selected.id: [.birthTime]], sessionID: store.intakeSessionID))
        try await waitUntilIdle(store)
        XCTAssertEqual(store.profiles.first { $0.id == first.id }, originalProfiles.first)
        XCTAssertEqual(store.profiles.first { $0.id == selected.id }?.birthTimeText, "18:45")
        XCTAssertEqual(vault.load([OracleProfile].self, from: "profiles", fallback: []).first { $0.id == selected.id }?.birthTimeText, "18:45")
        XCTAssertTrue(store.runs.isEmpty, "只更正档案不应创建一轮推演")
    }

    func testManuallyCorrectedRecastUsesNewHourPillarAndKeepsHistoricalInputs() async throws {
        try await AppLanguage.$override.withValue(.simplifiedChinese) {
            let person = try person("陈平")
            let (store, vault) = try fixture(with: [person])
            let question = "只用八字看看陈平明年的事业。"
            store.send(question)
            try await waitUntilIdle(store)
            XCTAssertEqual(store.intakeParticipants.map(\.id), [person.id])
            XCTAssertTrue(store.confirmGroupIntake(profiles: store.intakeParticipants, numbers: [], sessionID: store.intakeSessionID))
            try await waitUntilIdle(store)
            let original = try XCTUnwrap(store.runs.first)
            let originalPillar = try hourPillar(in: original)
            XCTAssertEqual(original.input.readingParticipants.first?.birthTimeText, "08:30")

            store.send("陈平的出生时间更正为16:30，重新算一下。")
            try await waitUntilIdle(store)
            XCTAssertTrue(store.showIntake)
            let prefilled = try XCTUnwrap(store.intakeParticipants.first)
            XCTAssertEqual(prefilled.id, person.id)
            XCTAssertEqual(prefilled.birthTimeText, "08:30", "聊天中的建议值不得进入问事表的出生时刻")
            XCTAssertEqual(store.profiles.first?.birthTimeText, "08:30")
            let history = ContextCompressor.history(messages: store.messages, summary: .init())
            XCTAssertFalse(history.contains { $0.content.contains("16:30") })
            let references = ConversationPlanningReference.candidates(in: store.messages, runs: store.runs)
            XCTAssertFalse(references.contains { $0.excerpt.contains("16:30") })

            let edited = try changingBirthTime(of: prefilled, to: "18:45")
            XCTAssertTrue(store.confirmGroupIntake(profiles: [edited], numbers: [],
                                                   editedFields: [person.id: [.birthTime]], sessionID: store.intakeSessionID))
            try await waitUntilIdle(store)
            XCTAssertEqual(store.runs.count, 2)
            let fresh = try XCTUnwrap(store.runs.last)
            XCTAssertNotEqual(fresh.id, original.id)
            XCTAssertEqual(fresh.input.question, original.input.question)
            XCTAssertEqual(fresh.input.readingParticipants.first?.birthTimeText, "18:45")
            XCTAssertNotEqual(try hourPillar(in: fresh), originalPillar)
            XCTAssertEqual(store.profiles.first?.birthTimeText, "18:45")

            let restarted = OracleStore(vault: vault, bootstrapCredential: false)
            let historical = try XCTUnwrap(restarted.runs.first { $0.id == original.id })
            XCTAssertEqual(historical.input.readingParticipants.first?.birthTimeText, "08:30")
            XCTAssertEqual(try hourPillar(in: historical), originalPillar)
            XCTAssertEqual(restarted.profiles.first?.birthTimeText, "18:45")
        }
    }

    func testManualTemporaryPeopleSurviveDraftRestartAndRecastWithoutEnteringDirectory() async throws {
        let (store, vault) = try fixture(with: [])
        store.send("只用八字分别看看我们两个人的事业。")
        try await waitUntilIdle(store)
        XCTAssertTrue(store.showIntake)
        XCTAssertTrue(store.intakeParticipants.isEmpty)
        XCTAssertEqual(store.pendingPlan?.subject, "多人")

        let people = [try person("临时甲"), try person("临时乙", date: "1995-03-11", clock: "10:30")]
        let ids = people.map(\.id)
        store.saveIntakeDraft(profiles: people, numbers: [], sessionID: store.intakeSessionID)
        store.send("把临时甲的生日改成2001年1月1日")
        XCTAssertTrue(store.showIntake)
        XCTAssertEqual(store.pendingPlan?.profileCorrection?.isStandalone, false)
        XCTAssertEqual(store.intakeParticipants.map(\.id), ids)
        XCTAssertEqual(store.intakeParticipants.first?.birthDateText, people.first?.birthDateText)
        let resumed = OracleStore(vault: vault, bootstrapCredential: false)
        XCTAssertEqual(resumed.intakeParticipants.map(\.id), ids)
        XCTAssertTrue(resumed.profiles.isEmpty)
        XCTAssertTrue(resumed.confirmGroupIntake(profiles: resumed.intakeParticipants, numbers: [], sessionID: resumed.intakeSessionID))
        try await waitUntilIdle(resumed)

        let original = try XCTUnwrap(resumed.runs.first)
        XCTAssertEqual(original.input.readingParticipants.map(\.id), ids)
        XCTAssertEqual(Set(original.results.filter { $0.method == .bazi && $0.status == .complete }.compactMap(\.participantID)), Set(ids))
        XCTAssertTrue(resumed.profiles.isEmpty)
        XCTAssertTrue(vault.load([OracleProfile].self, from: "profiles", fallback: []).isEmpty)

        resumed.send("现在补充了重新算一下")
        try await waitUntilIdle(resumed)
        XCTAssertTrue(resumed.showIntake)
        XCTAssertEqual(resumed.pendingPlan?.question, original.input.question)
        XCTAssertEqual(resumed.intakeParticipants.map(\.id), ids)
        XCTAssertTrue(resumed.profiles.isEmpty, "重算指令不能变成人员档案")
        XCTAssertTrue(resumed.confirmGroupIntake(profiles: resumed.intakeParticipants, numbers: [], sessionID: resumed.intakeSessionID))
        try await waitUntilIdle(resumed)

        XCTAssertEqual(resumed.runs.count, 2)
        XCTAssertEqual(resumed.runs.last?.input.readingParticipants.map(\.id), ids)
        XCTAssertTrue(resumed.profiles.isEmpty)
        XCTAssertTrue(vault.load([OracleProfile].self, from: "profiles", fallback: []).isEmpty)
    }

    private func temporaryVault() throws -> LocalVault {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("manual-profile-workflow-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return LocalVault(directory: directory)
    }

    private func fixture(with people: [OracleProfile]) throws -> (OracleStore, LocalVault) {
        let vault = try temporaryVault()
        try vault.save(people, as: "profiles")
        return (OracleStore(vault: vault, bootstrapCredential: false), vault)
    }

    private func person(_ name: String, date: String = "1992-06-15", clock: String = "08:30") throws -> OracleProfile {
        let instant = try XCTUnwrap(ISO8601DateFormatter().date(from: "\(date)T\(clock):00+08:00"))
        return OracleProfile(sex: "男", birthDate: instant, birthPlace: "上海", birthLatitude: 31.2304, birthLongitude: 121.4737,
                             updatedAt: Date(timeIntervalSince1970: 1_730_000_000),
                             name: name, birthDateText: date, birthTimeText: clock)
    }

    private func changingBirthTime(of person: OracleProfile, to clock: String) throws -> OracleProfile {
        let date = try XCTUnwrap(person.birthDateText)
        let time = try XCTUnwrap(ISO8601DateFormatter().date(from: "\(date)T\(clock):00+08:00"))
        var draft = ProfileFormDraft(profile: person)
        draft.setBirthTime(time)
        return try draft.validatedProfile()
    }

    private func hourPillar(in run: OracleRun) throws -> String {
        let result = try XCTUnwrap(run.results.first { $0.method == .bazi })
        XCTAssertEqual(result.status, .complete)
        return try XCTUnwrap(result.rows.first { $0.label == "时柱" }?.value)
    }

    private func waitUntilIdle(_ store: OracleStore) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while store.isBusy, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertFalse(store.isBusy)
    }
}

/// Existing fixtures can seed a profile or explicitly replace the same UUID.
@MainActor
extension OracleStore {
    @discardableResult func saveProfile(_ profile: OracleProfile) -> Bool {
        saveProfile(profile, creating: !profiles.contains { $0.id == profile.id })
    }
}

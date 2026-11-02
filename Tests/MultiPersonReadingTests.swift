import XCTest
@testable import BlindOracle

final class MultiPersonReadingTests: XCTestCase {
    private struct Call: Equatable, Sendable {
        let method: OracleMethod
        let profileID: UUID
        let name: String
    }
    private actor Calls {
        private var values: [Call] = []
        func append(_ value: Call) { values.append(value) }
        func snapshot() -> [Call] { values }
    }
    private struct SnapshotPlugin: OraclePlugin {
        let method: OracleMethod
        let calls: Calls
        var descriptor: OraclePluginDescriptor {
            NativeCalendar.descriptor(method, summary: "多人输入测试", questions: [], output: "独立人员结果")
        }
        func calculate(_ input: OracleInput) async throws -> OracleResult {
            let name = input.profile.resolvedName
            await calls.append(Call(method: method, profileID: input.profile.id, name: name))
            return OracleResult(method: method, headline: "独立结果", rows: [.init("输入姓名", name)],
                                evidence: [.init(id: "same-rule", statement: "EVIDENCE-\(name)-\(method.rawValue)")])
        }
    }

    private func person(_ name: String, birth: String = "1995-01-02T08:00:00+08:00") -> OracleProfile {
        var profile = OracleProfile()
        profile.name = name
        profile.familyName = String(name.prefix(1))
        profile.givenName = String(name.dropFirst())
        profile.sex = "男"
        profile.birthDate = ISO8601DateFormatter().date(from: birth)!
        profile.birthTimeKnown = true
        profile.birthPlace = "北京"
        profile.birthTimeZoneID = "Asia/Shanghai"
        return profile
    }
    private func plan(methods: [OracleMethod] = [.bazi], people: [OracleProfile] = []) -> OraclePlan {
        var plan = OraclePlan(intent: "合作关系", subject: "多人", methods: methods, requiredFields: [],
                              note: "分别确认参与人的资料", question: "张三和李四的合作关系如何安排？")
        plan.participantIDs = people.map(\.id)
        plan.relationship = "合作"
        return plan
    }
    private func input(people: [OracleProfile]) -> OracleInput {
        var input = OracleInput(question: "张三和李四的合作关系如何安排？", profile: person("原本人"), seed: 42, subject: "多人")
        input.participants = people
        input.relationship = "合作"
        return input
    }
    private func temporaryVault() throws -> LocalVault {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("multi-person-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return LocalVault(directory: directory)
    }
    private func removing(_ fields: [String], from value: some Encodable) throws -> Data {
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? [String: Any])
        for field in fields { object.removeValue(forKey: field) }
        return try JSONSerialization.data(withJSONObject: object)
    }
    @MainActor private func waitUntilIdle(_ store: OracleStore) async throws {
        let deadline = Date().addingTimeInterval(5)
        while store.isBusy && Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertFalse(store.isBusy)
    }

    func testLegacySinglePersonJSONNeedsNoNewGroupFields() throws {
        let profile = person("张三")
        let oldProfile = try JSONDecoder().decode(OracleProfile.self, from: removing(["name", "birthDateText", "birthTimeText"], from: profile))
        XCTAssertEqual(oldProfile.id, profile.id)
        XCTAssertEqual(oldProfile.resolvedName, "张三")
        var request = input(people: [profile])
        request.profile = oldProfile
        let legacy = try JSONDecoder().decode(OracleInput.self, from: removing(["participants", "relationship"], from: request))
        XCTAssertNil(legacy.participants)
        XCTAssertNil(legacy.relationship)
        XCTAssertEqual(legacy.readingParticipants.map(\.id), [profile.id])

        let oldPlan = try JSONDecoder().decode(OraclePlan.self, from: removing(["participantIDs", "participantNames", "profileUpdates", "relationship"], from: plan(people: [profile])))
        XCTAssertNil(oldPlan.participantIDs)
        XCTAssertNil(oldPlan.participantNames)
        XCTAssertNil(oldPlan.profileUpdates)
        XCTAssertNil(oldPlan.relationship)
        let result = OracleResult(method: .bazi, headline: "旧结果", rows: [])
        let oldResult = try JSONDecoder().decode(OracleResult.self, from: removing(["participantID", "participantName"], from: result))
        XCTAssertNil(oldResult.participantID)
        XCTAssertNil(oldResult.participantName)
        XCTAssertEqual(oldResult.displayTitle, OracleMethod.bazi.title)
    }

    func testExplicitEmptyParticipantsDoNotReuseLegacyProfileAndIDsAreDeduplicated() {
        let first = person("张三"), second = person("李四")
        var request = input(people: [])
        XCTAssertTrue(request.readingParticipants.isEmpty)
        request.participants = [first, first, second]
        XCTAssertEqual(request.readingParticipants.map(\.id), [first.id, second.id])
        request.participants = nil
        XCTAssertEqual(request.readingParticipants.map(\.id), [request.profile.id])
    }

    @MainActor func testLegacySelfMigrationNeverPromotesFriendAfterEmptyFirstProfileIsRemoved() throws {
        var friend = OracleProfile()
        friend.displayName = "张三"
        var selfPlan = plan()
        selfPlan.subject = "本人"; selfPlan.participantIDs = nil

        let emptyFirstVault = try temporaryVault()
        try emptyFirstVault.save([OracleProfile(), friend], as: "profiles")
        let withoutSelf = OracleStore(vault: emptyFirstVault, bootstrapCredential: false)
        XCTAssertEqual(withoutSelf.profiles.map(\.id), [friend.id])
        XCTAssertNil(withoutSelf.selfProfileID)
        XCTAssertTrue(withoutSelf.defaultParticipants(for: selfPlan).isEmpty)
        let restartedWithoutSelf = OracleStore(vault: emptyFirstVault, bootstrapCredential: false)
        XCTAssertNil(restartedWithoutSelf.selfProfileID)
        XCTAssertTrue(restartedWithoutSelf.defaultParticipants(for: selfPlan).isEmpty)

        let knownFirstVault = try temporaryVault()
        var originalSelf = person("李四")
        originalSelf.name = nil
        try knownFirstVault.save([originalSelf, friend], as: "profiles")
        let withSelf = OracleStore(vault: knownFirstVault, bootstrapCredential: false)
        XCTAssertEqual(withSelf.selfProfileID, originalSelf.id)
        XCTAssertEqual(withSelf.defaultParticipants(for: selfPlan).map(\.id), [originalSelf.id])
        let restartedWithSelf = OracleStore(vault: knownFirstVault, bootstrapCredential: false)
        XCTAssertEqual(restartedWithSelf.selfProfileID, originalSelf.id)
    }

    func testRegistryCalculatesPersonalMethodsForEachPersonAndEventMethodOnlyOnce() async throws {
        let first = person("张三"), second = person("李四", birth: "1996-03-04T14:00:00+08:00")
        let calls = Calls()
        let registry = PluginRegistry(plugins: [SnapshotPlugin(method: .bazi, calls: calls), SnapshotPlugin(method: .meihua, calls: calls)])
        let request = input(people: [first, second])
        let results = await registry.calculate(request, methods: [.bazi, .meihua]) { _ in }
        let personal = results.filter { $0.method == .bazi }
        XCTAssertEqual(results.count, 3)
        XCTAssertEqual(Set(results.map(\.id)).count, 3)
        XCTAssertEqual(Set(personal.compactMap(\.participantID)), [first.id, second.id])
        XCTAssertEqual(Set(personal.compactMap(\.participantName)), ["张三", "李四"])
        for result in personal {
            XCTAssertTrue(result.displayTitle.contains(try XCTUnwrap(result.participantName)))
            XCTAssertEqual(result.rows.first?.value, result.participantName)
        }
        XCTAssertEqual(results.filter { $0.method == .meihua }.count, 1)
        XCTAssertNil(results.first { $0.method == .meihua }?.participantID)
        let recorded = await calls.snapshot()
        XCTAssertEqual(Set(recorded.filter { $0.method == .bazi }.map(\.profileID)), [first.id, second.id])
        XCTAssertEqual(recorded.filter { $0.method == .meihua }.count, 1)
        XCTAssertFalse(recorded.filter { $0.method == .bazi }.contains { $0.profileID == request.profile.id })
    }

    func testNoParticipantDoesNotExecutePersonalPluginWithUnrelatedSavedPerson() async {
        let calls = Calls()
        let registry = PluginRegistry(plugins: [SnapshotPlugin(method: .bazi, calls: calls), SnapshotPlugin(method: .meihua, calls: calls)])
        _ = await registry.calculate(input(people: []), methods: [.bazi, .meihua]) { _ in }
        let recorded = await calls.snapshot()
        XCTAssertFalse(recorded.contains { $0.method == .bazi })
        XCTAssertEqual(recorded.filter { $0.method == .meihua }.count, 1)
    }

    @MainActor func testSavingAndUpdatingNamedPeoplePreservesSeparateIDsAndHistoricalInputs() throws {
        let vault = try temporaryVault()
        let store = OracleStore(vault: vault, bootstrapCredential: false)
        let first = person("张三"), second = person("李四")
        store.saveProfile(first)
        store.saveProfile(second)
        let savedSecond = try XCTUnwrap(store.profiles.first { $0.id == second.id })
        var selfPlan = plan()
        selfPlan.subject = "本人"; selfPlan.participantIDs = nil
        XCTAssertTrue(store.defaultParticipants(for: selfPlan).isEmpty)
        XCTAssertEqual(store.defaultParticipants(for: plan(people: [second])).map(\.id), [second.id])
        let request = input(people: [first, second])
        store.runs = [OracleRun(input: request, plan: plan(people: [first, second]))]
        var updated = first
        updated.birthPlace = "上海"
        store.saveProfile(updated)
        XCTAssertEqual(store.profiles.filter { $0.resolvedName == "张三" }.map(\.id), [first.id])
        XCTAssertEqual(store.profiles.first { $0.id == second.id }, savedSecond)
        XCTAssertEqual(store.runs.first?.input.participants?.first?.birthPlace, "北京")
        let restarted = OracleStore(vault: vault, bootstrapCredential: false)
        XCTAssertEqual(restarted.profiles.first { $0.id == first.id }?.birthPlace, "上海")
        XCTAssertEqual(restarted.profiles.first { $0.id == second.id }?.resolvedName, "李四")
        XCTAssertEqual(restarted.runs.first?.input.participants?.map(\.id), [first.id, second.id])
        XCTAssertEqual(restarted.runs.first?.input.participants?.first?.birthPlace, "北京")
    }

    @MainActor func testLocalChatCollectsTwoPeopleThenUpdatesOnlyNamedPersonAcrossRelaunch() async throws {
        let vault = try temporaryVault()
        let store = OracleStore(vault: vault, bootstrapCredential: false)
        store.send("张三，男，1995年1月2日出生；李四，女，1996年3月4日出生")
        try await waitUntilIdle(store)
        let first = try XCTUnwrap(store.profiles.first { $0.resolvedName == "张三" })
        let second = try XCTUnwrap(store.profiles.first { $0.resolvedName == "李四" })
        XCTAssertNotEqual(first.id, second.id)
        XCTAssertNotEqual(first.birthDate, second.birthDate)
        store.send("张三出生时间08:30，出生地北京")
        try await waitUntilIdle(store)
        let updated = try XCTUnwrap(store.profiles.first { $0.id == first.id })
        XCTAssertEqual(updated.birthTimeText, "08:30")
        XCTAssertEqual(updated.birthPlace, "北京")
        XCTAssertEqual(store.profiles.first { $0.id == second.id }, second)
        XCTAssertEqual(store.profiles.filter { $0.resolvedName == "张三" }.count, 1)
        let restarted = OracleStore(vault: vault, bootstrapCredential: false)
        XCTAssertEqual(restarted.profiles.first { $0.id == first.id }?.birthTimeText, "08:30")
        XCTAssertEqual(restarted.profiles.first { $0.id == first.id }?.birthPlace, "北京")
        let restoredSecond = try XCTUnwrap(restarted.profiles.first { $0.id == second.id })
        XCTAssertEqual(restoredSecond.resolvedName, second.resolvedName)
        XCTAssertEqual(restoredSecond.birthDate, second.birthDate)
        XCTAssertEqual(restoredSecond.birthDateText, second.birthDateText)
        XCTAssertEqual(restoredSecond.birthTimeText, second.birthTimeText)
        XCTAssertEqual(restoredSecond.unknownFields, second.unknownFields)
    }

    @MainActor func testAmbiguousSameNameChatCannotMergeEitherSavedPerson() async throws {
        let vault = try temporaryVault()
        let store = OracleStore(vault: vault, bootstrapCredential: false)
        let first = person("张三")
        var second = person("张三", birth: "2001-03-04T14:00:00+08:00")
        second.birthPlace = "上海"
        store.saveProfile(first)
        store.saveProfile(second)
        let before = store.profiles.filter { $0.resolvedName == "张三" }
        XCTAssertEqual(Set(before.map(\.id)), [first.id, second.id])
        store.send("张三出生地广州")
        try await waitUntilIdle(store)
        let after = store.profiles.filter { $0.resolvedName == "张三" }
        XCTAssertEqual(after, before)

        let previousSelf = person("李四")
        store.saveProfile(previousSelf)
        store.selfProfileID = previousSelf.id
        store.send("我是张三")
        try await waitUntilIdle(store)
        XCTAssertNil(store.selfProfileID)
        var selfPlan = plan()
        selfPlan.subject = "本人"; selfPlan.participantIDs = nil
        XCTAssertTrue(store.defaultParticipants(for: selfPlan).isEmpty)
    }

    @MainActor func testSelfAndNewPersonStatementsCannotOverwritePendingOtherPersonsBirthDate() async throws {
        let vault = try temporaryVault()
        let store = OracleStore(vault: vault, bootstrapCredential: false)
        let selected = person("张三"), own = person("李四", birth: "1996-03-04T14:00:00+08:00")
        store.saveProfile(selected); store.saveProfile(own)
        store.selfProfileID = own.id
        var pending = plan(people: [selected])
        pending.subject = "他人"
        let selfStatement = "我的生日是1991年2月3日"
        store.pendingPlan = pending
        store.send(selfStatement)
        try await waitUntilIdle(store)
        XCTAssertEqual(store.profiles.first { $0.id == selected.id }?.birthDate, selected.birthDate)
        XCTAssertEqual(store.profiles.first { $0.id == own.id }?.birthDateText, "1991-02-03")
        let updatedOwnDate = store.profiles.first { $0.id == own.id }?.birthDate

        let wronglyAssigned = ProfileUpdate(id: selected.id, name: selected.resolvedName, birthDate: "1991-02-03")
        XCTAssertTrue(ProfileDirectory.groundedUpdates([wronglyAssigned], in: selfStatement,
                                                       profiles: store.profiles, contextIDs: [own.id]).isEmpty)
        let unnamed = ProfileUpdate(birthDate: "1991-02-03")
        let groundedSelf = ProfileDirectory.groundedUpdates([unnamed], in: selfStatement,
                                                            profiles: store.profiles, contextIDs: [own.id])
        XCTAssertEqual(groundedSelf.map(\.id), [own.id])

        let newPersonStatement = "另外一位朋友出生日期2000年1月1日"
        store.pendingPlan = pending
        store.send(newPersonStatement)
        try await waitUntilIdle(store)
        XCTAssertEqual(store.profiles.first { $0.id == selected.id }?.birthDate, selected.birthDate)
        XCTAssertEqual(store.profiles.first { $0.id == own.id }?.birthDate, updatedOwnDate)
        XCTAssertTrue(ProfileDirectory.groundedUpdates([ProfileUpdate(birthDate: "2000-01-01")], in: newPersonStatement,
                                                       profiles: store.profiles, contextIDs: []).isEmpty)
        store.pendingPlan = pending
        store.send("出生日期1992年4月5日")
        try await waitUntilIdle(store)
        XCTAssertEqual(store.profiles.first { $0.id == selected.id }?.birthDateText, "1992-04-05")
        XCTAssertEqual(store.profiles.first { $0.id == own.id }?.birthDate, updatedOwnDate)
    }

    @MainActor func testGroupTarotWithoutTwoParticipantsOpensUnifiedFormBeforeInteraction() async throws {
        let vault = try temporaryVault()
        let store = OracleStore(vault: vault, bootstrapCredential: false)
        store.send("我们一起用塔罗看看友情")
        try await waitUntilIdle(store)
        XCTAssertEqual(store.pendingPlan?.subject, "多人")
        XCTAssertEqual(store.pendingPlan?.methods, [.tarot])
        XCTAssertTrue(store.showIntake)
        XCTAssertTrue(store.pendingPlan?.requestedFields?.isEmpty ?? true)
        XCTAssertEqual(store.phase, .awaitingIntake)
        XCTAssertNil(store.pendingInteraction)
        XCTAssertFalse(store.showInteraction)
        XCTAssertTrue(store.runs.isEmpty)
    }

    @MainActor func testGroupIntakeRequiresTwoDistinctNamedPeopleAndKeepsBothSnapshots() async throws {
        let vault = try temporaryVault()
        let store = OracleStore(vault: vault, bootstrapCredential: false)
        let first = person("张三"), second = person("李四")
        store.pendingPlan = plan(people: [first, second])
        store.confirmGroupIntake(profiles: [first, first], numbers: [], save: false)
        XCTAssertTrue(store.runs.isEmpty)
        XCTAssertNotNil(store.pendingPlan)
        var unnamed = second
        unnamed.name = ""; unnamed.familyName = ""; unnamed.givenName = ""; unnamed.displayName = ""
        store.confirmGroupIntake(profiles: [first, unnamed], numbers: [], save: false)
        XCTAssertTrue(store.runs.isEmpty)
        XCTAssertNotNil(store.pendingPlan)
        store.confirmGroupIntake(profiles: [first, second], numbers: [], save: false)
        try await waitUntilIdle(store)
        let run = try XCTUnwrap(store.runs.first)
        XCTAssertEqual(run.input.participants?.map(\.id), [first.id, second.id])
        XCTAssertEqual(run.input.relationship, "合作")
        XCTAssertEqual(Set(run.results.compactMap(\.participantID)), [first.id, second.id])
    }

    func testAIPayloadIncludesEachPersonsSameMethodEvidenceWithoutMerging() async throws {
        let first = person("张三"), second = person("李四")
        let calls = Calls()
        let registry = PluginRegistry(plugins: [SnapshotPlugin(method: .bazi, calls: calls)])
        let request = input(people: [first, second])
        let results = await registry.calculate(request, methods: [.bazi]) { _ in }
        let run = OracleRun(input: request, plan: plan(people: [first, second]), results: results)
        let payload = try ReadingContextBuilder.payload(run: run, weights: PreferenceLearning.initial)
        XCTAssertEqual(results.count, 2)
        XCTAssertTrue(payload.contains(first.id.uuidString))
        XCTAssertTrue(payload.contains(second.id.uuidString))
        XCTAssertTrue(payload.contains("EVIDENCE-张三-bazi"))
        XCTAssertTrue(payload.contains("EVIDENCE-李四-bazi"))
        XCTAssertTrue(payload.contains("合作"))
    }

    @MainActor func testSeveralPeopleUsingSameMethodStillReceiveOnlyOnePreferenceVote() throws {
        let vault = try temporaryVault()
        let store = OracleStore(vault: vault, bootstrapCredential: false)
        let first = person("张三"), second = person("李四")
        var firstResult = OracleResult(method: .bazi, headline: "第一人的盘面", rows: [])
        firstResult.participantID = first.id; firstResult.participantName = first.resolvedName
        var secondResult = OracleResult(method: .bazi, headline: "第二人的盘面", rows: [])
        secondResult.participantID = second.id; secondResult.participantName = second.resolvedName
        let chosen = ReadingAlternative(id: "a", title: "先沟通", body: "一项方法对应两位参与人", supportingMethods: [.bazi, .bazi])
        let opposing = ReadingAlternative(id: "b", title: "先观察", body: "另一种取法", supportingMethods: [.meihua])
        var run = OracleRun(input: input(people: [first, second]), plan: plan(methods: [.bazi, .meihua], people: [first, second]),
                            results: [firstResult, secondResult, .init(method: .meihua, headline: "问事结果", rows: [])])
        run.synthesis = ReadingSynthesis(text: "两种处境", alternatives: [chosen, opposing])
        store.runs = [run]
        let initial = store.weights
        let expected = PreferenceLearning.updated(initial, chosen: [.bazi], opposing: [.meihua])
        store.select(chosen, for: run.id)
        for method in OracleMethod.allCases {
            XCTAssertEqual(try XCTUnwrap(store.weights[method.rawValue]), try XCTUnwrap(expected[method.rawValue]), accuracy: 1e-10)
        }
        let afterFirstChoice = store.weights
        store.select(chosen, for: run.id)
        XCTAssertEqual(store.weights, afterFirstChoice)
    }
}

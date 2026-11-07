import XCTest
@testable import BlindOracle

final class MeihuaWorkflowTests: XCTestCase {
    private func plan(methods: [OracleMethod] = [.meihua], requestedNumbers: Bool = true) -> OraclePlan {
        var value = OraclePlan(intent: "留数交互验收", subject: "事件", methods: methods,
                               requiredFields: requestedNumbers ? [.numbers] : [], note: "",
                               question: "这次出行怎样安排？")
        value.mandatoryMethods = methods
        return value
    }

    private func site() -> OracleProfile {
        var value = OracleProfile()
        value.currentPlace = "上海市黄浦区"
        value.currentLatitude = 31.2304; value.currentLongitude = 121.4737
        value.currentTimeZoneID = "Asia/Shanghai"
        return value
    }

    private func vault() throws -> LocalVault {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("meihua-workflow-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return LocalVault(directory: directory)
    }

    @MainActor private func store(pending: OraclePlan, vault: LocalVault? = nil) throws -> OracleStore {
        let value = OracleStore(vault: try vault ?? self.vault(), bootstrapCredential: false)
        value.messages = [ChatMessage(role: .user, content: pending.question),
                          ChatMessage(role: .assistant, content: "请确认资料", kind: .intake)]
        value.pendingPlan = pending; value.showIntake = true
        return value
    }

    @MainActor private func waitUntilIdle(_ store: OracleStore) async throws {
        let deadline = Date().addingTimeInterval(5)
        while store.isBusy && Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertFalse(store.isBusy)
    }

    private func snapshot(_ run: OracleRun) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return try encoder.encode(run)
    }

    func testLegacyNumberRequirementPreparesTheInteractionWithoutInventingValuesOrGPS() {
        let pending = plan()
        XCTAssertNil(pending.interactions)
        let report = ReadingPreparationPolicy.evaluate(plan: pending, participants: [], descriptors: PluginRegistry().descriptors)
        XCTAssertTrue(report.canProceed)
        XCTAssertEqual(report.runnableMethods, [.meihua])
        XCTAssertTrue(report.assessments.first?.requiresUserInteraction == true)
        XCTAssertTrue(report.assessments.first?.blocking.isEmpty == true)
        XCTAssertFalse(ReadingPreparationPolicy.requiresCastingLocation(plan: pending, method: .meihua, numbers: []))
        XCTAssertEqual(OracleInteractionPolicy.requests(for: pending).map(\.kind), [.numbers])
        XCTAssertNil(pending.draftNumbers)
    }

    func testTimeAndTwoNumberModesStillNeedTheirRealCastingPlace() {
        let timed = plan(requestedNumbers: false)
        for numbers in [[], [12, 23]] {
            XCTAssertTrue(ReadingPreparationPolicy.requiresCastingLocation(plan: timed, method: .meihua, numbers: numbers))
            let report = ReadingPreparationPolicy.evaluate(plan: timed, participants: [], descriptors: PluginRegistry().descriptors,
                                                           numbers: numbers)
            XCTAssertFalse(report.canProceed)
            XCTAssertTrue(report.assessments.first?.blocking.contains { $0.field == .currentLocation } == true)
        }
        XCTAssertFalse(ReadingPreparationPolicy.requiresCastingLocation(plan: timed, method: .meihua, numbers: [12, 23, 6]))
    }

    @MainActor func testConfirmingDetailsStartsNumberSelectionAndOnlyCompleteNumbersStartCalculation() async throws {
        let store = try store(pending: plan())
        XCTAssertTrue(store.canConfirmIntake)
        XCTAssertTrue(store.confirmGroupIntake(profiles: [], numbers: [], save: false))
        let session = try XCTUnwrap(store.pendingInteraction)
        XCTAssertEqual(session.currentRequest?.kind, .numbers)
        XCTAssertTrue(session.input.numbers.isEmpty)
        XCTAssertNil(session.input.profile.currentLongitude)
        XCTAssertNil(store.pendingPlan)
        XCTAssertTrue(store.showInteraction)
        XCTAssertTrue(store.runs.isEmpty)

        store.completeInteraction(.init(requestID: "meihua", numbers: [8, 8]), sessionID: session.id)
        store.completeInteraction(.init(requestID: "meihua", numbers: [8, 8, 0]), sessionID: session.id)
        XCTAssertEqual(store.pendingInteraction?.id, session.id)
        XCTAssertTrue(store.runs.isEmpty)

        let numbers = [8, 8, 6]
        store.completeInteraction(.init(requestID: "meihua", numbers: numbers), sessionID: session.id)
        try await waitUntilIdle(store)
        let run = try XCTUnwrap(store.runs.first)
        XCTAssertNil(store.pendingInteraction)
        XCTAssertEqual(run.input.numbers, numbers)
        XCTAssertEqual(run.input.seed, session.input.seed)
        XCTAssertEqual(run.input.castingDate, session.input.castingDate)
        XCTAssertEqual(run.input.interactionResponses?.first?.numbers, numbers)
        XCTAssertTrue(run.results.contains { $0.method == .meihua && [.complete, .partial].contains($0.status) })
        XCTAssertTrue(run.results.first { $0.method == .meihua }?.rows.contains {
            $0.label == L10n.text("所留数字", "Your numbers")
                && $0.value == numbers.map(String.init).joined(separator: L10n.text("、", ", "))
        } == true)

        store.retrySynthesis(run)
        try await waitUntilIdle(store)
        XCTAssertEqual(store.runs.count, 1)
        XCTAssertEqual(store.runs.first?.input.numbers, numbers)
        XCTAssertEqual(store.runs.first?.results.map(\.id), run.results.map(\.id))
    }

    @MainActor func testPendingNumbersDoNotWaiveAnotherMethodsLocationRequirement() throws {
        let pending = plan(methods: [.meihua, .qimen])
        let report = ReadingPreparationPolicy.evaluate(plan: pending, participants: [], descriptors: PluginRegistry().descriptors)
        XCTAssertTrue(report.assessments.first { $0.method == .meihua }?.canExecute == true)
        XCTAssertTrue(report.assessments.first { $0.method == .qimen }?.blocking.contains { $0.field == .currentLocation } == true)
        XCTAssertTrue(ReadingPreparationPolicy.requiresCastingLocation(plan: pending, method: .qimen, numbers: []))
        XCTAssertFalse(report.canProceed)

        let store = try store(pending: pending)
        XCTAssertFalse(store.confirmGroupIntake(profiles: [], numbers: [], save: false))
        XCTAssertNil(store.pendingInteraction)
        XCTAssertTrue(store.runs.isEmpty)
        XCTAssertTrue(store.confirmGroupIntake(profiles: [], numbers: [], save: false, castingProfile: site()))
        XCTAssertEqual(store.pendingInteraction?.currentRequest?.kind, .numbers)
        XCTAssertEqual(store.pendingInteraction?.input.profile.currentLongitude, site().currentLongitude)
        XCTAssertTrue(store.runs.isEmpty)
        store.cancelPendingReading()
    }

    @MainActor func testIncompleteAndInvalidOldValuesMoveToTheInteractionForCorrection() throws {
        for values in [[12], [12, 23], [0, 23, 6], [12, 23, 1000]] {
            let store = try store(pending: plan())
            XCTAssertTrue(store.confirmGroupIntake(profiles: [], numbers: values, save: false), "\(values)")
            XCTAssertEqual(store.pendingInteraction?.currentRequest?.kind, .numbers, "\(values)")
            XCTAssertEqual(store.pendingInteraction?.input.numbers, values, "\(values)")
            XCTAssertTrue(store.runs.isEmpty, "\(values)")
            store.cancelPendingReading()
        }
        let legacy = try store(pending: plan(requestedNumbers: false))
        XCTAssertTrue(legacy.confirmGroupIntake(profiles: [], numbers: [0, 23, 6], save: false))
        XCTAssertEqual(legacy.pendingInteraction?.currentRequest?.kind, .numbers)
        XCTAssertTrue(legacy.runs.isEmpty)
        legacy.cancelPendingReading()
    }

    @MainActor func testPartiallyEditedNumberSlotsSurviveRestartWithoutChangingTheCastSnapshot() throws {
        let vault = try vault()
        let store = try store(pending: plan(), vault: vault)
        XCTAssertTrue(store.confirmGroupIntake(profiles: [], numbers: [], save: false))
        let original = try XCTUnwrap(store.pendingInteraction)
        let draft = OracleInteractionResponse(requestID: "meihua", numberTexts: ["8", "", "6"])
        store.saveInteractionProgress(draft, sessionID: original.id)
        let restored = OracleStore(vault: vault, bootstrapCredential: false)
        let session = try XCTUnwrap(restored.pendingInteraction)
        XCTAssertEqual(session.id, original.id)
        XCTAssertEqual(session.input.seed, original.input.seed)
        XCTAssertEqual(Int(session.input.castingDate.timeIntervalSince1970), Int(original.input.castingDate.timeIntervalSince1970))
        XCTAssertEqual(session.draft, draft)
        XCTAssertTrue(session.input.numbers.isEmpty)
        XCTAssertTrue(restored.runs.isEmpty)
        restored.completeInteraction(draft, sessionID: session.id)
        XCTAssertTrue(restored.runs.isEmpty)
        XCTAssertEqual(restored.pendingInteraction?.draft, draft)
        restored.cancelPendingReading()
    }

    @MainActor func testSupplementsKeepCompletedTwoAndThreeNumberModesInsteadOfRequestingThemAgain() async throws {
        for numbers in [[12, 23], [12, 23, 6]] {
            let originalPlan = plan()
            let input = OracleInput(question: originalPlan.question, profile: site(),
                                    castingDate: Date(timeIntervalSince1970: 1_730_000_000), numbers: numbers,
                                    seed: 73, subject: "事件")
            let result = try await MeihuaPlugin().calculate(input)
            XCTAssertTrue([.complete, .partial].contains(result.status))
            let original = OracleRun(input: input, plan: originalPlan, results: [result], synthesis: .init(text: "原有解读"))
            let originalData = try snapshot(original)
            let store = try store(pending: plan())
            store.runs = [original]
            var pending = try XCTUnwrap(store.pendingPlan)
            pending.action = "supplement"; pending.baseRunID = original.id; pending.followUpQuestion = "把原结论展开"
            pending.castingProfile = input.profile
            store.pendingPlan = pending
            XCTAssertTrue(store.confirmGroupIntake(profiles: [], numbers: numbers, save: false))
            XCTAssertNil(store.pendingInteraction, "\(numbers)")
            try await waitUntilIdle(store)
            let supplemented = try XCTUnwrap(store.runs.last)
            XCTAssertEqual(store.runs.count, 2)
            XCTAssertEqual(supplemented.input.numbers, numbers)
            XCTAssertEqual(supplemented.input.seed, input.seed)
            XCTAssertEqual(supplemented.input.castingDate, input.castingDate)
            XCTAssertEqual(supplemented.results.first { $0.method == .meihua }?.id, result.id)
            XCTAssertEqual(try snapshot(try XCTUnwrap(store.runs.first)), originalData)
        }
    }
}

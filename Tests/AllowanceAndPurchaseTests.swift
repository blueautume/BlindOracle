import XCTest
@testable import BlindOracle

final class AllowanceAndPurchaseTests: XCTestCase {
    private func api() -> AccountAPI {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [AllowanceURLProtocol.self]
        return AccountAPI(configuration: config)
    }
    private func session(_ id: UUID = UUID()) throws -> AccountSession {
        try AccountSession(response: AccountTokenResponse(accessToken: "fixture-access", refreshToken: "fixture-refresh", expiresIn: 3600,
            user: AccountUser(id: id.uuidString, displayName: "测试", email: nil, createdAt: "2026-11-06T00:00:00Z")), appleUserID: nil)
    }
    private func directory() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true) }
    private let wallet = #"{"quota":{"remaining_percent":75,"is_unlimited":false,"can_start":true}}"#
    override func tearDown() { AllowanceURLProtocol.handler = nil; super.tearDown() }
    func testQuotaDecodesWithoutLegacyBalanceFieldsAndUnlimitedStaysAtFull() throws {
        let ordinary = try JSONDecoder().decode(AccountWallet.self, from: Data(wallet.utf8))
        XCTAssertEqual(ordinary.quota?.displayedPercent, 75)
        let unlimited = try JSONDecoder().decode(AccountWallet.self, from: Data(#"{"quota":{"remaining_percent":0,"is_unlimited":true,"can_start":true}}"#.utf8))
        XCTAssertEqual(unlimited.quota?.displayedPercent, 100)
        let refundHold = try JSONDecoder().decode(AccountWallet.self, from: Data(#"{"quota":{"remaining_percent":0,"is_unlimited":true,"can_start":false}}"#.utf8))
        XCTAssertEqual(refundHold.quota?.displayedPercent, 0)
        let legacy = try JSONDecoder().decode(AccountWallet.self, from: Data(#"{"available_credits":100}"#.utf8))
        XCTAssertNil(legacy.quota, "Old responses must not invent a percentage")
    }
    @MainActor func testServerConfirmedOwnedPurchaseFinishesOnlyAfterDelivery() async throws {
        let buyer = UUID(); let client = api()
        let manager = AccountSessionManager(api: client, vault: PurchaseVault(try session(buyer)))
        let store = AccountPurchaseStore(api: client, sessions: manager)
        let finished = PurchaseFinishCounter()
        AllowanceURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.absoluteString, AccountAPI.baseURL.appendingPathComponent("purchases/apple/verify/").absoluteString)
            let body = try JSONSerialization.jsonObject(with: AllowanceURLProtocol.body(request)) as? [String: String]
            XCTAssertEqual(body, ["transaction_id": "12345", "environment": ServiceEnvironment.current.storeKitEnvironment])
            return .init(body: "{\"transaction_id\":\"12345\",\"status\":\"credited\",\"wallet\":" + self.wallet + "}")
        }
        await store.deliver(VerifiedAccountPurchase(transactionID: "12345", appAccountToken: buyer, environment: ServiceEnvironment.current.storeKitEnvironment)) { await finished.finish() }
        let count = await finished.count; XCTAssertEqual(count, 1)
        XCTAssertTrue(store.message?.contains("已补充") == true)
    }
    @MainActor func testUnconfirmedPurchaseNeverFinishesOrClaimsDelivery() async throws {
        for status in [422, 503] {
            let buyer = UUID(); let client = api()
            let store = AccountPurchaseStore(api: client, sessions: AccountSessionManager(api: client, vault: PurchaseVault(try session(buyer))))
            let finished = PurchaseFinishCounter()
            AllowanceURLProtocol.handler = { _ in .init(status: status, body: #"{"error":{"code":"verification_pending","message":"unavailable"}}"#) }
            await store.deliver(VerifiedAccountPurchase(transactionID: "12345", appAccountToken: buyer, environment: ServiceEnvironment.current.storeKitEnvironment)) { await finished.finish() }
            let count = await finished.count; XCTAssertEqual(count, 0)
            XCTAssertFalse(store.message?.contains("已补充") == true)
        }
    }
    @MainActor func testPurchaseForAnotherAccountIsNotSubmittedOrFinished() async throws {
        let client = api(); let store = AccountPurchaseStore(api: client, sessions: AccountSessionManager(api: client, vault: PurchaseVault(try session())))
        let unexpected = expectation(description: "No request for another account"); unexpected.isInverted = true
        AllowanceURLProtocol.handler = { _ in unexpected.fulfill(); return .init(body: "{}") }
        let finished = PurchaseFinishCounter()
        await store.deliver(VerifiedAccountPurchase(transactionID: "12345", appAccountToken: UUID(), environment: ServiceEnvironment.current.storeKitEnvironment)) { await finished.finish() }
        let count = await finished.count; XCTAssertEqual(count, 0)
        await fulfillment(of: [unexpected], timeout: 0.1)
    }
    @MainActor func testEachBuildRejectsPurchasesFromTheOtherStoreKitEnvironment() async throws {
        let buyer = UUID(); let client = api()
        let manager = AccountSessionManager(api: client, vault: PurchaseVault(try session(buyer)))
        let unexpected = expectation(description: "No cross-environment verification"); unexpected.isInverted = true
        AllowanceURLProtocol.handler = { _ in unexpected.fulfill(); return .init(body: "{}") }
        let finished = PurchaseFinishCounter()
        for environment in [ServiceEnvironment.production, .sandbox] {
            let store = AccountPurchaseStore(api: client, sessions: manager, environment: environment)
            let other = environment == .production ? "Sandbox" : "Production"
            await store.deliver(VerifiedAccountPurchase(transactionID: "12345", appAccountToken: buyer, environment: other)) { await finished.finish() }
        }
        let count = await finished.count; XCTAssertEqual(count, 0)
        await fulfillment(of: [unexpected], timeout: 0.1)
    }
    @MainActor func testAccountSwitchDuringVerificationLeavesPurchaseUnfinished() async throws {
        let buyer = UUID(); let client = api(); let manager = AccountSessionManager(api: client, vault: PurchaseVault(try session(buyer)))
        let store = AccountPurchaseStore(api: client, sessions: manager)
        let started = expectation(description: "Verification started")
        AllowanceURLProtocol.handler = { _ in started.fulfill(); return .init(body: "{\"transaction_id\":\"12345\",\"status\":\"credited\",\"wallet\":" + self.wallet + "}", delay: 0.15) }
        let finished = PurchaseFinishCounter()
        let flight = Task { await store.deliver(VerifiedAccountPurchase(transactionID: "12345", appAccountToken: buyer, environment: ServiceEnvironment.current.storeKitEnvironment)) { await finished.finish() } }
        await fulfillment(of: [started], timeout: 2)
        try await manager.install(session())
        await flight.value
        let count = await finished.count; XCTAssertEqual(count, 0)
        XCTAssertNil(store.message)
    }
    func testTaskRetriesReuseOriginalBodyAcrossServiceRestartAndRepair() async throws {
        let folder = directory(); defer { try? FileManager.default.removeItem(at: folder) }
        let client = api(); let manager = AccountSessionManager(api: client, vault: PurchaseVault(try session()))
        let stage = AIQuotaStage(taskID: UUID(), stageID: "answer")
        AllowanceURLProtocol.handler = { request in
            if request.url?.absoluteString.hasSuffix("/end/") == true {
                XCTAssertEqual(request.value(forHTTPHeaderField: "X-Task-Token"), "fixture-admission")
                return .init(status: 204, body: "")
            }
            return .init(body: "{\"task_id\":\"" + ServiceEnvironment.current.serverTaskID(for: stage.taskID).uuidString + "\",\"state\":\"open\",\"admission_token\":\"fixture-admission\"}")
        }
        let first = AIQuotaTaskService(directory: folder, api: client, sessions: manager)
        let original = Data(#"{"purpose":"synthesize","messages":[{"content":"original-snapshot"}]}"#.utf8)
        let initial = try await first.prepare(stage: stage, body: original, purpose: "synthesize")
        XCTAssertEqual(initial.body, original)
        try await first.markRepair(stage, needed: true)
        let restarted = AIQuotaTaskService(directory: folder, api: client, sessions: manager)
        let retry = try await restarted.prepare(stage: stage, body: Data("changed timestamp/context".utf8), purpose: "synthesize")
        XCTAssertEqual(retry.body, original); XCTAssertEqual(retry.stageID, initial.stageID); XCTAssertTrue(retry.needsRepair)
        await restarted.end(stage.taskID, status: "completed")
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent(ServiceEnvironment.current.serverTaskID(for: stage.taskID).uuidString.lowercased()).path))
    }
    func testTaskCannotBeAdoptedByAnotherAccount() async throws {
        let folder = directory(); defer { try? FileManager.default.removeItem(at: folder) }
        let client = api(); let manager = AccountSessionManager(api: client, vault: PurchaseVault(try session()))
        let stage = AIQuotaStage(taskID: UUID(), stageID: "plan:fixture")
        AllowanceURLProtocol.handler = { _ in .init(body: "{\"task_id\":\"" + ServiceEnvironment.current.serverTaskID(for: stage.taskID).uuidString + "\",\"state\":\"open\",\"admission_token\":\"fixture-admission\"}") }
        let service = AIQuotaTaskService(directory: folder, api: client, sessions: manager)
        _ = try await service.prepare(stage: stage, body: Data("original".utf8), purpose: "plan")
        try await manager.install(session())
        do { _ = try await service.prepare(stage: stage, body: Data("new".utf8), purpose: "plan"); XCTFail("Cannot transfer a task between accounts") }
        catch { XCTAssertEqual(error as? AccountAPIError, .staleSession) }
    }
    func testTaskSnapshotsAndServerIDsAreSeparatedAcrossEnvironments() async throws {
        let folder = directory(); defer { try? FileManager.default.removeItem(at: folder) }
        let client = api(); let manager = AccountSessionManager(api: client, vault: PurchaseVault(try session()))
        let stage = AIQuotaStage(taskID: UUID(), stageID: "answer")
        AllowanceURLProtocol.handler = { request in
            let body = try JSONSerialization.jsonObject(with: AllowanceURLProtocol.body(request)) as? [String: String]
            let id = try XCTUnwrap(body?["task_id"])
            return .init(body: "{\"task_id\":\"" + id + "\",\"state\":\"open\",\"admission_token\":\"fixture-admission\"}")
        }
        let production = AIQuotaTaskService(directory: folder.appendingPathComponent(ServiceEnvironment.production.taskDirectoryName), api: client, sessions: manager, environment: .production)
        let sandbox = AIQuotaTaskService(directory: folder.appendingPathComponent(ServiceEnvironment.sandbox.taskDirectoryName), api: client, sessions: manager, environment: .sandbox)
        let first = try await production.prepare(stage: stage, body: Data("production body".utf8), purpose: "synthesize")
        let second = try await sandbox.prepare(stage: stage, body: Data("sandbox body".utf8), purpose: "synthesize")
        XCTAssertNotEqual(first.taskID, second.taskID)
        XCTAssertEqual(first.body, Data("production body".utf8)); XCTAssertEqual(second.body, Data("sandbox body".utf8))
        try await production.markRepair(stage, needed: true)
        let retry = try await sandbox.prepare(stage: stage, body: Data("changed".utf8), purpose: "synthesize")
        XCTAssertEqual(retry.body, second.body); XCTAssertFalse(retry.needsRepair)
    }
    func testCopiedProductionTaskTicketCannotBeAdoptedInSandbox() async throws {
        let folder = directory(); defer { try? FileManager.default.removeItem(at: folder) }
        let client = api(); let manager = AccountSessionManager(api: client, vault: PurchaseVault(try session()))
        let stage = AIQuotaStage(taskID: UUID(), stageID: "answer")
        AllowanceURLProtocol.handler = { _ in .init(body: "{\"task_id\":\"" + stage.taskID.uuidString + "\",\"state\":\"open\",\"admission_token\":\"fixture-production-ticket\"}") }
        let productionFolder = folder.appendingPathComponent("production")
        let production = AIQuotaTaskService(directory: productionFolder, api: client, sessions: manager, environment: .production)
        _ = try await production.prepare(stage: stage, body: Data("production body".utf8), purpose: "synthesize")
        let sandboxFolder = folder.appendingPathComponent("sandbox")
        try FileManager.default.createDirectory(at: sandboxFolder, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: productionFolder.appendingPathComponent(stage.taskID.uuidString.lowercased()),
            to: sandboxFolder.appendingPathComponent(ServiceEnvironment.sandbox.serverTaskID(for: stage.taskID).uuidString.lowercased()))
        let unexpected = expectation(description: "No request using a copied production ticket"); unexpected.isInverted = true
        AllowanceURLProtocol.handler = { _ in unexpected.fulfill(); return .init(body: "{}") }
        let sandbox = AIQuotaTaskService(directory: sandboxFolder, api: client, sessions: manager, environment: .sandbox)
        do { _ = try await sandbox.prepare(stage: stage, body: Data("sandbox body".utf8), purpose: "synthesize"); XCTFail("Must reject cross-environment task records") }
        catch { XCTAssertEqual(error as? AccountAPIError, .staleSession) }
        await sandbox.flushPendingEnds()
        await fulfillment(of: [unexpected], timeout: 0.1)
    }
    func testDeletingConversationErasesRequestSnapshotsEvenWhenServerIsOffline() async throws {
        let folder = directory(); defer { try? FileManager.default.removeItem(at: folder) }
        let client = api(); let manager = AccountSessionManager(api: client, vault: PurchaseVault(try session()))
        let stage = AIQuotaStage(taskID: UUID(), stageID: "answer", conversationID: UUID())
        AllowanceURLProtocol.handler = { request in
            if request.url?.absoluteString.hasSuffix("/end/") == true { return .init(status: 503, body: "{}") }
            return .init(body: "{\"task_id\":\"" + ServiceEnvironment.current.serverTaskID(for: stage.taskID).uuidString + "\",\"state\":\"open\",\"admission_token\":\"fixture-admission\"}")
        }
        let service = AIQuotaTaskService(directory: folder, api: client, sessions: manager)
        _ = try await service.prepare(stage: stage, body: Data("private-request-snapshot".utf8), purpose: "synthesize")
        try await service.eraseConversation(stage.conversationID)
        let files = try FileManager.default.contentsOfDirectory(at: folder.appendingPathComponent(ServiceEnvironment.current.serverTaskID(for: stage.taskID).uuidString.lowercased()), includingPropertiesForKeys: nil)
        XCTAssertEqual(files.map(\.lastPathComponent), ["task.json"])
        do { _ = try await service.prepare(stage: stage, body: Data("new".utf8), purpose: "synthesize"); XCTFail("Deleted tasks cannot be resumed") } catch { }
    }
    @MainActor func testFailedBusinessTaskIDSurvivesRelaunchAndRetryButNewQuestionGetsNewTask() async throws {
        let folder = directory(); defer { try? FileManager.default.removeItem(at: folder) }
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [AllowanceURLProtocol.self]
        let client = DeepSeekClient(accessToken: "fixture-access", sessionConfiguration: config)
        AllowanceURLProtocol.handler = { _ in .init(status: 503, body: "{}") }
        let vault = LocalVault(directory: folder)
        var store = OracleStore(vault: vault, bootstrapCredential: false, aiClient: client)
        store.send("第一问：明天的工作怎么安排？")
        await idle(store)
        let firstID = try XCTUnwrap(store.quotaTaskID)
        XCTAssertTrue(store.canRetryAnalysis); store.checkpoint()
        store = OracleStore(vault: vault, bootstrapCredential: false, aiClient: client)
        XCTAssertEqual(store.quotaTaskID, firstID)
        store.retryAnalysis(); await idle(store)
        XCTAssertEqual(store.quotaTaskID, firstID)
        store.send("第二问：周末是否出行？"); await idle(store)
        XCTAssertNotEqual(store.quotaTaskID, firstID)
    }
    @MainActor func testOneTaskSpansPlanFormAndFinalAnswerAndSuccessfulNextQuestionGetsNewTask() async throws {
        let folder = directory(); defer { try? FileManager.default.removeItem(at: folder) }
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [AllowanceURLProtocol.self]
        let client = DeepSeekClient(accessToken: "fixture-access", sessionConfiguration: config)
        AllowanceURLProtocol.handler = { request in
            let body = try JSONSerialization.jsonObject(with: AllowanceURLProtocol.body(request)) as? [String: Any]
            if body?["stream"] as? Bool == true {
                let content = #"{"text":"先处理手头工作。","alternatives":"malformed-optional","tarotClarification":"malformed-optional"}"#
                let event = try JSONSerialization.data(withJSONObject: ["model": "deepseek-v4-pro", "choices": [["delta": ["content": content]]]])
                return .init(body: "data: " + String(decoding: event, as: UTF8.self) + "\n\ndata: {\"model\":\"deepseek-v4-pro\",\"choices\":[{\"delta\":{},\"finish_reason\":\"stop\"}]}\n\ndata: [DONE]\n\n")
            }
            let plan = #"{"action":"intake","intent":"工作安排","subject":"事件","methods":["xiaoliuren"],"requiredFields":[],"note":"请核对问事资料","interactions":"malformed-optional"}"#
            let envelope = try JSONSerialization.data(withJSONObject: ["model": "deepseek-v4-pro", "choices": [["message": ["content": plan], "finish_reason": "stop"]]])
            return .init(body: String(decoding: envelope, as: UTF8.self))
        }
        let store = OracleStore(vault: LocalVault(directory: folder), bootstrapCredential: false, aiClient: client)
        store.send("请用小六壬看看明天工作如何安排")
        await idle(store)
        let id = try XCTUnwrap(store.quotaTaskID)
        XCTAssertEqual(store.pendingPlan?.quotaTaskID, id)
        XCTAssertTrue(store.confirmIntake(profile: OracleProfile(), numbers: [], save: false))
        await idle(store)
        XCTAssertEqual(store.runs.last?.plan.quotaTaskID, id)
        XCTAssertNotNil(store.runs.last?.completedAt)
        XCTAssertEqual(store.runs.last?.synthesis?.text, "先处理手头工作。")
        XCTAssertNil(store.quotaTaskID)
        store.send("请用小六壬看下周的出行安排"); await idle(store)
        XCTAssertNotEqual(store.quotaTaskID, id)
    }
    @MainActor private func idle(_ store: OracleStore) async {
        for _ in 0..<200 { if !store.isBusy { return }; try? await Task.sleep(nanoseconds: 10_000_000) }
        XCTFail("The mocked operation should finish")
    }
}

private actor PurchaseFinishCounter { var count = 0; func finish() { count += 1 } }
private final class PurchaseVault: AccountSessionStorage {
    var value: AccountSession?
    init(_ value: AccountSession?) { self.value = value }
    func load() throws -> AccountSession? { value }
    func save(_ session: AccountSession) throws { value = session }
    func delete() throws { value = nil }
}
private final class AllowanceURLProtocol: URLProtocol {
    struct Response { var status = 200; var body: String; var delay: TimeInterval = 0 }
    static var handler: ((URLRequest) throws -> Response)?
    private var work: DispatchWorkItem?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            guard let handler = Self.handler else { throw URLError(.badServerResponse) }
            let value = try handler(request)
            let delivery = DispatchWorkItem { [weak self] in
                guard let self else { return }
                let response = HTTPURLResponse(url: self.request.url!, statusCode: value.status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
                self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                self.client?.urlProtocol(self, didLoad: Data(value.body.utf8)); self.client?.urlProtocolDidFinishLoading(self)
            }
            work = delivery; DispatchQueue.global().asyncAfter(deadline: .now() + value.delay, execute: delivery)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() { work?.cancel() }
    static func body(_ request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open(); defer { stream.close() }; var result = Data(); var bytes = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable { let count = stream.read(&bytes, maxLength: bytes.count); if count <= 0 { break }; result.append(bytes, count: count) }
        return result
    }
}

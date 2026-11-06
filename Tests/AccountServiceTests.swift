import XCTest
import Combine
@testable import BlindOracle

final class AccountServiceTests: XCTestCase {
    private func api() -> AccountAPI {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AuthURLProtocol.self]
        return AccountAPI(configuration: configuration)
    }
    override func tearDown() { AuthURLProtocol.handler = nil; super.tearDown() }
    private func session(expired: Bool = false, id: String = "fixture-user") throws -> AccountSession {
        let response = AccountTokenResponse(accessToken: "fixture-access", refreshToken: "fixture-refresh", expiresIn: expired ? 1 : 3600,
            user: AccountUser(id: id, displayName: "测试账号", email: nil, createdAt: "2026-11-06T00:00:00Z"))
        return try AccountSession(response: response, appleUserID: "fixture-apple-user", now: expired ? .distantPast : Date())
    }
    private var rotatedResponse: String {
        #"{"access_token":"fixture-rotated-access","refresh_token":"fixture-rotated-refresh","expires_in":3600,"user":{"id":"fixture-user","display_name":"测试账号","email":null,"created_at":"2026-11-06T00:00:00Z"}}"#
    }
    @MainActor func testLaunchWithoutSessionNeverUnlocksTheMainInterface() async throws {
        let noNetwork = expectation(description: "No authentication request without a saved session"); noNetwork.isInverted = true
        AuthURLProtocol.handler = { _ in noNetwork.fulfill(); return .init(body: "{}") }
        let client = api(); let store = AccountStore(api: client, sessions: AccountSessionManager(api: client, vault: MemoryAccountVault(nil)))
        XCTAssertEqual(store.accessState, .restoring); XCTAssertFalse(store.canAccessMain)
        await store.restore()
        XCTAssertEqual(store.accessState, .signedOut); XCTAssertFalse(store.canAccessMain)
        await fulfillment(of: [noNetwork], timeout: 0.1)
    }
    @MainActor func testStoredUserDoesNotUnlockMainUntilServerVerificationCompletes() async throws {
        let requested = expectation(description: "Server session validation started")
        var saved = try session(); saved.appleUserID = nil
        let body = String(decoding: try JSONEncoder().encode(saved.user), as: UTF8.self)
        AuthURLProtocol.handler = { _ in requested.fulfill(); return .init(body: body, delay: 0.15) }
        let client = api(); let store = AccountStore(api: client, sessions: AccountSessionManager(api: client, vault: MemoryAccountVault(saved)))
        var observed: [AccountAccessState] = []
        let observation = store.$accessState.sink { observed.append($0) }
        defer { observation.cancel() }
        let restore = Task { await store.restore() }
        await fulfillment(of: [requested], timeout: 2)
        XCTAssertNotNil(store.user); XCTAssertEqual(store.accessState, .restoring); XCTAssertFalse(store.canAccessMain)
        await restore.value
        XCTAssertEqual(store.accessState, .authenticated); XCTAssertTrue(store.canAccessMain)
        XCTAssertFalse(observed.contains(.signedOut), "A returning user must never mount the login screen while restoring")
    }
    @MainActor func testTemporaryRestoreFailureKeepsSessionAndOffersRetry() async throws {
        var saved = try session(); saved.appleUserID = nil
        let vault = MemoryAccountVault(saved); let client = api()
        let store = AccountStore(api: client, sessions: AccountSessionManager(api: client, vault: vault))
        var observed: [AccountAccessState] = []
        let observation = store.$accessState.sink { observed.append($0) }
        defer { observation.cancel() }
        AuthURLProtocol.handler = { _ in .init(status: 503, body: "{}") }
        await store.restore()
        XCTAssertFalse(store.canAccessMain); XCTAssertTrue(store.canRetrySession); XCTAssertNotNil(try vault.load())
        XCTAssertEqual(store.accessState, .recoveryRequired)
        let body = String(decoding: try JSONEncoder().encode(saved.user), as: UTF8.self)
        AuthURLProtocol.handler = { _ in .init(body: body) }
        await store.restore(force: true)
        XCTAssertTrue(store.canAccessMain); XCTAssertFalse(store.canRetrySession)
        XCTAssertFalse(observed.contains(.signedOut))
    }
    @MainActor func testExpiredReturningSessionRefreshesWithoutEverShowingSignIn() async throws {
        var saved = try session(expired: true); saved.appleUserID = nil
        let userBody = String(decoding: try JSONEncoder().encode(saved.user), as: UTF8.self)
        AuthURLProtocol.handler = { request in
            request.url?.absoluteString.hasSuffix("/auth/refresh/") == true ? .init(body: self.rotatedResponse, delay: 0.05) : .init(body: userBody)
        }
        let client = api(); let vault = MemoryAccountVault(saved)
        let store = AccountStore(api: client, sessions: AccountSessionManager(api: client, vault: vault))
        var observed: [AccountAccessState] = []
        let observation = store.$accessState.sink { observed.append($0) }; defer { observation.cancel() }
        await store.restore()
        XCTAssertTrue(store.canAccessMain); XCTAssertFalse(observed.contains(.signedOut))
        XCTAssertEqual(try vault.load()?.refreshToken, "fixture-rotated-refresh")
    }
    @MainActor func testOfflineRestorationPreservesCredentialsAndUsesRecoveryScreen() async throws {
        var saved = try session(); saved.appleUserID = nil
        let vault = MemoryAccountVault(saved); let client = api()
        let store = AccountStore(api: client, sessions: AccountSessionManager(api: client, vault: vault))
        AuthURLProtocol.handler = { _ in throw URLError(.notConnectedToInternet) }
        await store.restore()
        XCTAssertEqual(store.accessState, .recoveryRequired); XCTAssertTrue(store.canRetrySession)
        XCTAssertFalse(store.canAccessMain); XCTAssertEqual(try vault.load(), saved)
    }
    @MainActor func testLockedKeychainShowsRecoveryAndRetriesReadWithoutShowingSignIn() async throws {
        var saved = try session(); saved.appleUserID = nil
        let vault = MemoryAccountVault(saved); vault.shouldFailLoad = true
        let client = api(); let manager = AccountSessionManager(api: client, vault: vault)
        let store = AccountStore(api: client, sessions: manager)
        var observed: [AccountAccessState] = []
        let observation = store.$accessState.sink { observed.append($0) }; defer { observation.cancel() }
        await store.restore()
        XCTAssertEqual(store.accessState, .recoveryRequired); XCTAssertTrue(store.canRetrySession)
        vault.shouldFailLoad = false
        let userBody = String(decoding: try JSONEncoder().encode(saved.user), as: UTF8.self)
        AuthURLProtocol.handler = { _ in .init(body: userBody) }
        await store.restore(force: true)
        XCTAssertTrue(store.canAccessMain); XCTAssertFalse(observed.contains(.signedOut))
    }
    @MainActor func testChoosingSignInExplicitlyDiscardsUnrecoverableSavedSession() async throws {
        var saved = try session(); saved.appleUserID = nil
        let client = api(); let manager = AccountSessionManager(api: client, vault: MemoryAccountVault(saved))
        let store = AccountStore(api: client, sessions: manager)
        AuthURLProtocol.handler = { _ in .init(status: 503, body: "{}") }
        await store.restore(); XCTAssertEqual(store.accessState, .recoveryRequired)
        let logout = expectation(description: "Old session revocation attempted without blocking sign-in")
        AuthURLProtocol.handler = { _ in logout.fulfill(); return .init(status: 204, body: "") }
        await store.chooseSignIn()
        XCTAssertEqual(store.accessState, .signedOut); XCTAssertFalse(store.canRetrySession)
        let snapshot = await manager.snapshot(); XCTAssertNil(snapshot)
        await fulfillment(of: [logout], timeout: 2)
    }
    @MainActor func testFinalUnauthorizedRestorationRequiresActualSignIn() async throws {
        var saved = try session(); saved.appleUserID = nil
        AuthURLProtocol.handler = { request in
            request.url?.absoluteString.hasSuffix("/auth/refresh/") == true ? .init(body: self.rotatedResponse) : .init(status: 401, body: "{}")
        }
        let client = api(); let manager = AccountSessionManager(api: client, vault: MemoryAccountVault(saved))
        let store = AccountStore(api: client, sessions: manager)
        await store.restore()
        XCTAssertEqual(store.accessState, .signedOut); XCTAssertFalse(store.canRetrySession); XCTAssertNil(store.user)
        let snapshot = await manager.snapshot(); XCTAssertNil(snapshot)
    }
    @MainActor func testWalletFailureDoesNotInvalidateVerifiedLogin() async throws {
        var saved = try session(); saved.appleUserID = nil
        let body = String(decoding: try JSONEncoder().encode(saved.user), as: UTF8.self)
        AuthURLProtocol.handler = { request in
            request.url?.absoluteString.hasSuffix("/me/") == true ? .init(body: body) : .init(status: 503, body: "{}")
        }
        let client = api(); let store = AccountStore(api: client, sessions: AccountSessionManager(api: client, vault: MemoryAccountVault(saved)))
        await store.restore(); XCTAssertTrue(store.canAccessMain)
        await store.refreshOverview()
        XCTAssertTrue(store.canAccessMain); XCTAssertNil(store.wallet); XCTAssertNotNil(store.message)
    }
    @MainActor func testRejectedRefreshLocksGateEvenIfKeychainDeletionFails() async throws {
        var saved = try session(expired: true); saved.appleUserID = nil
        let vault = MemoryAccountVault(saved); vault.shouldFailDelete = true
        AuthURLProtocol.handler = { _ in .init(status: 401, body: "{}") }
        let client = api(); let manager = AccountSessionManager(api: client, vault: vault)
        let store = AccountStore(api: client, sessions: manager)
        await store.restore()
        XCTAssertFalse(store.canAccessMain); XCTAssertEqual(store.accessState, .signedOut); XCTAssertFalse(store.canRetrySession)
        let snapshot = await manager.snapshot(); XCTAssertNil(snapshot)
    }
    @MainActor func testLogoutAndServerDeletionStayLockedWhenSecureStorageIsUnavailable() async throws {
        for deleteAccount in [false, true] {
            var saved = try session(); saved.appleUserID = nil
            let body = String(decoding: try JSONEncoder().encode(saved.user), as: UTF8.self)
            AuthURLProtocol.handler = { request in request.httpMethod == "GET" ? .init(body: body) : .init(status: 204, body: "") }
            let vault = MemoryAccountVault(saved); vault.shouldFailDelete = true
            let client = api(); let manager = AccountSessionManager(api: client, vault: vault)
            let store = AccountStore(api: client, sessions: manager)
            await store.restore(); XCTAssertTrue(store.canAccessMain)
            if deleteAccount { await store.deleteAccount() } else { await store.logout() }
            XCTAssertFalse(store.canAccessMain); XCTAssertEqual(store.accessState, .signedOut)
            let snapshot = await manager.snapshot(); XCTAssertNil(snapshot)
            await store.restore(force: true); XCTAssertFalse(store.canAccessMain)
        }
    }
    @MainActor func testAppleRevocationLocksGateEvenIfSecureStorageDeletionFails() async throws {
        var saved = try session(); saved.appleUserID = nil
        let body = String(decoding: try JSONEncoder().encode(saved.user), as: UTF8.self)
        AuthURLProtocol.handler = { _ in .init(body: body) }
        let vault = MemoryAccountVault(saved); vault.shouldFailDelete = true
        let client = api(); let manager = AccountSessionManager(api: client, vault: vault)
        let store = AccountStore(api: client, sessions: manager)
        await store.restore(); XCTAssertTrue(store.canAccessMain)
        saved.appleUserID = "fixture-apple-user"; try await manager.install(saved)
        await store.credentialRevoked()
        XCTAssertFalse(store.canAccessMain); XCTAssertEqual(store.accessState, .signedOut)
        let snapshot = await manager.snapshot(); XCTAssertNil(snapshot)
    }
    @MainActor func testFinalUnauthorizedAfterRefreshLocksBothGatewayAndDeletion() async throws {
        for gateway in [true, false] {
            var saved = try session(); saved.appleUserID = nil
            let body = String(decoding: try JSONEncoder().encode(saved.user), as: UTF8.self)
            AuthURLProtocol.handler = { request in
                if request.url?.absoluteString.hasSuffix("/auth/refresh/") == true { return .init(body: self.rotatedResponse) }
                if request.httpMethod == "DELETE" || request.url?.absoluteString.contains("/ai/chat/") == true { return .init(status: 401, body: "{}") }
                return .init(body: body)
            }
            let client = api(); let manager = AccountSessionManager(api: client, vault: MemoryAccountVault(saved))
            let store = AccountStore(api: client, sessions: manager)
            await store.restore(); XCTAssertTrue(store.canAccessMain)
            if gateway {
                let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [AuthURLProtocol.self]
                do { _ = try await DeepSeekClient(accountSessions: manager, manageQuota: false, sessionConfiguration: configuration).checkConnection(); XCTFail("Expected invalid session") }
                catch { }
                await store.sessionChanged()
            } else { await store.deleteAccount() }
            XCTAssertFalse(store.canAccessMain); XCTAssertEqual(store.accessState, .signedOut)
            let snapshot = await manager.snapshot(); XCTAssertNil(snapshot)
        }
    }
    func testChallengeUsesRawNonceOnlyForHashAndLoginUsesSnakeCaseContract() async throws {
        let login = expectation(description: "Apple credential exchange")
        AuthURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.host, "wellecho.cn")
            if request.url?.absoluteString.hasSuffix("/challenge/") == true {
                XCTAssertEqual(request.httpMethod, "POST")
                return .init(body: #"{"challenge_id":"fixture-challenge","nonce":"abc","expires_in":300}"#)
            }
            XCTAssertEqual(request.url?.path, AccountAPI.baseURL.appendingPathComponent("auth/apple/").path)
            let body = try JSONSerialization.jsonObject(with: AuthURLProtocol.body(request)) as? [String: String]
            XCTAssertEqual(body?["identity_token"], "fixture-identity")
            XCTAssertEqual(body?["authorization_code"], "fixture-code")
            XCTAssertEqual(body?["challenge_id"], "fixture-challenge")
            XCTAssertEqual(body?["full_name"], "测试账号")
            XCTAssertNil(body?["nonce"])
            login.fulfill()
            return .init(body: self.rotatedResponse)
        }
        let client = api()
        let challenge = try await client.challenge()
        XCTAssertEqual(challenge.hashedNonce, "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        let tokens = try await client.signIn(challengeID: challenge.challengeID, identityToken: "fixture-identity", authorizationCode: "fixture-code", fullName: "测试账号")
        XCTAssertEqual(tokens.user.id, "fixture-user")
        await fulfillment(of: [login], timeout: 2)
    }
    func testExpiredSessionRefreshIsSingleFlightAndPersistsRotatedTokens() async throws {
        let refresh = expectation(description: "Exactly one refresh")
        refresh.assertForOverFulfill = true
        AuthURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.path, AccountAPI.baseURL.appendingPathComponent("auth/refresh/").path)
            refresh.fulfill()
            return .init(body: self.rotatedResponse, delay: 0.08)
        }
        let vault = MemoryAccountVault(try session(expired: true))
        let manager = AccountSessionManager(api: api(), vault: vault)
        let values = try await withThrowingTaskGroup(of: String.self) { group in
            for _ in 0..<12 { group.addTask { try await manager.accessToken() } }
            var results: [String] = []
            for try await value in group { results.append(value) }
            return results
        }
        XCTAssertEqual(values.count, 12)
        XCTAssertEqual(Set(values), ["fixture-rotated-access"])
        XCTAssertEqual(try vault.load()?.refreshToken, "fixture-rotated-refresh")
        await fulfillment(of: [refresh], timeout: 2)
    }
    func testRefreshCompletingAfterLogoutCannotRestorePreviousAccount() async throws {
        let started = expectation(description: "Refresh started")
        AuthURLProtocol.handler = { _ in started.fulfill(); return .init(body: self.rotatedResponse, delay: 0.2) }
        let vault = MemoryAccountVault(try session(expired: true))
        let manager = AccountSessionManager(api: api(), vault: vault)
        let flight = Task { try await manager.accessToken() }
        await fulfillment(of: [started], timeout: 2)
        try await manager.clear()
        do { _ = try await flight.value; XCTFail("Logged-out refresh must not return a token") } catch { }
        let snapshot = await manager.snapshot()
        XCTAssertNil(snapshot); XCTAssertNil(try vault.load())
    }
    func testInvalidRefreshClearsSessionRatherThanRetryingRotatedRefreshToken() async throws {
        AuthURLProtocol.handler = { _ in .init(status: 401, body: #"{"error":{"code":"invalid_refresh","message":"private-server-detail"}}"#) }
        let vault = MemoryAccountVault(try session(expired: true))
        let manager = AccountSessionManager(api: api(), vault: vault)
        do { _ = try await manager.accessToken(); XCTFail("Expected authorization failure") }
        catch { XCTAssertEqual(error as? AccountAPIError, .unauthorized) }
        XCTAssertNil(try vault.load())
    }
    func testOldGatewayAuthorizationCannotUseANewAccountsToken() async throws {
        let manager = AccountSessionManager(api: api(), vault: MemoryAccountVault(try session()))
        let oldGeneration = await manager.sessionGeneration()
        try await manager.install(session(id: "second-user"))
        do {
            _ = try await manager.accessToken(expectedGeneration: oldGeneration)
            XCTFail("A previous operation must not acquire a new account's authorization")
        } catch { XCTAssertEqual(error as? AccountAPIError, .staleSession) }
    }
    func testLateUnauthorizedForPreviousAccessDoesNotRotateRefreshAgain() async throws {
        let refresh = expectation(description: "Only one refresh despite late rejection"); refresh.assertForOverFulfill = true
        AuthURLProtocol.handler = { _ in refresh.fulfill(); return .init(body: self.rotatedResponse) }
        let manager = AccountSessionManager(api: api(), vault: MemoryAccountVault(try session()))
        let first = try await manager.refreshAfterRejection(of: "fixture-access")
        let late = try await manager.refreshAfterRejection(of: "fixture-access")
        XCTAssertEqual(first, late)
        await fulfillment(of: [refresh], timeout: 2)
    }
    func testRotatedRefreshStorageFailureNeverReusesConsumedRefresh() async throws {
        let refresh = expectation(description: "Refresh attempted once"); refresh.assertForOverFulfill = true
        AuthURLProtocol.handler = { _ in refresh.fulfill(); return .init(body: self.rotatedResponse) }
        let vault = MemoryAccountVault(try session(expired: true)); vault.shouldFailSave = true
        let manager = AccountSessionManager(api: api(), vault: vault)
        for _ in 0..<2 {
            do { _ = try await manager.accessToken(); XCTFail("Failed persistence must require recovery") }
            catch { XCTAssertEqual(error as? AccountAPIError, .storage) }
        }
        let snapshot = await manager.snapshot()
        XCTAssertNil(snapshot); XCTAssertNil(try vault.load())
        await fulfillment(of: [refresh], timeout: 2)
    }
    @MainActor func testLogoutRefreshesExpiredAccessBeforeRevokingTheRotatedSession() async throws {
        let revoked = expectation(description: "Revoked current server refresh token")
        AuthURLProtocol.handler = { request in
            if request.url?.absoluteString.hasSuffix("/auth/refresh/") == true { return .init(body: self.rotatedResponse) }
            XCTAssertEqual(request.url, AccountAPI.baseURL.appendingPathComponent("auth/logout/"))
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer fixture-rotated-access")
            let body = try JSONSerialization.jsonObject(with: AuthURLProtocol.body(request)) as? [String: String]
            XCTAssertEqual(body?["refresh_token"], "fixture-rotated-refresh")
            revoked.fulfill(); return .init(status: 204, body: "")
        }
        let client = api(); let manager = AccountSessionManager(api: client, vault: MemoryAccountVault(try session(expired: true)))
        let store = AccountStore(api: client, sessions: manager)
        await store.sessionChanged(); await store.logout()
        XCTAssertNil(store.user); XCTAssertNil(store.message)
        await fulfillment(of: [revoked], timeout: 2)
    }
    @MainActor func testDeletionUnavailableDoesNotPretendAccountWasDeleted() async throws {
        AuthURLProtocol.handler = { request in
            XCTAssertEqual(request.httpMethod, "DELETE")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer fixture-access")
            return .init(status: 503, body: #"{"error":{"code":"apple_revocation_unavailable","message":"not configured"}}"#)
        }
        let vault = MemoryAccountVault(try session())
        let client = api(); let manager = AccountSessionManager(api: client, vault: vault)
        let store = AccountStore(api: client, sessions: manager)
        await store.sessionChanged(); await store.deleteAccount()
        XCTAssertEqual(store.user?.id, "fixture-user")
        XCTAssertNotNil(try vault.load())
        XCTAssertTrue(store.message?.contains("尚未删除") == true)
        XCTAssertFalse(store.isBusy)
    }
    @MainActor func testSuccessfulAppleExchangeInstallsSessionAndLoadsOverview() async throws {
        AuthURLProtocol.handler = { request in
            let url = request.url!.absoluteString
            if url.hasSuffix("/challenge/") { return .init(body: #"{"challenge_id":"fixture-challenge","nonce":"abc","expires_in":300}"#) }
            if url.hasSuffix("/auth/apple/") { return .init(body: self.rotatedResponse) }
            if url.hasSuffix("/wallet/") { return .init(body: #"{"paid_credits":10,"bonus_credits":2,"reserved_credits":1,"available_credits":11}"#) }
            if url.hasSuffix("/usage/summary/") { return .init(body: #"{"request_count":2,"input_tokens":4,"output_tokens":3,"total_tokens":7,"confirmed_cost_cny":"0.0001","unknown_count":0}"#) }
            return .init(body: #"{"id":"fixture-user","display_name":"测试账号","email":null,"created_at":"2026-11-06T00:00:00Z"}"#)
        }
        let vault = MemoryAccountVault(nil); let client = api()
        let manager = AccountSessionManager(api: client, vault: vault)
        let store = AccountStore(api: client, sessions: manager)
        let attempt = try await store.beginAppleSignIn()
        await store.completeAppleSignIn(attempt: attempt, identityToken: "fixture-identity", authorizationCode: "fixture-code", fullName: nil, appleUserID: "fixture-apple-user")
        XCTAssertEqual(store.user?.id, "fixture-user")
        XCTAssertEqual(store.wallet?.availableCredits, 11)
        XCTAssertEqual(store.usage?.totalTokens, 7)
        XCTAssertEqual(try vault.load()?.appleUserID, "fixture-apple-user")
        XCTAssertFalse(store.isBusy); XCTAssertNil(store.message)
    }
    @MainActor func testLateDeleteRejectionCannotDeleteAReplacementAccount() async throws {
        let started = expectation(description: "Only the original account receives a delete request"); started.assertForOverFulfill = true
        AuthURLProtocol.handler = { request in
            XCTAssertEqual(request.httpMethod, "DELETE")
            started.fulfill()
            return .init(status: 401, body: "{}", delay: 0.1)
        }
        let client = api(); let vault = MemoryAccountVault(try session())
        let manager = AccountSessionManager(api: client, vault: vault)
        let store = AccountStore(api: client, sessions: manager)
        await store.sessionChanged()
        let deletion = Task { await store.deleteAccount() }
        await fulfillment(of: [started], timeout: 2)
        try await manager.install(session(id: "replacement-account"))
        await deletion.value; await store.sessionChanged()
        XCTAssertEqual(store.user?.id, "replacement-account")
        XCTAssertEqual(try vault.load()?.user.id, "replacement-account")
    }
    @MainActor func testOldOverviewCannotPopulateWalletAfterLogout() async throws {
        let started = expectation(description: "Overview started")
        AuthURLProtocol.handler = { request in
            if request.url?.absoluteString.hasSuffix("/auth/logout/") == true { return .init(status: 204, body: "") }
            if request.url?.absoluteString.hasSuffix("/wallet/") == true {
                return .init(body: #"{"paid_credits":10,"bonus_credits":2,"reserved_credits":1,"available_credits":11}"#, delay: 0.15)
            }
            if request.url?.absoluteString.hasSuffix("/usage/summary/") == true {
                return .init(body: #"{"request_count":2,"input_tokens":4,"output_tokens":3,"total_tokens":7,"confirmed_cost_cny":"0.0001","unknown_count":0}"#, delay: 0.15)
            }
            started.fulfill()
            return .init(body: #"{"id":"fixture-user","display_name":"测试账号","email":null,"created_at":"2026-11-06T00:00:00Z"}"#, delay: 0.15)
        }
        let client = api(); let manager = AccountSessionManager(api: client, vault: MemoryAccountVault(try session()))
        let store = AccountStore(api: client, sessions: manager)
        await store.sessionChanged()
        let flight = Task { await store.refreshOverview() }
        await fulfillment(of: [started], timeout: 2)
        await store.logout(); await flight.value
        XCTAssertNil(store.user); XCTAssertNil(store.wallet); XCTAssertNil(store.usage)
    }
    func testKeychainNamespacesAreIsolatedAndDeletingSessionDoesNotDeleteOtherNamespace() throws {
        let prefix = "BlindOracle.AccountServiceTests." + UUID().uuidString
        let first = AccountSessionVault(service: prefix + ".a")
        let second = AccountSessionVault(service: prefix + ".b")
        defer { try? first.delete(); try? second.delete() }
        try first.save(session()); try second.save(session(id: "second-user"))
        XCTAssertEqual(try first.load()?.user.id, "fixture-user")
        try first.delete()
        XCTAssertNil(try first.load())
        XCTAssertEqual(try second.load()?.user.id, "second-user")
    }
    func testGatewayUsesOwnSessionAndPurposeWithoutLoadingProviderCredential() async throws {
        let observed = expectation(description: "Gateway request")
        AuthURLProtocol.handler = { request in
            XCTAssertEqual(request.url, ServiceEnvironment.current.aiEndpoint)
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer fixture-access")
            XCTAssertNotNil(request.value(forHTTPHeaderField: "Idempotency-Key"))
            let body = try JSONSerialization.jsonObject(with: AuthURLProtocol.body(request)) as? [String: Any]
            XCTAssertEqual(body?["purpose"] as? String, "diagnostic")
            observed.fulfill()
            return .init(body: #"{"model":"deepseek-v4-pro","choices":[{"message":{"content":"OK"},"finish_reason":"stop"}],"usage":{"prompt_tokens":4,"completion_tokens":1,"total_tokens":5}}"#)
        }
        let manager = AccountSessionManager(api: api(), vault: MemoryAccountVault(try session()))
        let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [AuthURLProtocol.self]
        let client = DeepSeekClient(accountSessions: manager, manageQuota: false, sessionConfiguration: configuration)
        let report = try await client.checkConnection()
        XCTAssertEqual(report.host, "wellecho.cn"); XCTAssertEqual(report.totalTokens, 5)
        await fulfillment(of: [observed], timeout: 2)
    }
    func testNoSessionNeverStartsGatewayRequest() async throws {
        let unexpected = expectation(description: "No network request"); unexpected.isInverted = true
        AuthURLProtocol.handler = { _ in unexpected.fulfill(); return .init(body: "{}") }
        let manager = AccountSessionManager(api: api(), vault: MemoryAccountVault(nil))
        let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [AuthURLProtocol.self]
        let client = DeepSeekClient(accountSessions: manager, manageQuota: false, sessionConfiguration: configuration)
        do { _ = try await client.checkConnection(); XCTFail("Expected login requirement") }
        catch { guard case DeepSeekError.signInRequired = error else { return XCTFail("Expected friendly login error") } }
        await fulfillment(of: [unexpected], timeout: 0.1)
    }
    func testGatewayUnauthorizedRefreshKeepsTheSameRequestIdentity() async throws {
        let refreshed = expectation(description: "One refresh after rejected access")
        let retried = expectation(description: "Gateway retries same operation")
        let lock = NSLock(); var requestID: String?
        AuthURLProtocol.handler = { request in
            if request.url?.absoluteString.hasSuffix("/auth/refresh/") == true {
                refreshed.fulfill(); return .init(body: self.rotatedResponse)
            }
            if request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-access" {
                lock.lock(); requestID = request.value(forHTTPHeaderField: "Idempotency-Key"); lock.unlock()
                return .init(status: 401, body: "{}")
            }
            lock.lock(); let expectedID = requestID; lock.unlock()
            XCTAssertEqual(request.value(forHTTPHeaderField: "Idempotency-Key"), expectedID)
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer fixture-rotated-access")
            retried.fulfill()
            return .init(body: #"{"model":"deepseek-v4-pro","choices":[{"message":{"content":"OK"},"finish_reason":"stop"}]}"#)
        }
        let manager = AccountSessionManager(api: api(), vault: MemoryAccountVault(try session()))
        let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [AuthURLProtocol.self]
        _ = try await DeepSeekClient(accountSessions: manager, manageQuota: false, sessionConfiguration: configuration).checkConnection()
        await fulfillment(of: [refreshed, retried], timeout: 2)
    }
    func testGatewayTransientFailureDoesNotAutomaticallyRepeatGeneration() async throws {
        let request = expectation(description: "One upstream attempt only"); request.assertForOverFulfill = true
        AuthURLProtocol.handler = { _ in
            request.fulfill()
            return .init(status: 503, body: #"{"error":{"code":"upstream_unavailable","message":"unavailable"}}"#)
        }
        let manager = AccountSessionManager(api: api(), vault: MemoryAccountVault(try session()))
        let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [AuthURLProtocol.self]
        let client = DeepSeekClient(accountSessions: manager, manageQuota: false, sessionConfiguration: configuration)
        do { _ = try await client.summarize(transcript: "synthetic fixture", previous: ""); XCTFail("Expected gateway failure") }
        catch { guard case DeepSeekError.http(503) = error else { return XCTFail("Expected gateway failure") } }
        await fulfillment(of: [request], timeout: 2)
    }
    func testUnavailableResponseDoesNotExposeRawServerMessage() async {
        AuthURLProtocol.handler = { _ in .init(status: 404, body: #"{"error":{"code":"not_ready","message":"private-error-marker"}}"#) }
        do { _ = try await api().challenge(); XCTFail("Expected unavailable endpoint") }
        catch { XCTAssertFalse(error.localizedDescription.contains("private-error-marker")); XCTAssertFalse(error.localizedDescription.isEmpty) }
    }
}

private final class MemoryAccountVault: AccountSessionStorage {
    private var value: AccountSession?
    var shouldFailSave = false
    var shouldFailDelete = false
    var shouldFailLoad = false
    init(_ session: AccountSession?) { value = session }
    func load() throws -> AccountSession? { if shouldFailLoad { throw AccountAPIError.storage }; return value }
    func save(_ session: AccountSession) throws { if shouldFailSave { throw AccountAPIError.storage }; value = session }
    func delete() throws { if shouldFailDelete { throw AccountAPIError.storage }; value = nil }
}

private final class AuthURLProtocol: URLProtocol {
    struct Response { var status = 200; var body: String; var delay: TimeInterval = 0 }
    static var handler: ((URLRequest) throws -> Response)?
    private var delivery: DispatchWorkItem?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            guard let handler = Self.handler else { throw URLError(.badServerResponse) }
            let value = try handler(request)
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                let response = HTTPURLResponse(url: self.request.url!, statusCode: value.status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
                self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                self.client?.urlProtocol(self, didLoad: Data(value.body.utf8)); self.client?.urlProtocolDidFinishLoading(self)
            }
            delivery = work
            DispatchQueue.global().asyncAfter(deadline: .now() + value.delay, execute: work)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() { delivery?.cancel() }
    static func body(_ request: URLRequest) -> Data {
        if let value = request.httpBody { return value }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open(); defer { stream.close() }
        var result = Data(); var bytes = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&bytes, maxLength: bytes.count)
            if count <= 0 { break }; result.append(bytes, count: count)
        }
        return result
    }
}

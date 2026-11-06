import Foundation
import Combine
import AuthenticationServices

struct AppleSignInAttempt: Sendable {
    let challenge: AppleLoginChallenge
    let generation: UUID
    let sessionGeneration: UUID
}

enum AccountAccessState: Equatable {
    case restoring, recoveryRequired, signedOut, authenticated
}

@MainActor final class AccountStore: ObservableObject {
    @Published private(set) var accessState: AccountAccessState = .restoring
    @Published private(set) var canRetrySession = false
    var canAccessMain: Bool { accessState == .authenticated && user != nil }
    @Published private(set) var user: AccountUser?
    @Published private(set) var wallet: AccountWallet?
    @Published private(set) var usage: AccountUsageSummary?
    @Published private(set) var isBusy = false
    @Published private(set) var isLoading = false
    @Published var message: String?
    private let api: AccountAPI
    private let sessions: AccountSessionManager
    private var generation = UUID()
    private var restored = false
    private var restoring = false
    #if DEBUG
    private var debugUIFixture = false
    #endif
    init(api: AccountAPI = AccountAPI(), sessions: AccountSessionManager = .shared) {
        self.api = api; self.sessions = sessions
    }
    static func makeAppStore() -> AccountStore {
        let store = AccountStore()
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--ui-testing-local") {
            store.debugUIFixture = true; store.restored = true
            if ProcessInfo.processInfo.arguments.contains("--ui-testing-auth-signed-out") {
                store.accessState = .signedOut
            } else {
                store.user = AccountUser(id: "ui-fixture-account", displayName: "测试账号", email: "tester@example.com", createdAt: "2026-11-06T00:00:00Z")
                store.wallet = AccountWallet(paidCredits: 1200, bonusCredits: 300, reservedCredits: 100, availableCredits: 1400, quota: AccountQuota(remainingPercent: 100, isUnlimited: false, canStart: true))
                store.usage = try? JSONDecoder().decode(AccountUsageSummary.self, from: Data(#"{"request_count":8,"input_tokens":1200,"output_tokens":400,"total_tokens":1600,"confirmed_cost_cny":"0.12","unknown_count":1}"#.utf8))
                if ProcessInfo.processInfo.arguments.contains("--ui-testing-auth-restoring") {
                    store.accessState = .restoring
                    Task { [weak store] in
                        try? await Task.sleep(nanoseconds: 4_000_000_000)
                        guard let store, store.accessState == .restoring else { return }
                        store.accessState = .authenticated
                    }
                } else if ProcessInfo.processInfo.arguments.contains("--ui-testing-auth-recovery") {
                    store.accessState = .recoveryRequired; store.canRetrySession = true
                    store.message = AccountAPIError.unavailable.localizedDescription
                } else { store.accessState = .authenticated }
            }
        }
        #endif
        return store
    }
    func restore(force: Bool = false) async {
        #if DEBUG
        if debugUIFixture {
            if force, accessState == .recoveryRequired { accessState = .authenticated; canRetrySession = false; message = nil }
            return
        }
        #endif
        guard !restoring, !isBusy, !restored || force else { return }
        restoring = true; restored = true; accessState = .restoring; message = nil; canRetrySession = false
        defer { restoring = false }
        do { try await sessions.prepareRestoration() }
        catch {
            accessState = .recoveryRequired; canRetrySession = true; message = friendly(error)
            return
        }
        await sessionChanged()
        await verifyAppleCredentialState()
        let context = await sessions.context()
        guard let cached = context.session else { accessState = .signedOut; return }
        let expected = generation
        do {
            var token = try await sessions.accessToken(expectedGeneration: context.generation)
            let verified: AccountUser
            do { verified = try await api.user(token: token) }
            catch AccountAPIError.unauthorized {
                token = try await sessions.refreshAfterRejection(of: token, expectedGeneration: context.generation)
                verified = try await api.user(token: token)
            }
            guard generation == expected, await sessions.sessionGeneration() == context.generation else { return }
            guard verified.id == cached.user.id else { throw AccountAPIError.invalidResponse }
            user = verified; accessState = .authenticated; message = nil
        } catch {
            guard generation == expected else { return }
            message = friendly(error)
            if (error as? AccountAPIError) == .unauthorized {
                accessState = .signedOut
                try? await sessions.invalidate(expectedGeneration: context.generation)
                user = nil; wallet = nil; usage = nil
            } else {
                canRetrySession = await sessions.snapshot() != nil
                accessState = canRetrySession ? .recoveryRequired : .signedOut
            }
        }
    }
    func chooseSignIn() async {
        guard !isBusy else { return }
        #if DEBUG
        if debugUIFixture {
            generation = UUID(); user = nil; wallet = nil; usage = nil
            accessState = .signedOut; canRetrySession = false; message = nil
            return
        }
        #endif
        generation = UUID(); let expected = generation
        isBusy = true; accessState = .restoring
        let context = await sessions.context()
        do { try await sessions.invalidate(expectedGeneration: context.generation) }
        catch AccountAPIError.staleSession { isBusy = false; await sessionChanged(); return }
        catch { message = friendly(error) }
        guard generation == expected else { return }
        user = nil; wallet = nil; usage = nil; isBusy = false
        accessState = .signedOut; canRetrySession = false
        if let previous = context.session {
            let api = self.api
            Task { try? await api.logout(accessToken: previous.accessToken, refreshToken: previous.refreshToken) }
        }
    }
    func sessionChanged() async {
        #if DEBUG
        if debugUIFixture { return }
        #endif
        let snapshot = await sessions.snapshot()
        if user?.id != snapshot?.user.id {
            // Our own in-flight login installs its session before publishing UI state.
            if !(isBusy && user == nil && snapshot != nil) { generation = UUID(); isBusy = false }
            wallet = nil; usage = nil; isLoading = false
            if snapshot == nil { isBusy = false }
            if snapshot != nil { accessState = .restoring }
        }
        user = snapshot?.user
        if snapshot == nil { accessState = .signedOut; canRetrySession = false }
    }
    func beginAppleSignIn() async throws -> AppleSignInAttempt {
        guard !isBusy else { throw AccountAPIError.staleSession }
        generation = UUID(); let expected = generation
        isBusy = true; message = nil; user = nil; wallet = nil; usage = nil; accessState = .signedOut
        do {
            let sessionGeneration = await sessions.sessionGeneration()
            let challenge = try await api.challenge()
            guard generation == expected else { throw AccountAPIError.staleSession }
            guard !challenge.nonce.isEmpty, !challenge.challengeID.isEmpty, challenge.expiresIn > 0 else { throw AccountAPIError.invalidResponse }
            return AppleSignInAttempt(challenge: challenge, generation: expected, sessionGeneration: sessionGeneration)
        } catch {
            if generation == expected { isBusy = false; message = friendly(error) }
            throw error
        }
    }
    func completeAppleSignIn(attempt: AppleSignInAttempt, identityToken: String, authorizationCode: String,
                             fullName: String?, appleUserID: String) async {
        guard generation == attempt.generation else { return }
        do {
            let response = try await api.signIn(challengeID: attempt.challenge.challengeID,
                identityToken: identityToken, authorizationCode: authorizationCode, fullName: fullName)
            guard generation == attempt.generation else { return }
            let session = try AccountSession(response: response, appleUserID: appleUserID)
            try await sessions.install(session, expectedGeneration: attempt.sessionGeneration)
            guard generation == attempt.generation else { return }
            user = session.user; isBusy = false; message = nil
            accessState = .authenticated; canRetrySession = false
            await refreshOverview()
        } catch {
            guard generation == attempt.generation else { return }
            isBusy = false; message = friendly(error)
        }
    }
    func cancelAppleSignIn(attempt: AppleSignInAttempt?, message: String? = nil) {
        guard attempt == nil || attempt?.generation == generation else { return }
        isBusy = false; self.message = message
    }
    func refreshOverview() async {
        #if DEBUG
        if debugUIFixture { return }
        #endif
        guard user != nil, !isLoading, !isBusy else { return }
        let expected = generation
        isLoading = true; message = nil
        defer { if generation == expected { isLoading = false } }
        let context = await sessions.context()
        do {
            guard context.session?.user.id == user?.id else { throw AccountAPIError.staleSession }
            var token = try await sessions.accessToken(expectedGeneration: context.generation)
            let result: (AccountUser, AccountWallet, AccountUsageSummary)
            do { result = try await overview(token: token) }
            catch AccountAPIError.unauthorized {
                token = try await sessions.refreshAfterRejection(of: token, expectedGeneration: context.generation)
                result = try await overview(token: token)
            }
            guard generation == expected, user?.id == result.0.id else { return }
            user = result.0; wallet = result.1; usage = result.2
        } catch {
            guard generation == expected else { return }
            message = friendly(error)
            if (error as? AccountAPIError) == .unauthorized {
                accessState = .signedOut; user = nil; wallet = nil; usage = nil; canRetrySession = false
                try? await sessions.invalidate(expectedGeneration: context.generation)
                await sessionChanged()
            } else if await sessions.snapshot() == nil {
                accessState = .signedOut; user = nil; wallet = nil; usage = nil; canRetrySession = false
            }
        }
    }
    private func overview(token: String) async throws -> (AccountUser, AccountWallet, AccountUsageSummary) {
        async let person = api.user(token: token)
        async let balance = api.wallet(token: token)
        async let consumption = api.usage(token: token)
        return try await (person, balance, consumption)
    }
    func logout() async {
        #if DEBUG
        if debugUIFixture {
            generation = UUID(); user = nil; wallet = nil; usage = nil
            accessState = .signedOut; canRetrySession = false; message = nil; return
        }
        #endif
        guard !isBusy else { return }
        let started = generation
        isBusy = true; accessState = .restoring
        let context = await sessions.context()
        let initial = context.session
        var previous = initial
        var canRevoke = true
        if initial != nil {
            do { _ = try await sessions.accessToken(expectedGeneration: context.generation); previous = await sessions.snapshot() }
            catch { canRevoke = false }
        }
        guard generation == started else { return }
        var cleanupMessage: String?
        do { try await sessions.invalidate(expectedGeneration: context.generation) }
        catch AccountAPIError.staleSession { isBusy = false; await sessionChanged(); return }
        catch { cleanupMessage = friendly(error) }
        generation = UUID(); let expected = generation
        user = nil; wallet = nil; usage = nil; isBusy = false; isLoading = false; message = nil
        accessState = .signedOut; canRetrySession = false
        message = cleanupMessage
        if let previous, canRevoke {
            do { try await api.logout(accessToken: previous.accessToken, refreshToken: previous.refreshToken) }
            catch {
                if generation == expected, user == nil {
                    message = L10n.text("本机已退出；服务器会话暂未完成撤销，请联网后重新登录管理账号。", "Signed out on this device. The server session could not be revoked; reconnect and sign in to manage your account.")
                }
            }
        } else if initial != nil, !canRevoke {
            message = L10n.text("本机已退出；服务器会话暂未完成撤销，请联网后重新登录管理账号。", "Signed out on this device. The server session could not be revoked; reconnect and sign in to manage your account.")
        }
    }
    func deleteAccount() async {
        guard user != nil, !isBusy else { return }
        let expected = generation
        isBusy = true; message = nil
        defer { if generation == expected { isBusy = false } }
        let context = await sessions.context()
        do {
            guard context.session?.user.id == user?.id else { throw AccountAPIError.staleSession }
            var token = try await sessions.accessToken(expectedGeneration: context.generation)
            do { try await api.deleteUser(token: token) }
            catch AccountAPIError.unauthorized {
                token = try await sessions.refreshAfterRejection(of: token, expectedGeneration: context.generation)
                try await api.deleteUser(token: token)
            }
            guard generation == expected else { return }
            var cleanupMessage: String?
            do { try await sessions.invalidate(expectedGeneration: context.generation) }
            catch AccountAPIError.staleSession { await sessionChanged(); return }
            catch { cleanupMessage = friendly(error) }
            generation = UUID(); user = nil; wallet = nil; usage = nil; isBusy = false; isLoading = false
            accessState = .signedOut; canRetrySession = false
            message = L10n.text("服务器账号已删除。本机记录仍保留；需重新登录后才能访问。", "Your server account was deleted. Local records remain and require signing in again to access.")
            if let cleanupMessage { message! += "\n" + cleanupMessage }
        } catch {
            guard generation == expected else { return }
            if (error as? AccountAPIError) == .unauthorized {
                accessState = .signedOut; user = nil; wallet = nil; usage = nil; canRetrySession = false
                try? await sessions.invalidate(expectedGeneration: context.generation)
                await sessionChanged()
                message = AccountAPIError.unauthorized.localizedDescription
            } else if (error as? AccountAPIError)?.status == 503 {
                message = L10n.text("账号删除服务暂不可用，账号尚未删除。请稍后重试或通过隐私政策中的方式联系我们。", "Account deletion is temporarily unavailable. Your account has not been deleted. Try later or contact us using the Privacy Policy.")
            } else { message = friendly(error) }
        }
    }
    func credentialRevoked(expectedSessionGeneration: UUID? = nil) async {
        let context = await sessions.context()
        guard expectedSessionGeneration == nil || expectedSessionGeneration == context.generation else { return }
        guard let session = context.session, session.appleUserID != nil else { return }
        generation = UUID(); let expected = generation
        user = nil; wallet = nil; usage = nil; isBusy = false; isLoading = false
        accessState = .signedOut; canRetrySession = false
        do {
            try await sessions.invalidate(expectedGeneration: context.generation)
            guard generation == expected else { return }
            message = L10n.text("Apple 登录授权已撤销，请重新登录。", "Apple sign-in authorization was revoked. Please sign in again.")
        } catch { if generation == expected { message = friendly(error) } }
    }
    func verifyAppleCredentialState() async {
        #if DEBUG
        if debugUIFixture { return }
        #endif
        let context = await sessions.context()
        guard let current = context.session, let appleID = current.appleUserID else { return }
        let expected = generation
        let state: ASAuthorizationAppleIDProvider.CredentialState? = await withCheckedContinuation { continuation in
            ASAuthorizationAppleIDProvider().getCredentialState(forUserID: appleID) { state, error in
                continuation.resume(returning: error == nil ? state : nil)
            }
        }
        guard generation == expected else { return }
        if state == .revoked || state == .notFound { await credentialRevoked(expectedSessionGeneration: context.generation) }
    }
    private func friendly(_ error: Error) -> String {
        (error as? AccountAPIError)?.localizedDescription ?? AccountAPIError.unavailable.localizedDescription
    }
}

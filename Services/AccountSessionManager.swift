import Foundation

extension Notification.Name {
    static let accountSessionChanged = Notification.Name("BlindOracle.accountSessionChanged")
}

/// One session owner for both the account UI and the AI gateway. Never contains a provider key.
actor AccountSessionManager {
    static let shared = AccountSessionManager()
    private let api: AccountAPI
    private let vault: AccountSessionStorage
    private var session: AccountSession?
    private var generation = UUID()
    private var refreshTask: Task<AccountSession, Error>?
    private var refreshID: UUID?
    private var storageFailure = false
    private var restoreNeedsVaultRead = false
    init(api: AccountAPI = AccountAPI(), vault: AccountSessionStorage = AccountSessionVault()) {
        self.api = api; self.vault = vault
        do { session = try vault.load() } catch { storageFailure = true; restoreNeedsVaultRead = true }
    }
    func prepareRestoration() throws {
        guard restoreNeedsVaultRead else { return }
        session = try vault.load()
        storageFailure = false; restoreNeedsVaultRead = false
    }
    func snapshot() -> AccountSession? { session }
    func context() -> (session: AccountSession?, generation: UUID) { (session, generation) }
    func sessionGeneration() -> UUID { generation }
    func install(_ newSession: AccountSession, expectedGeneration: UUID? = nil) throws {
        guard expectedGeneration == nil || expectedGeneration == generation else { throw AccountAPIError.staleSession }
        try vault.save(newSession)
        generation = UUID(); refreshTask?.cancel(); refreshTask = nil; refreshID = nil
        storageFailure = false; restoreNeedsVaultRead = false; session = newSession
        NotificationCenter.default.post(name: .accountSessionChanged, object: nil)
    }
    func clear(expectedGeneration: UUID? = nil) throws {
        guard expectedGeneration == nil || expectedGeneration == generation else { throw AccountAPIError.staleSession }
        try vault.delete()
        generation = UUID(); refreshTask?.cancel(); refreshTask = nil; refreshID = nil
        storageFailure = false; restoreNeedsVaultRead = false; session = nil
        NotificationCenter.default.post(name: .accountSessionChanged, object: nil)
    }
    func invalidate(expectedGeneration: UUID) throws {
        guard expectedGeneration == generation else { throw AccountAPIError.staleSession }
        // A known revoked credential must stop authorizing requests even when Keychain is unavailable.
        generation = UUID(); refreshTask?.cancel(); refreshTask = nil; refreshID = nil
        session = nil; storageFailure = true; restoreNeedsVaultRead = false
        NotificationCenter.default.post(name: .accountSessionChanged, object: nil)
        try vault.delete()
        storageFailure = false
    }
    func refreshAfterRejection(of rejectedToken: String, expectedGeneration: UUID? = nil) async throws -> String {
        // A late 401 for the previous access token must not rotate an already refreshed session again.
        if let current = session, current.accessToken != rejectedToken {
            return try await accessToken(expectedGeneration: expectedGeneration)
        }
        return try await accessToken(forceRefresh: true, expectedGeneration: expectedGeneration)
    }
    func accessToken(forceRefresh: Bool = false, expectedGeneration: UUID? = nil) async throws -> String {
        guard expectedGeneration == nil || expectedGeneration == generation else { throw AccountAPIError.staleSession }
        guard !storageFailure else { throw AccountAPIError.storage }
        guard let current = session else { throw AccountAPIError.unauthorized }
        if !forceRefresh, current.expiresAt.timeIntervalSinceNow > 45 { return current.accessToken }
        let startedGeneration = generation
        let flight: Task<AccountSession, Error>; let flightID: UUID
        if let pending = refreshTask, let pendingID = refreshID { flight = pending; flightID = pendingID }
        else {
            let api = self.api
            flight = Task {
                let response = try await api.refresh(current.refreshToken)
                guard response.user.id == current.user.id else { throw AccountAPIError.invalidResponse }
                return try AccountSession(response: response, appleUserID: current.appleUserID)
            }
            flightID = UUID(); refreshTask = flight; refreshID = flightID
        }
        defer { if refreshID == flightID { refreshTask = nil; refreshID = nil } }
        do {
            let next = try await flight.value
            guard startedGeneration == generation else { throw AccountAPIError.staleSession }
            if session?.refreshToken == current.refreshToken {
                do { try vault.save(next) }
                catch {
                    // The server has consumed the old refresh token. Never retry that token after a storage failure.
                    storageFailure = true; session = nil; generation = UUID()
                    try? vault.delete()
                    NotificationCenter.default.post(name: .accountSessionChanged, object: nil)
                    throw AccountAPIError.storage
                }
                session = next
                NotificationCenter.default.post(name: .accountSessionChanged, object: nil)
            }
            return next.accessToken
        } catch {
            if (error as? AccountAPIError) == .unauthorized, startedGeneration == generation {
                try invalidate(expectedGeneration: startedGeneration)
            }
            throw error
        }
    }
}

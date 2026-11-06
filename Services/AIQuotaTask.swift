import Foundation
import CryptoKit

struct AIQuotaStage: Sendable {
    var taskID: UUID
    var stageID: String
    var conversationID: UUID? = nil
}

enum AIQuotaTaskScope {
    @TaskLocal static var stage: AIQuotaStage?
}

struct PreparedAIStage: Sendable {
    var body: Data
    var taskID: UUID
    var stageID: String
    var admissionToken: String
    var needsRepair: Bool
}

/// Request snapshots stay on this device with the same file protection as local conversations.
/// Replays use the original bytes, so a changed timestamp/context cannot turn a retry into a new task.
actor AIQuotaTaskService {
    static let shared = AIQuotaTaskService(directory: LocalVault.shared.directory.appendingPathComponent(ServiceEnvironment.current.taskDirectoryName, isDirectory: true))
    private struct TaskRecord: Codable {
        var ownerID: String
        var admissionToken: String?
        var endStatus: String?
        var conversationID: UUID?
        var serviceEnvironment: String?
        var logicalTaskID: UUID?
    }
    private struct StageRecord: Codable {
        var body: Data
        var purpose: String
        var needsRepair = false
    }
    private let directory: URL
    private let api: AccountAPI
    private let sessions: AccountSessionManager
    private let environment: ServiceEnvironment
    init(directory: URL, api: AccountAPI = AccountAPI(), sessions: AccountSessionManager = .shared, environment: ServiceEnvironment = .current) {
        self.directory = directory; self.api = api; self.sessions = sessions; self.environment = environment
    }
    func prepare(stage: AIQuotaStage, body: Data, purpose: String) async throws -> PreparedAIStage {
        let context = await sessions.context()
        guard let user = context.session?.user else { throw AccountAPIError.unauthorized }
        let taskFile = url(stage.taskID, "task")
        var record = try load(TaskRecord.self, taskFile) ?? TaskRecord(ownerID: user.id, conversationID: stage.conversationID, serviceEnvironment: environment.rawValue, logicalTaskID: stage.taskID)
        guard matchesEnvironment(record), record.ownerID == user.id, record.endStatus == nil,
              record.logicalTaskID == nil || record.logicalTaskID == stage.taskID else { throw AccountAPIError.staleSession }
        record.serviceEnvironment = environment.rawValue; record.logicalTaskID = stage.taskID
        // Persist ownership before the first network call; a restarted request must not adopt another user.
        try save(record, taskFile)
        let stageFile = url(stage.taskID, "stage-" + Self.digest(stage.stageID))
        let cached = try load(StageRecord.self, stageFile)
        guard cached == nil || cached?.purpose == purpose else { throw DeepSeekError.http(409) }
        let snapshot = cached ?? StageRecord(body: body, purpose: purpose)
        if cached == nil { try save(snapshot, stageFile) }
        var access = try await sessions.accessToken(expectedGeneration: context.generation)
        let admission: AITaskAdmission
        let serverID = environment.serverTaskID(for: stage.taskID)
        do { admission = try await api.startAITask(serverID, token: access) }
        catch AccountAPIError.unauthorized {
            access = try await sessions.refreshAfterRejection(of: access, expectedGeneration: context.generation)
            do { admission = try await api.startAITask(serverID, token: access) }
            catch AccountAPIError.unauthorized {
                try? await sessions.invalidate(expectedGeneration: context.generation)
                throw DeepSeekError.signInRequired
            }
        }
        guard admission.taskID == serverID, !admission.admissionToken.isEmpty,
              await sessions.sessionGeneration() == context.generation else { throw AccountAPIError.staleSession }
        guard let latest = try load(TaskRecord.self, taskFile), latest.endStatus == nil else { throw CancellationError() }
        record.admissionToken = admission.admissionToken
        try save(record, taskFile)
        return PreparedAIStage(body: snapshot.body, taskID: serverID, stageID: stage.stageID,
            admissionToken: admission.admissionToken, needsRepair: snapshot.needsRepair)
    }
    func markRepair(_ stage: AIQuotaStage?, needed: Bool) throws {
        guard let stage else { return }
        let file = url(stage.taskID, "stage-" + Self.digest(stage.stageID))
        guard var record = try load(StageRecord.self, file) else { return }
        record.needsRepair = needed; try save(record, file)
    }
    func end(_ taskID: UUID, status: String) async {
        let file = url(taskID, "task")
        do {
            guard var record = try load(TaskRecord.self, file) else { return }
            let context = await sessions.context()
            guard matchesEnvironment(record), record.ownerID == context.session?.user.id, let admissionToken = record.admissionToken else { return }
            record.endStatus = status; try save(record, file)
            var access = try await sessions.accessToken(expectedGeneration: context.generation)
            let serverID = environment.serverTaskID(for: taskID)
            do { try await api.endAITask(serverID, status: status, admissionToken: admissionToken, token: access) }
            catch AccountAPIError.unauthorized {
                access = try await sessions.refreshAfterRejection(of: access, expectedGeneration: context.generation)
                do { try await api.endAITask(serverID, status: status, admissionToken: admissionToken, token: access) }
                catch AccountAPIError.unauthorized {
                    try? await sessions.invalidate(expectedGeneration: context.generation)
                    throw AccountAPIError.unauthorized
                }
            }
            // Only discard raw snapshots after the app persisted its answer and the server acknowledged completion.
            try? FileManager.default.removeItem(at: file.deletingLastPathComponent())
            NotificationCenter.default.post(name: .accountBalanceChanged, object: nil)
        } catch { /* The on-device end marker is retried after the next authenticated launch. */ }
    }
    func flushPendingEnds() async {
        let folders = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        for folder in folders {
            guard let storedID = UUID(uuidString: folder.lastPathComponent),
                  let record = try? load(TaskRecord.self, folder.appendingPathComponent("task.json")), matchesEnvironment(record),
                  let id = record.logicalTaskID ?? (environment == .production ? storedID : nil), let status = record.endStatus else { continue }
            await end(id, status: status)
        }
    }
    func containsTask(_ id: UUID) -> Bool { FileManager.default.fileExists(atPath: url(id, "task").path) }
    func eraseConversation(_ conversationID: UUID?) async throws {
        let folders = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        for folder in folders {
            guard let storedID = UUID(uuidString: folder.lastPathComponent), var record = try load(TaskRecord.self, folder.appendingPathComponent("task.json")), matchesEnvironment(record),
                  let id = record.logicalTaskID ?? (environment == .production ? storedID : nil),
                  conversationID == nil || record.conversationID == conversationID else { continue }
            record.endStatus = "cancelled"; try save(record, url(id, "task"))
            for file in try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) where file.lastPathComponent.hasPrefix("stage-") {
                try FileManager.default.removeItem(at: file)
            }
            await end(id, status: "cancelled")
        }
    }
    private func url(_ taskID: UUID, _ file: String) -> URL {
        directory.appendingPathComponent(environment.serverTaskID(for: taskID).uuidString.lowercased(), isDirectory: true).appendingPathComponent(file + ".json")
    }
    private func matchesEnvironment(_ record: TaskRecord) -> Bool {
        record.serviceEnvironment == environment.rawValue || (record.serviceEnvironment == nil && environment == .production)
    }
    private func load<T: Decodable>(_ type: T.Type, _ file: URL) throws -> T? {
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        return try JSONDecoder().decode(type, from: Data(contentsOf: file))
    }
    private func save<T: Encodable>(_ value: T, _ file: URL) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        #if os(iOS)
        try JSONEncoder().encode(value).write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        #else
        try JSONEncoder().encode(value).write(to: file, options: .atomic)
        #endif
        var protectedDirectory = directory
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        try? protectedDirectory.setResourceValues(values)
    }
    private static func digest(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

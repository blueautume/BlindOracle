import Foundation
import CryptoKit

/// Selected once from Apple-verified evidence before constructing account or AI services.
enum ServiceEnvironment: String, Sendable {
    case production, sandbox

    static var current: Self { AppServiceContextStore.process.requireContext().environment }

    var isSandbox: Bool { self == .sandbox }
    var baseURL: URL {
        URL(string: isSandbox ? "https://wellecho.cn/xiazi-sandbox-api/v1/" : "https://wellecho.cn/xiazi-api/v1/")!
    }
    var aiEndpoint: URL { baseURL.appendingPathComponent("ai/chat/completions/") }
    // Keep the production namespace unchanged so a test installation never removes the saved production session.
    var sessionKeychainService: String { "com.lihao.BlindOracle.wellecho.account" + (isSandbox ? ".sandbox" : "") }
    var taskDirectoryName: String { isSandbox ? "ai-task-requests-sandbox" : "ai-task-requests" }
    var endIntentsFilename: String { isSandbox ? "pending-ai-task-ends-sandbox" : "pending-ai-task-ends" }
    var storeKitEnvironment: String { isSandbox ? "Sandbox" : "Production" }

    /// Local history is shared, but its logical task UUID must never address the other environment's server task.
    func serverTaskID(for logicalID: UUID) -> UUID {
        guard isSandbox else { return logicalID }
        var bytes = Array(SHA256.hash(data: Data(("BlindOracle.sandbox.task." + logicalID.uuidString.lowercased()).utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0f) | 0x50
        bytes[8] = (bytes[8] & 0x3f) | 0x80
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7], bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }
}

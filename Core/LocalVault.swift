import Foundation

/// Separate files deliberately keep permanent profiles outside conversation compression.
final class LocalVault {
    static let shared = LocalVault()
    let directory: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private var unreadableFiles: Set<String> = []
    private var recoveryCopies: [String: URL] = [:]
    init(directory: URL? = nil) {
        let uiTesting: Bool
        #if DEBUG
        uiTesting = ProcessInfo.processInfo.arguments.contains("--ui-testing-local")
        #else
        uiTesting = false
        #endif
        self.directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent(uiTesting ? "BlindOracle-UITest" : "BlindOracle", isDirectory: true)
        #if DEBUG
        if uiTesting, ProcessInfo.processInfo.arguments.contains("--ui-testing-reset") { try? FileManager.default.removeItem(at: self.directory) }
        #endif
        encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        try? FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true)
        var directoryURL = self.directory
        var resourceValues = URLResourceValues(); resourceValues.isExcludedFromBackup = true
        try? directoryURL.setResourceValues(resourceValues)
    }
    func load<T: Decodable>(_ type: T.Type, from name: String, fallback: T) -> T {
        let url = directory.appendingPathComponent(name + ".json")
        guard FileManager.default.fileExists(atPath: url.path) else { return fallback }
        do { return try decoder.decode(type, from: Data(contentsOf: url)) }
        catch {
            // Preserve the unreadable original for recovery rather than silently replacing it.
            preserveRecoveryCopy(name)
            return fallback
        }
    }
    func save<T: Encodable>(_ value: T, as name: String) throws {
        let url = directory.appendingPathComponent(name + ".json")
        let data = try encoder.encode(value)
        // A fallback returned by load must not destroy the only copy of data
        // when the recovery copy could not be written (for example, low space).
        if unreadableFiles.contains(name), !preserveRecoveryCopy(name) {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path])
        }
        #if os(iOS)
        try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        #else
        try data.write(to: url, options: .atomic)
        #endif
        unreadableFiles.remove(name)
    }
    func contains(_ name: String) -> Bool {
        FileManager.default.fileExists(atPath: directory.appendingPathComponent(name + ".json").path)
    }
    @discardableResult func preserveRecoveryCopy(_ name: String) -> Bool {
        let source = directory.appendingPathComponent(name + ".json")
        unreadableFiles.insert(name)
        if let existing = recoveryCopies[name],
           FileManager.default.contentsEqual(atPath: source.path, andPath: existing.path) {
            return true
        }
        let backup = directory.appendingPathComponent(name + ".recovery-" + UUID().uuidString + ".json")
        do {
            try FileManager.default.copyItem(at: source, to: backup)
            recoveryCopies[name] = backup
            return true
        } catch { return false }
    }
    func legacyConversationArchiveNames() -> [String] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return files.compactMap { url in
            let name = url.deletingPathExtension().lastPathComponent
            guard url.pathExtension == "json", name.hasPrefix("conversation-") else { return nil }
            let suffix = name.dropFirst("conversation-".count)
            guard !suffix.isEmpty, suffix.allSatisfy(\.isNumber) else { return nil }
            return name
        }.sorted {
            let prefixCount = "conversation-".count
            let lhs = Double($0.dropFirst(prefixCount)) ?? 0
            let rhs = Double($1.dropFirst(prefixCount)) ?? 0
            return lhs > rhs
        }
    }
    func removeLegacyConversationArchives() throws {
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        let recoverable = [ConversationHistory.filename, "conversation", "context", "pending-intake"]
        let legacyNames = Set(legacyConversationArchiveNames())
        for file in files where file.pathExtension == "json" {
            let name = file.deletingPathExtension().lastPathComponent
            let legacy = legacyNames.contains(name)
                || name.range(of: #"^conversation-[0-9]+\.recovery-"#, options: .regularExpression) != nil
            let recovery = recoverable.contains { name.hasPrefix($0 + ".recovery-") }
            if legacy || recovery { try FileManager.default.removeItem(at: file) }
        }
    }
    func export(profiles: [OracleProfile], runs: [OracleRun], weights: [String: Double]) throws -> URL {
        struct Export: Encodable { var schemaVersion = 1; var exportedAt = Date(); var profiles: [OracleProfile]; var runs: [OracleRun]; var weights: [String: Double] }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(L10n.text("瞎子-本地档案.json", "BlindOracle-local-data.json"))
        try encoder.encode(Export(profiles: profiles, runs: runs, weights: weights)).write(to: url, options: .atomic)
        return url
    }
}

enum PreferenceLearning {
    static var initial: [String: Double] { Dictionary(uniqueKeysWithValues: OracleMethod.allCases.map { ($0.rawValue, 1.0 / Double(OracleMethod.allCases.count)) }) }
    static func normalized(_ previous: [String: Double]) -> [String: Double] {
        var values = initial
        for method in OracleMethod.allCases {
            if let value = previous[method.rawValue], value.isFinite, value > 0 { values[method.rawValue] = value }
        }
        return project(values)
    }
    /// Small multiplicative steps track personal resonance, never statistical accuracy.
    static func updated(_ previous: [String: Double], chosen: Set<OracleMethod>, opposing: Set<OracleMethod>) -> [String: Double] {
        guard !chosen.isEmpty, chosen.isDisjoint(with: opposing) else { return previous }
        var values = normalized(previous)
        for method in OracleMethod.allCases {
            let direction: Double = chosen.contains(method) ? 1 : opposing.contains(method) ? -1 : 0
            values[method.rawValue] = max(0.04, min(0.25, (values[method.rawValue] ?? initial[method.rawValue]!) * exp(0.035 * direction)))
        }
        return project(values)
    }
    private static func project(_ previous: [String: Double]) -> [String: Double] {
        var values = previous.mapValues { max(0.04, min(0.25, $0)) }
        // Projection onto a bounded simplex prevents repeated votes from excluding a method.
        for _ in 0..<30 {
            let total = values.values.reduce(0, +)
            let free = values.keys.filter { key in total > 1 ? values[key]! > 0.0400001 : values[key]! < 0.2499999 }
            guard !free.isEmpty, abs(total - 1) > 1e-10 else { break }
            let adjustment = (1 - total) / Double(free.count)
            for key in free { values[key] = max(0.04, min(0.25, values[key]! + adjustment)) }
        }
        return values
    }
}

enum LocalContextPolicy {
    static let estimatedTokenThreshold = 32_000
    static let minimumNewMessages = 24
    static let retainedRecentMessages = 16
    static func estimatedTokens(_ text: String) -> Int {
        text.unicodeScalars.reduce(0) { $0 + ($1.value > 0x2E80 ? 1 : 0) } + text.unicodeScalars.filter { $0.value <= 0x2E80 }.count / 3
    }
    static func shouldCompact(messages: [ChatMessage], summary: ConversationSummary) -> Bool {
        let new = messages.filter { !summary.coveredMessageIDs.contains($0.id) }
        return new.count >= minimumNewMessages && estimatedTokens(summary.text + new.map(\.content).joined(separator: "\n")) > estimatedTokenThreshold
    }
    static func compact(messages: [ChatMessage], previous: ConversationSummary) -> ConversationSummary {
        let uncovered = messages.filter { !previous.coveredMessageIDs.contains($0.id) }
        let older = Array(uncovered.dropLast(retainedRecentMessages))
        guard !older.isEmpty else { return previous }
        let entries = older.filter { $0.kind != .intake }.map { message in
            let text = message.content.replacingOccurrences(of: "\n", with: " ")
            return (message.role == .user ? L10n.text("用户：", "User: ") : L10n.text("先知：", "Oracle: ")) + String(text.prefix(message.role == .user ? 500 : 800))
        }
        // A bounded retrieval digest. Full original messages and all result records remain on disk.
        var result = previous
        result.text = String((previous.text + "\n" + entries.joined(separator: "\n")).suffix(12_000))
        result.coveredMessageIDs = Array(Set(previous.coveredMessageIDs + older.map(\.id)))
        result.updatedAt = Date(); result.lastCompressedMessageCount = messages.count
        return result
    }
}

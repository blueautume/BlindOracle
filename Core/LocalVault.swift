import Foundation

/// Separate files deliberately keep permanent profiles outside conversation compression.
final class LocalVault {
    static let shared = LocalVault()
    let directory: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private let deletionDefaults: UserDefaults
    private var deletionDefaultsKey: String { "oracle.pendingAccountDeletion." + directory.lastPathComponent }
    private var deletionMarker: URL { directory.appendingPathExtension("account-deletion-pending") }
    var requiresAccountDeletionCleanup: Bool {
        deletionDefaults.bool(forKey: deletionDefaultsKey) || FileManager.default.fileExists(atPath: deletionMarker.path)
    }
    private var unreadableFiles: Set<String> = []
    private var recoveryCopies: [String: URL] = [:]
    init(directory: URL? = nil, deletionDefaults: UserDefaults = .standard) {
        let uiTesting: Bool
        #if DEBUG
        uiTesting = ProcessInfo.processInfo.arguments.contains("--ui-testing-local")
        #else
        uiTesting = false
        #endif
        self.directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent(uiTesting ? "BlindOracle-UITest" : "BlindOracle", isDirectory: true)
        self.deletionDefaults = deletionDefaults
        #if DEBUG
        if uiTesting, ProcessInfo.processInfo.arguments.contains("--ui-testing-reset") { try? FileManager.default.removeItem(at: self.directory) }
        #endif
        encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        // A process interruption or protected file must never make deleted
        // profiles/history visible on the next launch. Reads remain blocked
        // until the entire app-owned directory has been removed successfully.
        if requiresAccountDeletionCleanup { try? completeAccountDeletionCleanup() }
        try? FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true)
        var directoryURL = self.directory
        var resourceValues = URLResourceValues(); resourceValues.isExcludedFromBackup = true
        try? directoryURL.setResourceValues(resourceValues)
    }
    func load<T: Decodable>(_ type: T.Type, from name: String, fallback: T) -> T {
        guard !requiresAccountDeletionCleanup else { return fallback }
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
        guard !requiresAccountDeletionCleanup else { throw AccountAPIError.storage }
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
        !requiresAccountDeletionCleanup && FileManager.default.fileExists(atPath: directory.appendingPathComponent(name + ".json").path)
    }
    func markAccountDeletionPending() throws {
        // The defaults lock is also retained if writing the protected marker
        // fails. It contains no account identity or personal information.
        deletionDefaults.set(true, forKey: deletionDefaultsKey)
        deletionDefaults.synchronize()
        #if os(iOS)
        try Data().write(to: deletionMarker, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        #else
        try Data().write(to: deletionMarker, options: .atomic)
        #endif
    }
    func eraseDataForDeletedAccount() throws {
        try markAccountDeletionPending()
        try completeAccountDeletionCleanup()
    }
    private func completeAccountDeletionCleanup() throws {
        if FileManager.default.fileExists(atPath: directory.path) { try FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: deletionMarker.path) { try FileManager.default.removeItem(at: deletionMarker) }
        unreadableFiles.removeAll(); recoveryCopies.removeAll()
        deletionDefaults.removeObject(forKey: deletionDefaultsKey)
        deletionDefaults.synchronize()
    }
    @discardableResult func preserveRecoveryCopy(_ name: String) -> Bool {
        guard !requiresAccountDeletionCleanup else { return false }
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
    /// Retire only the obsolete preference cache and its recovery copies.
    /// Permanent profiles, reading snapshots and conversations are unaffected.
    func removeRetiredInterpretationPreferences() throws {
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        for file in files where file.pathExtension == "json" {
            let name = file.deletingPathExtension().lastPathComponent
            if name == "preferences" || name.hasPrefix("preferences.recovery-") {
                try FileManager.default.removeItem(at: file)
            }
        }
        unreadableFiles.remove("preferences")
        recoveryCopies.removeValue(forKey: "preferences")
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
        let entries = older.filter { $0.kind != .intake && $0.kind != .choice }.map { message in
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

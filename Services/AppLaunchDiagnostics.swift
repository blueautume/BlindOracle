import Foundation
import StoreKit

/// A closed diagnostic vocabulary. Never retain descriptions, arbitrary domains,
/// userInfo, StoreKit payloads, account identifiers, or a persistent device ID.
struct AppLaunchDiagnosticError: Codable, Sendable, Equatable {
    enum Domain: String, Codable, Sendable { case url, storeKit, storeKitInternal, appStore, cocoa, bootstrap, other, task }
    let domain: Domain
    let code: Int
    init(domain: Domain, code: Int) {
        self.domain = domain; self.code = min(Int(Int32.max), max(Int(Int32.min), code))
    }

    static func chain(for error: Error) -> [Self] {
        var result: [Self] = []
        var current: Error? = error
        while let next = current, result.count < 4 {
            let cocoa = next as NSError
            let domain: Domain
            if next is CancellationError { domain = .task }
            else if next is AppServiceBootstrapError || next is AppTransactionEvidenceError || next is AppServiceLaunchTimeout { domain = .bootstrap }
            else {
                switch cocoa.domain {
                case NSURLErrorDomain: domain = .url
                case "StoreKit.StoreKitError", "SKErrorDomain": domain = .storeKit
                case "SKInternalErrorDomain": domain = .storeKitInternal
                case "ASDErrorDomain": domain = .appStore
                case NSCocoaErrorDomain: domain = .cocoa
                default: domain = .other
                }
            }
            result.append(Self(domain: domain, code: cocoa.code))
            if let store = next as? StoreKitError {
                switch store {
                case .systemError(let underlying): current = underlying
                case .networkError(let underlying): current = underlying
                default: current = cocoa.userInfo[NSUnderlyingErrorKey] as? Error
                }
            } else { current = cocoa.userInfo[NSUnderlyingErrorKey] as? Error }
        }
        return result
    }
}

struct AppLaunchDiagnosticMetadata: Sendable {
    let appVersion: String
    let appBuild: String
    let osVersion: String
    init(appVersion: String, appBuild: String, osVersion: String) {
        func digits(_ value: Substring, maximum: Int) -> Bool {
            !value.isEmpty && value.count <= maximum && value.allSatisfy { $0.isASCII && $0.isNumber }
        }
        func version(_ value: String) -> String {
            let parts = value.split(separator: ".", omittingEmptySubsequences: false)
            return (1...4).contains(parts.count) && parts.allSatisfy { digits($0, maximum: 4) } ? value : "0"
        }
        self.appVersion = version(appVersion)
        self.appBuild = digits(Substring(appBuild), maximum: 10) ? appBuild : "0"
        self.osVersion = version(osVersion)
    }
    static var current: Self {
        let os = ProcessInfo.processInfo.operatingSystemVersion
        return Self(appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0",
                    appBuild: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0",
                    osVersion: "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)")
    }
}

struct AppLaunchDiagnosticEvent: Codable, Sendable, Equatable {
    enum Outcome: String, Codable, Sendable { case retrying, failed, recovered, succeeded, timedOut, taskCancelled }
    enum VerifiedEnvironment: String, Codable, Sendable { case unknown, production, sandbox }
    let schemaVersion: Int
    let eventID: UUID
    let launchID: UUID
    let attemptID: UUID
    let appVersion: String
    let appBuild: String
    let osVersion: String
    let clientOccurredAt: String
    let phase: AppTransactionEvidenceRequest
    let outcome: Outcome
    let attempt: Int
    let elapsedMS: Int
    let diagnosticCode: String
    let errorChain: [AppLaunchDiagnosticError]
    let verifiedEnvironment: VerifiedEnvironment
    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version", eventID = "event_id", launchID = "launch_id", attemptID = "attempt_id"
        case appVersion = "app_version", appBuild = "app_build", osVersion = "os_version"
        case clientOccurredAt = "client_occurred_at"
        case phase, outcome, attempt, elapsedMS = "elapsed_ms", diagnosticCode = "diagnostic_code"
        case errorChain = "error_chain", verifiedEnvironment = "verified_environment"
    }
    init(launchID: UUID, attemptID: UUID, metadata: AppLaunchDiagnosticMetadata, phase: AppTransactionEvidenceRequest,
         outcome: Outcome, attempt: Int, elapsed: TimeInterval, diagnosticCode: String,
         errorChain: [AppLaunchDiagnosticError], environment: VerifiedEnvironment = .unknown, occurredAt: Date = Date()) {
        schemaVersion = 1; eventID = UUID(); self.launchID = launchID; self.attemptID = attemptID
        appVersion = metadata.appVersion; appBuild = metadata.appBuild; osVersion = metadata.osVersion
        clientOccurredAt = ISO8601DateFormatter().string(from: occurredAt)
        self.phase = phase; self.outcome = outcome; self.attempt = min(3, max(1, attempt))
        elapsedMS = min(180_000, max(0, Int(elapsed * 1000)))
        self.diagnosticCode = diagnosticCode; self.errorChain = Array(errorChain.prefix(4)); verifiedEnvironment = environment
    }
    var safeText: String {
        let codes = errorChain.map { "\($0.domain.rawValue):\($0.code)" }.joined(separator: " → ")
        return "App \(appVersion) (\(appBuild)) · iOS \(osVersion)\nTime \(clientOccurredAt)\n\(diagnosticCode) · \(phase.rawValue) · \(outcome.rawValue)\nAttempt \(attempt) · \(elapsedMS) ms\nErrors \(codes.isEmpty ? "none" : codes)\nLaunch \(launchID.uuidString)\nAttempt ID \(attemptID.uuidString)\nEvent \(eventID.uuidString)"
    }
}

protocol AppLaunchDiagnosticReporting: Sendable {
    func report(_ event: AppLaunchDiagnosticEvent) async
    func flush() async
    func setDeliveryAllowed(_ allowed: Bool) async
}
extension AppLaunchDiagnosticReporting {
    func setDeliveryAllowed(_ allowed: Bool) async { }
}
struct DisabledAppLaunchDiagnosticReporter: AppLaunchDiagnosticReporting {
    func report(_ event: AppLaunchDiagnosticEvent) async { }
    func flush() async { }
}

protocol AppLaunchDiagnosticTransport: Sendable {
    func send(_ event: AppLaunchDiagnosticEvent) async -> AppLaunchDiagnosticDeliveryResult
}
enum AppLaunchDiagnosticDeliveryResult: Sendable { case accepted, discard, retry, cancelled }
struct AppLaunchDiagnosticHTTPTransport: AppLaunchDiagnosticTransport {
    static let endpoint = URL(string: "https://wellecho.cn/xiazi-api/v1/diagnostics/app-launch/")!
    private let session: URLSession
    init(configuration: URLSessionConfiguration = .ephemeral) {
        configuration.urlCache = nil; configuration.httpCookieStorage = nil
        configuration.timeoutIntervalForRequest = 5; configuration.timeoutIntervalForResource = 8
        session = URLSession(configuration: configuration)
    }
    func send(_ event: AppLaunchDiagnosticEvent) async -> AppLaunchDiagnosticDeliveryResult {
        guard !Task.isCancelled else { return .cancelled }
        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "POST"; request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        guard let body = try? JSONEncoder().encode(event) else { return .discard }
        request.httpBody = body
        let outgoing = request
        let cancellation = AppLaunchDiagnosticHTTPCancellation()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                // Resume only from URLSession's native task-completion callback,
                // never from the Swift cancellation handler. Protocol-specific
                // cleanup callbacks need not precede this acknowledgement.
                let task = session.dataTask(with: outgoing) { _, response, error in
                    let wasCancelled = cancellation.complete()
                    let result: AppLaunchDiagnosticDeliveryResult
                    if wasCancelled { result = .cancelled }
                    else if error != nil { result = .retry }
                    else if let status = (response as? HTTPURLResponse)?.statusCode {
                        if status == 202 { result = .accepted }
                        else if (400..<500).contains(status), status != 408, status != 429 { result = .discard }
                        else { result = .retry }
                    } else { result = .retry }
                    continuation.resume(returning: result)
                }
                cancellation.installAndResume(task)
            }
        } onCancel: {
            // Cancelling requests their stop; it never releases the continuation.
            cancellation.cancel()
        }
    }
}

private final class AppLaunchDiagnosticHTTPCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var task: URLSessionDataTask?
    private var cancelled = false

    func installAndResume(_ task: URLSessionDataTask) {
        lock.lock(); self.task = task; let shouldCancel = cancelled; lock.unlock()
        if shouldCancel { task.cancel() }
        task.resume()
    }
    func cancel() {
        lock.lock(); cancelled = true; let pending = task; lock.unlock()
        pending?.cancel()
    }
    func complete() -> Bool {
        lock.lock(); defer { lock.unlock() }
        task = nil
        return cancelled
    }
}

/// Bounded offline queue, separate from account data and usable before routing.
/// Reports only persist. The launch coordinator permits delivery after the app is
/// active and health/StoreKit verification has stopped; pausing drains an old send.
actor QueuedAppLaunchDiagnosticReporter: AppLaunchDiagnosticReporting {
    static let shared = QueuedAppLaunchDiagnosticReporter(deliveryAllowed: false)
    private struct Entry: Codable { let recordedAt: Date; let event: AppLaunchDiagnosticEvent }
    private let transport: any AppLaunchDiagnosticTransport
    private let fileURL: URL?
    private let now: @Sendable () -> Date
    private var entries: [Entry]
    private var deliveryAllowed: Bool
    private var deliveryGeneration: UInt64 = 0
    private var flushTask: Task<Void, Never>?
    private var flushID: UUID?
    private var nextSend = Date.distantPast
    private var consecutiveFailures = 0
    private var sendTimes: [Date] = []
    private let limit = 40
    private let ttl: TimeInterval = 7 * 24 * 60 * 60

    init(transport: any AppLaunchDiagnosticTransport = AppLaunchDiagnosticHTTPTransport(),
         fileURL: URL? = QueuedAppLaunchDiagnosticReporter.defaultFileURL,
         now: @escaping @Sendable () -> Date = { Date() }, deliveryAllowed: Bool = true) {
        self.transport = transport; self.fileURL = fileURL; self.now = now; self.deliveryAllowed = deliveryAllowed
        let cutoff = now().addingTimeInterval(-7 * 24 * 60 * 60)
        let loaded = fileURL.flatMap { try? Data(contentsOf: $0) }.flatMap { try? JSONDecoder().decode([Entry].self, from: $0) } ?? []
        entries = Array(loaded.filter { $0.recordedAt >= cutoff && $0.recordedAt <= now() }.suffix(40))
    }
    static var defaultFileURL: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("BlindOracleLaunchDiagnostics", isDirectory: true).appendingPathComponent("events.json")
    }
    func report(_ event: AppLaunchDiagnosticEvent) async {
        prune()
        guard !entries.contains(where: { $0.event.eventID == event.eventID }) else { return }
        entries.append(Entry(recordedAt: now(), event: event)); entries = Array(entries.suffix(limit)); persist()
    }
    func flush() async {
        await flush(generation: deliveryGeneration)
    }
    func setDeliveryAllowed(_ allowed: Bool) async {
        if allowed {
            // A cancelled delayed enable must not reopen delivery after a newer pause.
            guard !Task.isCancelled else { return }
            if !deliveryAllowed { deliveryGeneration &+= 1; deliveryAllowed = true }
            await flush(generation: deliveryGeneration)
        } else {
            deliveryAllowed = false; deliveryGeneration &+= 1
            let pending = flushTask
            pending?.cancel()
            // Retain the single-flight slot until URLSession/cancellable transport
            // has actually returned, even when another enable reenters this actor.
            await pending?.value
        }
    }
    private func flush(generation: UInt64) async {
        guard mayDeliver(generation) else { return }
        if let pending = flushTask {
            let restartingAfterPause = pending.isCancelled
            await pending.value
            guard restartingAfterPause, mayDeliver(generation) else { return }
        }
        guard flushTask == nil, mayDeliver(generation), now() >= nextSend else { return }
        prune(); persist()
        guard !entries.isEmpty else { return }
        let id = UUID()
        flushID = id
        let task = Task { await self.deliver(generation: generation, id: id) }
        flushTask = task
        await task.value
    }
    private func mayDeliver(_ generation: UInt64) -> Bool {
        deliveryAllowed && deliveryGeneration == generation && !Task.isCancelled
    }
    private func deliver(generation: UInt64, id: UUID) async {
        defer {
            if flushID == id { flushTask = nil; flushID = nil }
        }
        // At most 12 events per flush, leaving headroom under the server limit.
        for _ in 0..<12 {
            guard mayDeliver(generation), let entry = entries.first else { return }
            sendTimes.removeAll { now().timeIntervalSince($0) >= 60 }
            if sendTimes.count >= 12 {
                nextSend = sendTimes[0].addingTimeInterval(60)
                return
            }
            sendTimes.append(now())
            let result = await transport.send(entry.event)
            // A paused/cancelled attempt may have reached the server without an
            // acknowledgement. Keep its event ID for the server's idempotent replay.
            guard mayDeliver(generation) else { return }
            if case .cancelled = result { return }
            if case .retry = result {
                consecutiveFailures += 1
                nextSend = now().addingTimeInterval(min(3600, 60 * pow(2, Double(min(6, consecutiveFailures - 1)))))
                return
            }
            entries.removeAll { $0.event.eventID == entry.event.eventID }
            consecutiveFailures = 0; persist()
        }
        if mayDeliver(generation), !entries.isEmpty { nextSend = now().addingTimeInterval(60) }
    }
    func pendingCount() -> Int { entries.count }
    private func prune() {
        let current = now()
        entries.removeAll { current.timeIntervalSince($0.recordedAt) > ttl || $0.recordedAt > current }
    }
    private func persist() {
        guard let fileURL else { return }
        do {
            let directory = fileURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            var excludedDirectory = directory
            var values = URLResourceValues(); values.isExcludedFromBackup = true
            try excludedDirectory.setResourceValues(values)
            try JSONEncoder().encode(entries).write(to: fileURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication, .posixPermissions: 0o700], ofItemAtPath: directory.path)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
        } catch { /* Diagnostics never change account access or overwrite user data. */ }
    }
}

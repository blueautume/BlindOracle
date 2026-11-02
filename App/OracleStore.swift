import Foundation
import Combine

enum OraclePhase: String { case idle, planning, awaitingIntake, calculating, synthesizing }
struct OracleActivity: Identifiable { let id = UUID(); let text: String; let date = Date() }

@MainActor final class OracleStore: ObservableObject {
    @Published var profiles: [OracleProfile]
    @Published var messages: [ChatMessage]
    @Published var runs: [OracleRun]
    @Published var weights: [String: Double]
    @Published var summary: ConversationSummary
    @Published var conversations: [OracleConversation]
    @Published var activeConversationID: UUID
    @Published var phase: OraclePhase = .idle
    @Published var status = ""
    @Published var activities: [OracleActivity] = []
    @Published var pendingPlan: OraclePlan?
    @Published var showIntake = false
    @Published var notice: String?
    @Published var hasCredential = false
    @Published var selectedTab = 0
    let registry = PluginRegistry()
    let client = DeepSeekClient()
    private let vault: LocalVault
    private var task: Task<Void, Never>?
    private var operationID: UUID?
    var isBusy: Bool { [.planning, .calculating, .synthesizing].contains(phase) }
    var profile: OracleProfile { profiles.first ?? OracleProfile() }
    var latestRun: OracleRun? {
        let referenced = Set(messages.compactMap(\.runID))
        return runs.last { referenced.contains($0.id) }
    }
    var pendingIntakeMessageID: UUID? { pendingPlan == nil ? nil : messages.last(where: { $0.kind == .intake && $0.runID == nil })?.id }
    var localOnly: Bool {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--ui-testing-local") { return true }
        #endif
        return UserDefaults.standard.bool(forKey: "oracle.localOnly")
    }

    init(vault: LocalVault = .shared, bootstrapCredential: Bool = true) {
        self.vault = vault
        let history = ConversationHistory.load(from: vault)
        conversations = history.archive.conversations
        activeConversationID = history.archive.activeConversationID
        let active = history.archive.conversations.first { $0.id == history.archive.activeConversationID }
        profiles = vault.load([OracleProfile].self, from: "profiles", fallback: [OracleProfile()])
        messages = active?.messages ?? []
        runs = vault.load([OracleRun].self, from: "readings", fallback: [])
        weights = vault.load([String: Double].self, from: "preferences", fallback: PreferenceLearning.initial)
        summary = active?.summary ?? ConversationSummary()
        pendingPlan = active?.pendingPlan
        if pendingPlan != nil { phase = .awaitingIntake }
        if history.needsInitialSave {
            do { try vault.save(history.archive, as: ConversationHistory.filename) }
            catch { notice = "历史对话暂未写入磁盘，请检查设备可用空间。" }
        }
        if history.recoveredUnreadableFile { notice = "历史对话暂时无法读取，原文件已保留恢复副本。" }
        if bootstrapCredential { KeychainStore.shared.bootstrapDevelopmentKey(); refreshCredential() }
    }

    func refreshCredential() { hasCredential = KeychainStore.shared.string() != nil }
    private func persist() {
        captureCurrentConversation()
        do {
            try vault.save(profiles, as: "profiles")
            try vault.save(runs, as: "readings")
            try vault.save(weights, as: "preferences")
            let history = OracleConversationArchive(activeConversationID: activeConversationID, conversations: conversations)
            try vault.save(history, as: ConversationHistory.filename)
            // Keep the previous single-chat files as a compatibility snapshot;
            // the versioned history remains authoritative after migration.
            try vault.save(messages, as: "conversation")
            try vault.save(summary, as: "context")
            try vault.save(pendingPlan, as: "pending-intake")
        } catch { notice = "本次资料暂未写入磁盘，请检查设备可用空间。" }
    }
    func saveProfile(_ value: OracleProfile) {
        var copy = value; copy.updatedAt = Date()
        if let index = profiles.firstIndex(where: { $0.id == copy.id }) { profiles[index] = copy }
        else { profiles.append(copy) }
        persist()
    }
    func resetPreferences() { weights = PreferenceLearning.initial; persist() }
    func export() -> URL? { try? vault.export(profiles: profiles, runs: runs, weights: weights) }
    func newConversation() {
        cancelConversationTask()
        captureCurrentConversation()
        if !messages.isEmpty || pendingPlan != nil || !summary.text.isEmpty { activeConversationID = UUID() }
        messages = []; summary = ConversationSummary(); pendingPlan = nil
        clearConversationPresentation()
        persist()
    }
    func openConversation(_ id: UUID) {
        guard id != activeConversationID, let target = conversations.first(where: { $0.id == id }) else { return }
        cancelConversationTask()
        captureCurrentConversation()
        activeConversationID = target.id
        messages = target.messages; summary = target.summary; pendingPlan = target.pendingPlan
        clearConversationPresentation()
        selectedTab = 0
        persist()
    }
    func deleteConversation(_ id: UUID) {
        guard conversations.contains(where: { $0.id == id }) else { return }
        if id == activeConversationID {
            // Invalidate callbacks before removing the record. Do not capture
            // the deleted transcript again during the following persist.
            cancelConversationTask()
            conversations.removeAll { $0.id == id }
            activeConversationID = UUID()
            messages = []; summary = ConversationSummary(); pendingPlan = nil
            clearConversationPresentation()
        } else { conversations.removeAll { $0.id == id } }
        persist()
    }
    private func captureCurrentConversation() {
        let previous = conversations.first { $0.id == activeConversationID }
        let snapshot = OracleConversation(id: activeConversationID, messages: messages, summary: summary,
                                          pendingPlan: pendingPlan, createdAt: previous?.createdAt)
        conversations.removeAll { $0.id == activeConversationID }
        if !snapshot.isEmpty { conversations.append(snapshot) }
        conversations = ConversationHistory.ordered(conversations)
    }
    private func cancelConversationTask() {
        let interrupted = isBusy
        task?.cancel(); task = nil; operationID = nil
        if interrupted {
            for index in messages.indices where messages[index].role == .assistant && messages[index].content.isEmpty {
                messages[index].content = "这次先停在这里，已完成的资料与结果仍保留。"
            }
        }
    }
    private func clearConversationPresentation() {
        showIntake = false; notice = nil; status = ""; activities = []
        phase = pendingPlan == nil ? .idle : .awaitingIntake
    }
    private func progress(_ text: String) { status = text; activities.append(OracleActivity(text: text)) }

    func send(_ question: String) {
        let text = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isBusy else { return }
        guard text.count <= 6000 else { notice = "这次问题较长，请先整理到六千字以内。"; return }
        messages.append(ChatMessage(role: .user, content: text))
        activities = []; phase = .planning; progress("听清你所问的事…")
        let id = UUID(); operationID = id; persist()
        task = Task { [weak self] in
            guard let self else { return }
            await prepareContext(operation: id)
            guard operationID == id, !Task.isCancelled else { return }
            let history = ContextCompressor.history(messages: Array(messages.dropLast()), summary: summary)
            let followup = latestRun != nil && (["再细说些", "详细解读", "继续说"].contains(text) || text.hasPrefix("请结合刚才的结果"))
            let greeting = text.count < 20 && ["你好", "您好", "在吗", "你是谁", "你能做什么"].contains { text.contains($0) }
            if (followup || greeting), hasCredential, !localOnly {
                await answerFollowUp(text, history: history, operation: id); return
            }
            var plan = registry.localPlan(question: text, profile: profile)
            if hasCredential && !localOnly {
                do { plan = try await client.plan(question: text, profile: profile, plugins: registry.descriptors, history: history) }
                catch {
                    guard !Task.isCancelled else { return }
                    notice = error.localizedDescription + " 已改为本地准备问事笺。"
                }
            }
            guard operationID == id, !Task.isCancelled else { return }
            if plan.action == "reply" {
                await answerFollowUp(text, history: history, operation: id); return
            }
            if plan.action == "clarify" {
                messages.append(ChatMessage(role: .assistant, content: plan.note.isEmpty ? "你最想问的是哪一件具体的事？" : plan.note))
                phase = pendingPlan == nil ? .idle : .awaitingIntake; operationID = nil; persist(); return
            }
            // A union of declared requirements prevents a model from bypassing local validation.
            let requirements = registry.descriptors.filter { plan.methods.contains($0.method) }.flatMap(\.requiredFields)
            plan.requiredFields = Array(Set(plan.requiredFields + requirements))
            pendingPlan = plan; phase = .awaitingIntake
            progress("问事笺已备好，等你确认。")
            messages.append(ChatMessage(role: .assistant, content: plan.note.isEmpty ? "先留一份问事笺。能确定的写下，不确定的也如实留着。" : plan.note, kind: .intake))
            showIntake = true; persist()
        }
    }

    private func prepareContext(operation: UUID) async {
        guard ContextCompressor.shouldCompress(messages: messages, summary: summary) else { return }
        if hasCredential && !localOnly {
            do {
                if let newSummary = try await ContextCompressor.compact(messages: messages, summary: summary, using: client) {
                    guard operationID == operation, !Task.isCancelled else { return }
                    summary = newSummary; persist(); return
                }
            } catch { if Task.isCancelled { return } }
        }
        guard operationID == operation, !Task.isCancelled else { return }
        summary = LocalContextPolicy.compact(messages: messages, previous: summary); persist()
    }

    func confirmIntake(profile submittedProfile: OracleProfile, numbers: [Int], save: Bool) {
        guard let plan = pendingPlan, !isBusy else { return }
        if save { saveProfile(submittedProfile) }
        let style = ["蓍草", "大衍"].contains { plan.question.contains($0) } ? "yarrow" : "coins"
        let input = OracleInput(question: plan.question, profile: submittedProfile, numbers: numbers, subject: plan.subject, castingStyle: style)
        let run = OracleRun(input: input, plan: plan, weightsSnapshot: weights)
        runs.append(run); showIntake = false; pendingPlan = nil; phase = .calculating
        if let index = messages.lastIndex(where: { $0.kind == .intake }) {
            messages[index].runID = run.id
            messages[index].content = "问事笺已收好。稍坐，我替你理一理。"
        }
        activities = []; progress("核对这次资料与时辰…")
        let operation = UUID(); operationID = operation; persist()
        task = Task { [weak self] in
            guard let self else { return }
            let results = await registry.calculate(input, methods: plan.methods) { [weak self] result in
                await self?.receive(result, for: run.id, operation: operation)
            }
            guard operationID == operation, !Task.isCancelled else { return }
            if let index = runs.firstIndex(where: { $0.id == run.id }) { runs[index].results = results }
            await synthesize(runID: run.id, operation: operation)
        }
    }
    private func receive(_ result: OracleResult, for runID: UUID, operation: UUID) {
        guard operationID == operation, let index = runs.firstIndex(where: { $0.id == runID }) else { return }
        runs[index].results.append(result)
        progress("本地推演 \(runs[index].results.count) / \(runs[index].plan.methods.count)…")
        persist()
    }
    func retrySynthesis(_ run: OracleRun) {
        guard !isBusy else { return }
        phase = .synthesizing
        let operation = UUID(); operationID = operation
        task = Task { [weak self] in await self?.synthesize(runID: run.id, operation: operation) }
    }
    private func synthesize(runID: UUID, operation: UUID) async {
        guard operationID == operation, !Task.isCancelled,
              let run = runs.first(where: { $0.id == runID }) else { return }
        phase = .synthesizing; progress("将几处线索慢慢合在一起…")
        let messageID = UUID()
        messages.append(ChatMessage(id: messageID, role: .assistant, content: "", kind: .reading, runID: runID))
        let history = ContextCompressor.history(messages: Array(messages.dropLast()), summary: summary)
        var synthesis: ReadingSynthesis
        if hasCredential && !localOnly {
            do {
                synthesis = try await client.synthesize(run: run, weights: weights, history: history) { [weak self] delta in
                    Task { @MainActor [weak self] in
                        guard let self, self.operationID == operation,
                              let index = self.messages.firstIndex(where: { $0.id == messageID }) else { return }
                        self.messages[index].content += delta
                    }
                }
            } catch {
                guard !Task.isCancelled else { return }
                notice = error.localizedDescription
                synthesis = localReading(run, reason: "暂未接通解读服务，先留一份本地规则摘要。")
            }
        } else {
            synthesis = localReading(run, reason: localOnly ? "当前为本地试算，以下是规则摘要。" : "本地推演已完成。设置解读密钥后，可以继续听我细说。")
        }
        guard operationID == operation, !Task.isCancelled else { return }
        if run.selectedAlternative != nil, let original = run.synthesis?.alternatives, original.count == 2 {
            synthesis.alternatives = original
        }
        if let index = messages.firstIndex(where: { $0.id == messageID }) { messages[index].content = synthesis.text }
        if let index = runs.firstIndex(where: { $0.id == runID }) { runs[index].synthesis = synthesis; runs[index].completedAt = Date() }
        progress("这次推演已记入数据簿。")
        phase = pendingPlan == nil ? .idle : .awaitingIntake; operationID = nil; persist()
    }
    private func localReading(_ run: OracleRun, reason: String) -> ReadingSynthesis {
        let eligible = run.results.filter { $0.status == .complete || $0.status == .partial }
        let statements = eligible.flatMap(\.evidence).map(\.statement)
        var seen = Set<String>()
        let unique = statements.filter { seen.insert($0).inserted }
        let body = unique.isEmpty ? "现有资料还不足以给出完整判断。你可以在数据簿查看已完成的部分，并补充不确定的资料。" : String(unique.prefix(5).joined(separator: "\n\n").prefix(900))
        let uncertainty = eligible.contains { !$0.limitations.isEmpty } ? "\n\n有些资料或规则仍有限制，未确定的部分先留白。" : ""
        return ReadingSynthesis(text: reason + "\n\n" + body + uncertainty, alternatives: [])
    }
    private func answerFollowUp(_ question: String, history: [AIConversationTurn], operation: UUID) async {
        phase = .synthesizing; progress("顺着刚才的线索，再说细一些…")
        let messageID = UUID()
        messages.append(ChatMessage(id: messageID, role: .assistant, content: "", runID: latestRun?.id))
        do {
            let text = try await client.followUp(question: question, run: latestRun, profile: profile, history: history) { [weak self] delta in
                Task { @MainActor [weak self] in
                    guard let self, self.operationID == operation, let index = self.messages.firstIndex(where: { $0.id == messageID }) else { return }
                    self.messages[index].content += delta
                }
            }
            guard operationID == operation else { return }
            if let index = messages.firstIndex(where: { $0.id == messageID }) { messages[index].content = text }
        } catch {
            guard !Task.isCancelled else { return }
            if let index = messages.firstIndex(where: { $0.id == messageID }) { messages[index].content = error.localizedDescription }
        }
        guard operationID == operation else { return }
        progress("我在，慢慢问。")
        phase = pendingPlan == nil ? .idle : .awaitingIntake; operationID = nil; persist()
    }
    func select(_ alternative: ReadingAlternative, for runID: UUID) {
        guard let index = runs.firstIndex(where: { $0.id == runID }), runs[index].selectedAlternative == nil,
              let options = runs[index].synthesis?.alternatives, options.count == 2,
              let chosen = options.first(where: { $0.id == alternative.id }),
              let other = options.first(where: { $0.id != alternative.id }) else { return }
        let valid = Set(runs[index].results.filter { $0.status == .complete || $0.status == .partial }.map(\.method))
        let chosenMethods = Set(chosen.supportingMethods).intersection(valid)
        let otherMethods = Set(other.supportingMethods).intersection(valid)
        weights = PreferenceLearning.updated(weights, chosen: chosenMethods, opposing: otherMethods)
        runs[index].selectedAlternative = chosen.id
        messages.append(ChatMessage(role: .user, content: "更贴近我的处境：" + chosen.title, kind: .choice, runID: runID))
        messages.append(ChatMessage(role: .assistant, content: "记下了。往后会把这类线索稍稍多放在心上；这次先照你确认的处境继续看。", runID: runID))
        persist()
    }
    func stop() {
        task?.cancel(); task = nil; operationID = nil; phase = .idle
        progress("已停下，完成的资料与结果仍保留。")
        for index in messages.indices where messages[index].role == .assistant && messages[index].content.isEmpty {
            messages[index].content = "这次先停在这里。"
        }
        persist()
    }
}

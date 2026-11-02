import Foundation
import Combine

enum OraclePhase: String { case idle, planning, awaitingIntake, awaitingInteraction, calculating, synthesizing }

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
    @Published var activitySessionID = UUID()
    @Published var activityMessageID: UUID?
    @Published var pendingPlan: OraclePlan?
    @Published var showIntake = false
    @Published var pendingInteraction: OracleInteractionSession?
    @Published var showInteraction = false
    @Published var notice: String?
    @Published var hasCredential = false
    @Published var selectedTab = 0
    let registry = PluginRegistry()
    let client = DeepSeekClient()
    private let vault: LocalVault
    private var task: Task<Void, Never>?
    private var operationID: UUID?
    private var activityRunID: UUID?
    var isBusy: Bool { [.planning, .calculating, .synthesizing].contains(phase) }
    private var waitingPhase: OraclePhase { pendingInteraction != nil ? .awaitingInteraction : pendingPlan != nil ? .awaitingIntake : .idle }
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
        DeepSeekConfiguration.migrateDefault()
        self.vault = vault
        let history = ConversationHistory.load(from: vault)
        conversations = history.archive.conversations
        activeConversationID = history.archive.activeConversationID
        let active = history.archive.conversations.first { $0.id == history.archive.activeConversationID }
        profiles = vault.load([OracleProfile].self, from: "profiles", fallback: [OracleProfile()])
        messages = active?.messages ?? []
        runs = vault.load([OracleRun].self, from: "readings", fallback: [])
        weights = PreferenceLearning.normalized(vault.load([String: Double].self, from: "preferences", fallback: PreferenceLearning.initial))
        summary = active?.summary ?? ConversationSummary()
        pendingPlan = active?.pendingPlan
        pendingInteraction = active?.pendingInteraction
        phase = waitingPhase
        if history.needsInitialSave {
            do { try vault.save(history.archive, as: ConversationHistory.filename) }
            catch { notice = "历史对话暂未写入磁盘，请检查设备可用空间。" }
        }
        if history.recoveredUnreadableFile { notice = "历史对话暂时无法读取，原文件已保留恢复副本。" }
        if bootstrapCredential { KeychainStore.shared.bootstrapDevelopmentKey(); refreshCredential() }
        restoreActivities()
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--ui-testing-progress") || ProcessInfo.processInfo.arguments.contains("--ui-testing-progress-paused") {
            startProgressPreview(paused: ProcessInfo.processInfo.arguments.contains("--ui-testing-progress-paused"))
        }
        #endif
    }

    func refreshCredential() { hasCredential = KeychainStore.shared.string() != nil }
    private func persist() {
        syncActivities()
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
        if !messages.isEmpty || pendingPlan != nil || pendingInteraction != nil || !summary.text.isEmpty { activeConversationID = UUID() }
        messages = []; summary = ConversationSummary(); pendingPlan = nil; pendingInteraction = nil
        clearConversationPresentation()
        persist()
    }
    func openConversation(_ id: UUID) {
        guard id != activeConversationID, let target = conversations.first(where: { $0.id == id }) else { return }
        cancelConversationTask()
        captureCurrentConversation()
        activeConversationID = target.id
        messages = target.messages; summary = target.summary; pendingPlan = target.pendingPlan
        pendingInteraction = target.pendingInteraction
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
            messages = []; summary = ConversationSummary(); pendingPlan = nil; pendingInteraction = nil
            clearConversationPresentation()
        } else { conversations.removeAll { $0.id == id } }
        persist()
    }
    private func captureCurrentConversation() {
        let previous = conversations.first { $0.id == activeConversationID }
        let snapshot = OracleConversation(id: activeConversationID, messages: messages, summary: summary,
                                          pendingPlan: pendingPlan, pendingInteraction: pendingInteraction, createdAt: previous?.createdAt)
        conversations.removeAll { $0.id == activeConversationID }
        if !snapshot.isEmpty { conversations.append(snapshot) }
        conversations = ConversationHistory.ordered(conversations)
    }
    private func cancelConversationTask() {
        let interrupted = isBusy
        task?.cancel(); task = nil; operationID = nil
        if interrupted {
            finishActivity(status: .cancelled)
            for index in messages.indices where messages[index].role == .assistant && messages[index].content.isEmpty {
                messages[index].content = "这次先停在这里，已完成的资料与结果仍保留。"
            }
        }
    }
    private func clearConversationPresentation() {
        showIntake = false; showInteraction = false; notice = nil; status = ""; activities = []
        phase = waitingPhase
        activityMessageID = nil; activityRunID = nil; activitySessionID = UUID()
        restoreActivities()
    }
    private func beginActivitySession() {
        activities = []; status = ""; activitySessionID = UUID(); activityMessageID = nil; activityRunID = nil
    }
    private func progress(_ text: String, detail: String? = nil, method: OracleMethod? = nil,
                          state: OracleActivityStatus = .running) {
        var timeline = OracleProgressTimeline(activities: activities)
        timeline.begin(text: text, detail: detail, method: method, status: state)
        activities = timeline.activities; status = text; syncActivities()
    }
    private func finishActivity(status: OracleActivityStatus = .completed) {
        var timeline = OracleProgressTimeline(activities: activities)
        timeline.finish(status: status); activities = timeline.activities; syncActivities()
    }
    private func syncActivities() {
        if let id = activityRunID, let index = runs.firstIndex(where: { $0.id == id }) { runs[index].activities = activities }
        if let id = activityMessageID, let index = messages.firstIndex(where: { $0.id == id }) { messages[index].activities = activities }
    }
    private func restoreActivities() {
        let awaitingUser = pendingPlan != nil || pendingInteraction != nil
        if let message = messages.last(where: {
            !($0.activities ?? []).isEmpty && (!awaitingUser || ($0.kind == .intake && $0.runID == nil))
        }) {
            activityMessageID = message.id; activityRunID = message.kind == .reading ? message.runID : nil
            activities = message.activities ?? []; activitySessionID = message.id
            if activities.last?.status == .running { finishActivity(status: .cancelled) }
            status = activities.last?.text ?? ""
        } else if !awaitingUser, let run = latestRun, let saved = run.activities, !saved.isEmpty {
            activities = saved; activityRunID = run.id; activitySessionID = run.id
            activityMessageID = messages.last(where: { $0.runID == run.id && $0.kind == .reading })?.id
            if activities.last?.status == .running { finishActivity(status: .cancelled) }
            status = activities.last?.text ?? ""
        }
        if awaitingUser {
            activityRunID = nil
            activityMessageID = messages.last(where: { $0.kind == .intake && $0.runID == nil })?.id
            progress(pendingInteraction != nil ? interactionStatus : "等待你确认问事资料", state: .waiting)
        }
    }
    private var interactionStatus: String {
        switch pendingInteraction?.currentRequest?.kind {
        case .tarot: "等待你选牌并翻开"
        case .numbers: "等待你留下三个数字"
        case .coins: "等待你依次留下六爻"
        case nil: "等待你确认选择"
        }
    }

    func send(_ question: String) {
        let text = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isBusy else { return }
        guard pendingInteraction == nil else {
            notice = "先完成这次操作，先知便能接着为你解读。"; showInteraction = true; return
        }
        guard text.count <= 6000 else { notice = "这次问题较长，请先整理到六千字以内。"; return }
        if pendingPlan == nil, activities.last?.status == .waiting { finishActivity() }
        messages.append(ChatMessage(role: .user, content: text))
        beginActivitySession(); phase = .planning; progress("理解问题与确认询问对象")
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
            progress("选择适用方法与所需资料")
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
                activityMessageID = messages.last?.id
                progress("等待你补充确认所问事项", state: .waiting)
                phase = waitingPhase; operationID = nil; persist(); return
            }
            // A union of declared requirements prevents a model from bypassing local validation.
            let requirements = registry.descriptors.filter { plan.methods.contains($0.method) }.flatMap(\.requiredFields)
            plan.requiredFields = Array(Set(plan.requiredFields + requirements))
            pendingPlan = plan; phase = .awaitingIntake
            progress("等待你确认问事资料", state: .waiting)
            messages.append(ChatMessage(role: .assistant, content: plan.note.isEmpty ? "先留一份问事笺。能确定的写下，不确定的也如实留着。" : plan.note, kind: .intake))
            activityMessageID = messages.last?.id; syncActivities()
            if plan.methods == [.tarot], plan.requiredFields.isEmpty {
                confirmIntake(profile: plan.subject == "他人" ? OracleProfile() : profile, numbers: [], save: false)
            } else { showIntake = true; persist() }
        }
    }

    private func prepareContext(operation: UUID) async {
        guard operationID == operation, !Task.isCancelled else { return }
        guard ContextCompressor.shouldCompress(messages: messages, summary: summary) else { return }
        progress("整理此前对话与已确认资料")
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
        let requests = OracleInteractionPolicy.requests(for: plan, numbers: numbers)
        if !requests.isEmpty {
            pendingInteraction = OracleInteractionSession(input: input, plan: plan, requests: requests)
            pendingPlan = nil; showIntake = false; phase = .awaitingInteraction; operationID = nil
            if let index = messages.lastIndex(where: { $0.kind == .intake && $0.runID == nil }) {
                messages[index].content = "请先完成这次操作，留下属于你的选择。"
            }
            progress(interactionStatus, state: .waiting); showInteraction = true; persist(); return
        }
        startReading(input: input, plan: plan)
    }

    func saveInteractionProgress(_ response: OracleInteractionResponse, sessionID: UUID) {
        guard var session = pendingInteraction, session.id == sessionID, !isBusy,
              session.saveProgress(response) else { return }
        pendingInteraction = session; persist()
    }

    func completeInteraction(_ response: OracleInteractionResponse, sessionID: UUID) {
        guard var session = pendingInteraction, session.id == sessionID, !isBusy,
              session.complete(response) else { return }
        pendingInteraction = session
        if session.currentRequest == nil {
            pendingInteraction = nil; showInteraction = false
            startReading(input: session.input, plan: session.plan)
        } else { progress(interactionStatus, state: .waiting); persist() }
    }

    private func startReading(input: OracleInput, plan: OraclePlan) {
        let run = OracleRun(input: input, plan: plan, weightsSnapshot: weights)
        activityRunID = run.id
        runs.append(run); showIntake = false; pendingPlan = nil; phase = .calculating
        if let index = messages.lastIndex(where: { $0.kind == .intake }) {
            messages[index].runID = run.id
            messages[index].content = "问事笺已收好。稍坐，我替你理一理。"
        }
        progress("核对资料与已确认的选择")
        let operation = UUID(); operationID = operation; persist()
        let conversationID = activeConversationID
        task = Task { [weak self] in
            guard let self else { return }
            let results = await registry.calculate(input, methods: plan.methods, onMethodStart: { [weak self] method, index, total in
                await self?.beginMethod(method, index: index, total: total, runID: run.id, operation: operation, conversationID: conversationID)
            }, onProgress: { [weak self] result in
                await self?.receive(result, for: run.id, operation: operation)
            })
            guard operationID == operation, !Task.isCancelled else { return }
            if let index = runs.firstIndex(where: { $0.id == run.id }) { runs[index].results = results }
            await synthesize(runID: run.id, operation: operation)
        }
    }
    private func beginMethod(_ method: OracleMethod, index: Int, total: Int, runID: UUID, operation: UUID, conversationID: UUID) {
        guard operationID == operation, activeConversationID == conversationID,
              runs.contains(where: { $0.id == runID }), !Task.isCancelled else { return }
        progress("正在推演\(method.progressName)", detail: "第 \(index) 项，共 \(total) 项推演", method: method)
    }
    private func receive(_ result: OracleResult, for runID: UUID, operation: UUID) {
        guard operationID == operation, let index = runs.firstIndex(where: { $0.id == runID }) else { return }
        runs[index].results.append(result)
        finishActivity(status: result.status == .failed ? .failed : .completed)
        let detail = result.status == .unavailable ? "资料不足，此项不参与解读。" : "\(result.rows.count) 项盘面数据 · \(result.evidence.count) 条规则线索"
        progress("整理\(result.method.progressName)结果", detail: detail, method: result.method,
                 state: result.status == .failed ? .failed : .completed)
        persist()
    }
    func retrySynthesis(_ run: OracleRun) {
        guard !isBusy else { return }
        guard pendingInteraction == nil else { notice = "请先完成当前选择，再继续解读。"; return }
        beginActivitySession(); activityRunID = run.id
        progress("沿用已保存的推演结果", detail: run.results.map { $0.method.progressName }.joined(separator: "、"), state: .completed)
        phase = .synthesizing
        let operation = UUID(); operationID = operation
        task = Task { [weak self] in await self?.synthesize(runID: run.id, operation: operation) }
    }
    private func synthesize(runID: UUID, operation: UUID) async {
        guard operationID == operation, !Task.isCancelled,
              let run = runs.first(where: { $0.id == runID }) else { return }
        phase = .synthesizing
        let messageID = UUID()
        messages.append(ChatMessage(id: messageID, role: .assistant, content: "", kind: .reading, runID: runID))
        activityMessageID = messageID
        let history = ContextCompressor.history(messages: Array(messages.dropLast()), summary: summary)
        var synthesis: ReadingSynthesis
        if hasCredential && !localOnly {
            do {
                synthesis = try await client.synthesize(run: run, weights: weights, history: history, onProgress: { [weak self] stage in
                    await self?.readingProgress(stage, runID: runID, operation: operation)
                }) { [weak self] delta in
                    Task { @MainActor [weak self] in
                        guard let self, self.operationID == operation,
                              let index = self.messages.firstIndex(where: { $0.id == messageID }) else { return }
                        self.messages[index].content += delta
                    }
                }
            } catch {
                guard !Task.isCancelled else { return }
                notice = error.localizedDescription
                if let index = messages.firstIndex(where: { $0.id == messageID }) {
                    messages[index].content = "这次解读暂未完成，请稍后重试。已经确认的选择与本地结果都已保留。"
                }
                finishActivity(status: .failed)
                progress("解读暂未完成，结果已保留", detail: "可以沿用本次结果重试。", state: .failed)
                phase = waitingPhase; operationID = nil; persist(); return
            }
        } else {
            progress("整理本地规则摘要")
            synthesis = localReading(run, reason: localOnly ? "当前为本地试算，以下是规则摘要。" : "本地推演已完成。设置解读密钥后，可以继续听我细说。")
        }
        guard operationID == operation, !Task.isCancelled else { return }
        if run.selectedAlternative != nil, let original = run.synthesis?.alternatives, original.count == 2 {
            synthesis.alternatives = original
        }
        if let index = messages.firstIndex(where: { $0.id == messageID }) { messages[index].content = synthesis.text }
        if let index = runs.firstIndex(where: { $0.id == runID }) { runs[index].synthesis = synthesis; runs[index].completedAt = Date() }
        progress("解读已完成", state: .completed)
        phase = waitingPhase; operationID = nil; persist()
    }
    private func readingProgress(_ stage: AIReadingProgress, runID: UUID, operation: UUID) {
        guard operationID == operation, let run = runs.first(where: { $0.id == runID }), !Task.isCancelled else { return }
        let methods = run.results.filter { $0.status == .complete || $0.status == .partial }.map { $0.method.progressName }
        switch stage {
        case .preparing: progress("汇集各项推演结果", detail: methods.joined(separator: "、"))
        case .requesting:
            let names = methods.prefix(2).joined(separator: "、") + (methods.count > 2 ? "等" : "")
            progress(methods.count == 1 ? "正在解读\(names)结果" : "综合解析\(names)结果",
                     detail: "结合问题、已保存结果与资料限制生成解读。")
        case .writing: progress("正在整理中文解读")
        case .validating: progress("核对解读与分歧选项")
        }
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
        phase = .synthesizing; progress("结合已确认资料生成补充解读")
        let messageID = UUID()
        messages.append(ChatMessage(id: messageID, role: .assistant, content: "", runID: latestRun?.id))
        activityMessageID = messageID
        do {
            let text = try await client.followUp(question: question, run: latestRun, profile: profile, history: history) { [weak self] delta in
                Task { @MainActor [weak self] in
                    guard let self, self.operationID == operation, let index = self.messages.firstIndex(where: { $0.id == messageID }) else { return }
                    if self.activities.last?.text != "正在整理补充回答" { self.progress("正在整理补充回答") }
                    self.messages[index].content += delta
                }
            }
            guard operationID == operation else { return }
            if let index = messages.firstIndex(where: { $0.id == messageID }) { messages[index].content = text }
        } catch {
            guard !Task.isCancelled else { return }
            finishActivity(status: .failed)
            if let index = messages.firstIndex(where: { $0.id == messageID }) { messages[index].content = error.localizedDescription }
        }
        guard operationID == operation else { return }
        progress(activities.last?.status == .failed ? "补充回答暂未完成" : "补充回答已完成", state: activities.last?.status == .failed ? .failed : .completed)
        phase = waitingPhase; operationID = nil; persist()
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
        task?.cancel(); task = nil; operationID = nil; phase = waitingPhase
        finishActivity(status: .cancelled)
        progress("已停下，已有资料与结果仍保留", state: .cancelled)
        for index in messages.indices where messages[index].role == .assistant && messages[index].content.isEmpty {
            messages[index].content = "这次先停在这里。"
        }
        persist()
    }

    #if DEBUG
    /// Deterministic UI preview only. Production progress is driven exclusively
    /// by actual registry and network events, never by a rotating timer.
    private func startProgressPreview(paused: Bool) {
        beginActivitySession()
        messages = []
        for index in 1...3 {
            messages.append(ChatMessage(role: .user, content: "第\(index)次问事：接下来如何安排手头的计划？"))
            let paragraph = "先把手头的事情排出轻重，把需要确认的信息写下来。推进之前，留一点时间核对现实条件，再决定下一步。"
            messages.append(ChatMessage(role: .assistant, content: Array(repeating: paragraph, count: 3).joined(separator: "\n\n")))
        }
        messages.append(ChatMessage(role: .user, content: "请结合八字和紫微斗数，看看未来一个月的工作节奏。"))
        let messageID = UUID()
        messages.append(ChatMessage(id: messageID, role: .assistant, content: ""))
        activityMessageID = messageID
        let titles = ["理解问题与确认询问对象", "选择适用方法与所需资料", "核对资料与已确认的交互结果",
                      "正在推演八字", "整理八字结果", "正在推演紫微斗数", "整理紫微斗数结果",
                      "汇集本次盘面与交互数据", "综合解析八字、紫微斗数等结果"]
        var timeline = OracleProgressTimeline()
        let start = Date().addingTimeInterval(-Double(titles.count))
        for (index, title) in titles.enumerated() {
            timeline.begin(text: title, at: start.addingTimeInterval(Double(index)))
        }
        activities = timeline.activities; status = titles.last!
        phase = .synthesizing
        let operation = UUID(); operationID = operation
        syncActivities()
        guard !paused else { return }
        task = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(10))
                guard let self, self.operationID == operation, !Task.isCancelled else { return }
                progress("正在整理中文解读")
                if let index = messages.firstIndex(where: { $0.id == messageID }) {
                    messages[index].content = "接下来可以先稳住手头的安排，再逐步推进新的计划。把尚未确定的条件留出来核实，能让选择更从容。"
                }
                try await Task.sleep(for: .seconds(6))
                guard operationID == operation, !Task.isCancelled else { return }
                progress("解读已完成", state: .completed)
                phase = .idle; operationID = nil; persist()
            } catch { }
        }
    }
    #endif
}

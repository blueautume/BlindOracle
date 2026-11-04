import Foundation
import Combine

enum OraclePhase: String { case idle, planning, awaitingIntake, awaitingInteraction, calculating, synthesizing }

@MainActor final class OracleStore: ObservableObject {
    @Published var profiles: [OracleProfile]
    @Published var selfProfileID: UUID?
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
    @Published private(set) var intakeSessionID = UUID()
    @Published var intakeError: String?
    @Published var pendingInteraction: OracleInteractionSession?
    @Published var showInteraction = false
    @Published var notice: String?
    @Published private(set) var aiProvider: AIProvider
    @Published private(set) var hasCredential = false
    @Published private(set) var credentialIssue: String?
    @Published private(set) var connectionReport: AIConnectionReport?
    @Published private(set) var connectionFeedback: String?
    @Published private(set) var isCheckingConnection = false
    @Published var selectedTab = 0
    let registry = PluginRegistry()
    private lazy var deepSeekClient = DeepSeekClient(provider: .deepSeek)
    private lazy var qwenClient = DeepSeekClient(provider: .qwen)
    var client: DeepSeekClient { aiProvider == .deepSeek ? deepSeekClient : qwenClient }
    var credentialStore: KeychainStore { KeychainStore.store(for: aiProvider) }
    private let vault: LocalVault
    private var task: Task<Void, Never>?
    private var operationID: UUID?
    private var activityRunID: UUID?
    var isBusy: Bool { [.planning, .calculating, .synthesizing].contains(phase) }
    private var waitingPhase: OraclePhase { pendingInteraction != nil ? .awaitingInteraction : pendingPlan != nil ? .awaitingIntake : .idle }
    var profile: OracleProfile { profiles.first(where: { $0.id == selfProfileID }) ?? OracleProfile() }
    var latestRun: OracleRun? {
        guard let reference = messages.last(where: { $0.runID != nil || $0.deletedRunID != nil }),
              reference.deletedRunID == nil, let id = reference.runID else { return nil }
        return runs.first { $0.id == id }
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
        aiProvider = UserDefaults.standard.string(forKey: AIProvider.selectionKey)
            .flatMap(AIProvider.init(rawValue:)) ?? .deepSeek
        self.vault = vault
        let history = ConversationHistory.load(from: vault)
        conversations = history.archive.conversations
        activeConversationID = history.archive.activeConversationID
        let active = history.archive.conversations.first { $0.id == history.archive.activeConversationID }
        let originalProfiles = vault.load([OracleProfile].self, from: "profiles", fallback: [])
        let storedProfiles = originalProfiles.filter {
            $0.isAnonymousRecord == true || !($0.alias ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || !$0.resolvedName.isEmpty || $0.birthDate != nil || !$0.birthPlace.isEmpty
        }
        profiles = storedProfiles
        if vault.contains("self-profile-id") {
            selfProfileID = vault.load(UUID?.self, from: "self-profile-id", fallback: nil)
        } else {
            // Prior releases explicitly treated the first legacy record as self.
            // Named records created by the new directory never acquire this role.
            let originalSelf = originalProfiles.first
            selfProfileID = originalSelf?.name == nil && originalSelf?.isAnonymousRecord != true
                && storedProfiles.contains(where: { $0.id == originalSelf?.id }) ? originalSelf?.id : nil
        }
        messages = active?.messages ?? []
        runs = vault.load([OracleRun].self, from: "readings", fallback: [])
        weights = PreferenceLearning.normalized(vault.load([String: Double].self, from: "preferences", fallback: PreferenceLearning.initial))
        summary = active?.summary ?? ConversationSummary()
        pendingPlan = active?.pendingPlan
        pendingInteraction = active?.pendingInteraction
        phase = waitingPhase
        let recoveredClarification = recoverCommittedClarification()
        let discardedSupplement = discardMissingSupplement()
        if history.needsInitialSave {
            do { try vault.save(history.archive, as: ConversationHistory.filename) }
            catch { notice = "历史对话暂未写入磁盘，请检查设备可用空间。" }
        }
        if history.recoveredUnreadableFile {
            notice = history.recoveryCopyPreserved
                ? "历史对话有部分内容无法读取，已尽可能恢复可用对话并保留原文件副本。"
                : "历史对话有部分内容无法读取，原文件暂时无法备份，已阻止覆盖，请检查设备可用空间。"
        }
        if bootstrapCredential { refreshCredential() }
        if let plan = pendingPlan { prepareConversation(plan, appendMessage: false) }
        else if restoreActivities() || discardedSupplement || recoveredClarification { persist() }
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--ui-testing-local") && ProcessInfo.processInfo.arguments.contains("--ui-testing-reading-library") {
            seedReadingLibraryPreview()
        }
        if ProcessInfo.processInfo.arguments.contains("--ui-testing-progress") || ProcessInfo.processInfo.arguments.contains("--ui-testing-progress-paused") {
            startProgressPreview(paused: ProcessInfo.processInfo.arguments.contains("--ui-testing-progress-paused"))
        }
        #endif
    }

    var connectionStatus: String {
        if localOnly { return "仅本地规则摘要 · AI 未启用" }
        if credentialIssue != nil { return "\(aiProvider.displayName) 密钥读取异常 · 请检查设置" }
        guard hasCredential else { return "仅本地规则摘要 · 未配置 \(aiProvider.displayName) 密钥" }
        let model = aiProvider.model()
        let title: String
        switch aiProvider {
        case .deepSeek: title = model == DeepSeekConfiguration.defaultModel ? "DeepSeek Pro" : model
        case .qwen: title = "\(aiProvider.displayName) · \(model)"
        }
        return "\(title) · \(aiProvider.reasoningDescription)"
    }

    func selectAIProvider(_ provider: AIProvider) {
        guard provider != aiProvider, !isBusy, !isCheckingConnection else { return }
        aiProvider = provider
        UserDefaults.standard.set(provider.rawValue, forKey: AIProvider.selectionKey)
        invalidateConnectionReport()
        refreshCredential()
    }

    func refreshCredential(importBundledKey: Bool = true) {
        let keychain = credentialStore
        var bootstrapIssue: String?
        if importBundledKey {
            do { try keychain.bootstrapDevelopmentKey() }
            catch { bootstrapIssue = error.localizedDescription }
        }
        var issue: String?
        do { hasCredential = try keychain.load() != nil }
        catch { hasCredential = false; issue = error.localizedDescription }
        credentialIssue = issue
        if let issue = issue ?? bootstrapIssue { notice = issue }
    }

    func invalidateConnectionReport() { connectionReport = nil; connectionFeedback = nil }

    func restoreRecommendedConnection() {
        guard aiProvider == .deepSeek else { return }
        DeepSeekConfiguration.restoreRecommendedSettings()
        connectionReport = nil; connectionFeedback = "已恢复 DeepSeek Pro 联网解读，深度思考强度 max。"
        refreshCredential()
    }

    func checkAIConnection() async {
        guard !isCheckingConnection else { return }
        isCheckingConnection = true; connectionFeedback = nil; connectionReport = nil
        defer { isCheckingConnection = false }
        refreshCredential()
        guard hasCredential else {
            connectionFeedback = credentialIssue ?? "尚无可用的 \(aiProvider.displayName) 密钥，请检查安装包或保存自己的密钥。"
            return
        }
        do {
            connectionReport = try await client.checkConnection()
            connectionFeedback = localOnly ? "连接正常；当前聊天仍处于仅本地试算。" : "连接正常，已收到真实模型响应。"
        } catch { connectionFeedback = error.localizedDescription }
    }
    /// Save the latest streamed text before the app can be suspended. The live
    /// task continues; only a later process restart marks its work interrupted.
    func checkpoint() { persist() }
    private func persist() {
        syncActivities()
        captureCurrentConversation()
        do {
            try vault.save(profiles, as: "profiles")
            try vault.save(selfProfileID, as: "self-profile-id")
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
        var copy = ProfileDirectory.assigningDefaultBirthTimeZone(to: value)
        copy.updatedAt = Date()
        copy.isAnonymousRecord = copy.resolvedName.isEmpty ? true : nil
        if let index = profiles.firstIndex(where: { $0.id == copy.id }) { profiles[index] = copy }
        else { profiles.append(copy) }
        persist()
    }
    func deleteProfile(id: UUID) {
        profiles.removeAll { $0.id == id }
        if selfProfileID == id { selfProfileID = nil }
        persist()
    }
    func deleteReading(id: UUID) {
        guard runs.contains(where: { $0.id == id }) else { return }
        let ownsActivity = activityRunID == id || activityMessageID.map { messageID in
            messages.contains { $0.id == messageID && $0.runID == id }
        } == true
        if ownsActivity {
            let emptyReadingMessages = Set(messages.filter { $0.runID == id && $0.content.isEmpty }.map(\.id))
            cancelConversationTask()
            for index in messages.indices where emptyReadingMessages.contains(messages[index].id) {
                messages[index].content = "这份推演记录已删除。"
            }
            activityRunID = nil; activityMessageID = nil
            activities = []; status = ""; activitySessionID = UUID()
            phase = waitingPhase
        }
        runs.removeAll { $0.id == id }
        _ = discardMissingSupplement()
        func detach(_ transcript: inout [ChatMessage]) {
            for index in transcript.indices where transcript[index].runID == id {
                transcript[index].runID = nil; transcript[index].deletedRunID = id
            }
        }
        detach(&messages)
        for index in conversations.indices {
            detach(&conversations[index].messages)
            let dependedOnDeletedRun = conversations[index].pendingPlan?.baseRunID == id || conversations[index].pendingInteraction?.plan.baseRunID == id
            if conversations[index].pendingPlan?.baseRunID == id { conversations[index].pendingPlan = nil }
            if conversations[index].pendingInteraction?.plan.baseRunID == id { conversations[index].pendingInteraction = nil }
            if dependedOnDeletedRun, let messageIndex = conversations[index].messages.lastIndex(where: { $0.kind == .intake && $0.runID == nil }) {
                var timeline = OracleProgressTimeline(activities: conversations[index].messages[messageIndex].activities ?? [])
                timeline.finish(status: .cancelled)
                conversations[index].messages[messageIndex].activities = timeline.activities
            }
        }
        persist()
    }
    func defaultParticipants(for plan: OraclePlan) -> [OracleProfile] {
        if let ids = plan.participantIDs, !ids.isEmpty {
            var seen = Set<UUID>()
            return ids.compactMap { id in seen.insert(id).inserted ? profiles.first(where: { $0.id == id }) : nil }
        }
        if let names = plan.participantNames, !names.isEmpty {
            let resolution = resolveSavedPeople(names)
            return resolution.ids.compactMap { id in profiles.first(where: { $0.id == id }) }
        }
        if plan.subject == "本人", let selfProfileID, let own = profiles.first(where: { $0.id == selfProfileID }) { return [own] }
        return []
    }

    private func resolveSavedPeople(_ names: [String]) -> ProfileResolution {
        var result = ProfileResolution(ids: [], issues: [])
        var seen = Set<UUID>()
        for name in names {
            let resolved = ProfileDirectory.resolve(names: [name], in: profiles)
            let label = name.split(whereSeparator: \.isWhitespace).joined(separator: " ").precomposedStringWithCanonicalMapping
            let nameIDs = Set(resolved.ids + resolved.issues.flatMap(\.candidateIDs))
            let matches = profiles.filter { person in
                nameIDs.contains(person.id) || person.participantLabel.split(whereSeparator: \.isWhitespace)
                    .joined(separator: " ").precomposedStringWithCanonicalMapping == label
            }
            if matches.count == 1, let id = matches.first?.id {
                if seen.insert(id).inserted { result.ids.append(id) }
            } else if matches.count > 1 {
                result.issues.append(.init(kind: .ambiguousName, name: label, message: "有多位人员使用称呼\(label)，请从档案中选取。",
                                           candidateIDs: matches.map(\.id)))
            } else {
                result.issues += resolved.issues
            }
        }
        return result
    }
    @discardableResult func applyProfileUpdates(_ updates: [ProfileUpdate]) -> ProfileMergeResult {
        let result = ProfileDirectory.applying(updates, to: profiles)
        profiles = result.profiles
        if var drafts = pendingPlan?.draftParticipants {
            for var update in updates {
                let matches = profiles.filter { $0.id == update.id || (update.id == nil && $0.resolvedName == update.name) }
                guard matches.count == 1, let id = matches.first?.id,
                      result.appliedIDs.contains(id), drafts.contains(where: { $0.id == id }) else { continue }
                update.id = id
                drafts = ProfileDirectory.applying([update], to: drafts).profiles
            }
            pendingPlan?.draftParticipants = drafts
        }
        if !result.issues.isEmpty { notice = result.issues.map(\.message).joined(separator: "\n") }
        persist()
        return result
    }
    private func localPeoplePlan(question: String, collectedIDs: [UUID]) -> OraclePlan {
        var plan = registry.localPlan(question: question, profile: profile)
        let statement = !collectedIDs.isEmpty || !ProfileDirectory.parseExplicitUpdates(in: question, profiles: profiles).isEmpty
        let asks = ["？", "?", "看看", "算卦", "问卦", "如何", "怎样", "适合", "关系", "友情", "姻缘", "婚姻", "合作", "运势", "建议", "合不合", "感情"]
            .contains(where: question.contains)
        let deferReading = ["不要算", "先不算", "暂不算", "不需要解读"].contains(where: question.contains)
        if statement && (!asks || deferReading) {
            plan.action = "collect"; plan.methods = []; plan.requiredFields = []; plan.interactions = []
            let names = collectedIDs.compactMap { id in profiles.first(where: { $0.id == id })?.resolvedName }
            plan.note = names.isEmpty ? (notice ?? "请明确需要补充哪位的资料。") : "已分别记下\(names.joined(separator: "、"))的资料。可以继续补充，或告诉我这次想问的事。"
            return plan
        }
        let target = ReadingContinuationPolicy.participantIntent(in: question, profiles: profiles)
        if target.isGroup {
            plan.subject = "多人"
            plan.relationship = ["友情", "姻缘", "婚姻", "合作", "恋爱", "家庭"].first(where: question.contains) ?? "关系"
            if !plan.methods.contains(.tarot) && !plan.methods.contains(where: \.usesPersonalProfile) {
                plan.methods += [.bazi, .ziwei, .astrology]
                plan.requiredFields = Array(Set(plan.methods.flatMap { registry.plugin($0)?.descriptor.requiredFields ?? [] }))
            }
        }
        return plan
    }
    func resolveParticipants(in plan: inout OraclePlan, question: String) {
        let target = ReadingContinuationPolicy.participantIntent(in: question, profiles: profiles)
        let excluded = Set(target.excludedNames)
        plan.participantNames = plan.participantNames?.filter { !excluded.contains($0) }
        if !excluded.isEmpty {
            let excludedIDs = Set(profiles.filter { excluded.contains($0.resolvedName) }.map(\.id))
            plan.participantIDs = plan.participantIDs?.filter { !excludedIDs.contains($0) }
        }
        if !target.names.isEmpty || target.includesSelf {
            var names = target.names
            if target.isGroup {
                let additionalNames = (plan.participantNames ?? []).filter { name in question.contains(name) && !names.contains(name) }
                names += additionalNames
            }
            let match = resolveSavedPeople(names)
            let selected = Set(pendingPlan?.participantIDs ?? [])
            var ids = match.ids + match.issues.flatMap { issue in
                issue.candidateIDs.filter { selected.contains($0) }
            }
            if target.includesSelf, let selfProfileID, !ids.contains(selfProfileID) { ids.insert(selfProfileID, at: 0) }
            plan.participantNames = names
            plan.participantIDs = ids
        } else if target.refersToOther {
            plan.participantIDs = plan.participantIDs?.filter { $0 != selfProfileID }
            plan.participantNames = plan.participantNames?.filter { $0 != profile.resolvedName && $0 != profile.participantLabel }
        }
        if target.isGroup { plan.subject = "多人" }
        else if target.includesSelf { plan.subject = "本人" }
        else if !target.names.isEmpty || target.refersToOther {
            plan.subject = plan.participantIDs?.count == 1 && plan.participantIDs?.first == selfProfileID ? "本人" : "他人"
        }
        let hasExplicitIDs = !(plan.participantIDs ?? []).isEmpty
        var seenNames = Set<String>()
        let requestedNames = (plan.participantNames ?? []).filter { seenNames.insert($0).inserted }
        let newNames = requestedNames.filter { name in
            !["我", "本人", "他人", "朋友", "对象"].contains(name)
                && !profiles.contains(where: { $0.resolvedName == name || $0.participantLabel == name })
                && ProfileDirectory.isAffirmativeParticipantReference(name, in: question, profiles: profiles)
        }
        if !newNames.isEmpty { _ = applyProfileUpdates(newNames.map { ProfileUpdate(name: $0) }) }
        let validIDs = Set(profiles.map(\.id))
        if let ids = plan.participantIDs {
            var seen = Set<UUID>()
            plan.participantIDs = ids.filter { id in
                guard validIDs.contains(id), seen.insert(id).inserted, let person = profiles.first(where: { $0.id == id }) else { return false }
                if person.resolvedName.isEmpty { return true }
                let sameName = profiles.filter { $0.resolvedName == person.resolvedName }
                return sameName.count <= 1 || pendingPlan?.participantIDs?.contains(id) == true
            }
        }
        if !requestedNames.isEmpty {
            let match = resolveSavedPeople(requestedNames)
            if !match.issues.isEmpty { notice = match.issues.map(\.message).joined(separator: "\n") }
            if !hasExplicitIDs { plan.participantIDs = match.ids }
            else if target.isGroup, !target.names.isEmpty || target.includesSelf {
                let chosen = plan.participantIDs ?? []
                plan.participantIDs = chosen + match.ids.filter { !chosen.contains($0) }
            }
        } else if (plan.participantIDs ?? []).isEmpty, plan.subject == "本人", let selfProfileID {
            plan.participantIDs = [selfProfileID]
        }
        if let ids = plan.participantIDs, !ids.isEmpty {
            let selected = ids.compactMap { id in profiles.first(where: { $0.id == id }) }
            plan.participantNames = selected.map(\.participantLabel) + requestedNames.filter { name in
                !selected.contains { $0.resolvedName == name || $0.participantLabel == name }
            }
        }
        if let ids = plan.participantIDs, ids.count > 1 { plan.subject = "多人" }
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
        recoverCommittedClarification()
        clearConversationPresentation()
        _ = discardMissingSupplement()
        if let plan = pendingPlan { prepareConversation(plan, appendMessage: false) }
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
        showIntake = false; showInteraction = false; notice = nil; intakeError = nil; status = ""; activities = []
        intakeSessionID = UUID()
        phase = waitingPhase
        activityMessageID = nil; activityRunID = nil; activitySessionID = UUID()
        restoreActivities()
    }

    @discardableResult private func discardMissingSupplement() -> Bool {
        let dependencies = [pendingPlan?.baseRunID, pendingInteraction?.plan.baseRunID].compactMap { $0 }
        guard dependencies.contains(where: { id in !runs.contains { $0.id == id } }) else { return false }
        task?.cancel(); task = nil; operationID = nil
        pendingPlan = nil; pendingInteraction = nil; showIntake = false; showInteraction = false
        intakeSessionID = UUID(); intakeError = nil; phase = .idle
        activityRunID = nil
        notice = "原推演记录已删除，这次未完成的补充推演已取消；请重新提出问题。"
        progress("补充推演已取消", detail: "原推演记录已删除。", state: .cancelled)
        return true
    }

    @discardableResult private func recoverCommittedClarification() -> Bool {
        guard let request = pendingInteraction?.currentRequest?.tarotClarification,
              let run = runs.last(where: { $0.input.tarotClarificationRounds?.last?.request.id == request.id }) else { return false }
        // Readings are saved before the conversation. An interruption between
        // those writes can leave the old selection sheet in the transcript.
        pendingInteraction = nil; phase = waitingPhase
        if let index = messages.lastIndex(where: { $0.kind == .intake && $0.runID == nil && $0.deletedRunID == nil }) {
            messages[index].runID = run.id
            messages[index].content = "补牌已保存，可以继续结合完整牌阵解读。"
        }
        return true
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
    @discardableResult private func restoreActivities() -> Bool {
        var interrupted = false
        let awaitingUser = pendingPlan != nil || pendingInteraction != nil
        if let message = messages.last(where: {
            !($0.activities ?? []).isEmpty && (!awaitingUser || ($0.kind == .intake && $0.runID == nil))
        }) {
            activityMessageID = message.id
            activityRunID = message.kind == .reading || message.kind == .intake ? message.runID : nil
            activities = message.activities ?? []; activitySessionID = message.id
            if activities.last?.status == .running { finishActivity(status: .cancelled); interrupted = true }
            status = activities.last?.text ?? ""
        } else if !awaitingUser, let run = latestRun, let saved = run.activities, !saved.isEmpty {
            activities = saved; activityRunID = run.id; activitySessionID = run.id
            activityMessageID = messages.last(where: { $0.runID == run.id && $0.kind == .reading })?.id
            if activities.last?.status == .running { finishActivity(status: .cancelled); interrupted = true }
            status = activities.last?.text ?? ""
        }
        if interrupted {
            if let id = activityMessageID, let index = messages.firstIndex(where: { $0.id == id }),
               messages[index].role == .assistant, messages[index].content.isEmpty {
                messages[index].content = "上次回答中断，已保存的资料与结果仍保留。"
            }
            notice = notice ?? "上次处理已中断，已保存的资料、部分回答与本地结果仍保留。"
        }
        if !awaitingUser, exposeInterruptedTarotReading() { interrupted = true }
        if awaitingUser {
            activityRunID = nil
            activityMessageID = messages.last(where: { $0.kind == .intake && $0.runID == nil })?.id
            progress(pendingInteraction != nil ? interactionStatus : "等待你确认问事资料", state: .waiting)
        }
        return interrupted
    }

    @discardableResult private func exposeInterruptedTarotReading() -> Bool {
        guard let run = latestRun, run.plan.tarotClarification != nil, run.synthesis == nil,
              !messages.contains(where: { $0.runID == run.id && $0.kind == .reading }),
              let index = messages.lastIndex(where: { $0.runID == run.id && $0.kind == .intake }) else { return false }
        messages[index].kind = .reading
        messages[index].content = "补牌已保存，可以继续结合完整牌阵解读。"
        return true
    }
    private var interactionStatus: String {
        if pendingInteraction?.currentRequest?.tarotClarification != nil { return "等待你选择并翻开一张补牌" }
        return switch pendingInteraction?.currentRequest?.kind {
        case .tarot: "等待你选牌并翻开"
        case .numbers: "等待你留下三个数字"
        case .coins: "等待你依次留下六爻"
        case nil: "等待你确认选择"
        }
    }

    var intakeParticipants: [OracleProfile] {
        guard let plan = pendingPlan else { return [] }
        return initialIntakeParticipants(for: plan)
    }
    var intakeNumbers: [Int] { pendingPlan?.draftNumbers ?? [] }

    func intakePreparationReport(for participants: [OracleProfile]) -> ReadingPreparationReport? {
        guard let plan = pendingPlan else { return nil }
        return ReadingPreparationPolicy.evaluate(plan: plan, participants: participants.map(ProfileDirectory.assigningDefaultBirthTimeZone(to:)),
                                                 descriptors: registry.descriptors)
    }

    var canConfirmIntake: Bool {
        guard let report = intakePreparationReport(for: intakeParticipants), !isBusy else { return false }
        return report.canProceed
    }

    /// Compatibility entry point for the chat's reopen control. Only submitting
    /// the form authorizes a calculation; a chat confirmation never bypasses it.
    func confirmPendingIntake() {
        guard pendingPlan != nil, !isBusy else { return }
        intakeError = nil; showIntake = true; showInteraction = false; phase = .awaitingIntake
    }

    func saveIntakeDraft(profiles: [OracleProfile], numbers: [Int], sessionID: UUID) {
        guard sessionID == intakeSessionID, pendingPlan != nil, !isBusy else { return }
        pendingPlan?.draftParticipants = profiles
        pendingPlan?.draftNumbers = numbers
        persist()
    }

    private func prepareConversation(_ proposed: OraclePlan, clarification: String? = nil, pendingAnswer: String? = nil, appendMessage: Bool = true) {
        var plan = proposed
        // Legacy field-by-field preparations reopen as one complete form.
        plan.preparationStage = .collecting
        plan.requestedProfileID = nil; plan.requestedFields = nil
        plan.reviewedParticipants = nil; plan.pendingAnswer = nil
        let people = initialIntakeParticipants(for: plan)
        let report = ReadingPreparationPolicy.evaluate(plan: plan, participants: people, descriptors: registry.descriptors)
        plan.omittedMethods = report.omissions; plan.preparationNotes = preparationNotes(report)
        if appendMessage, pendingPlan != nil, let old = pendingIntakeMessageID,
           let index = messages.firstIndex(where: { $0.id == old }) {
            messages[index].kind = .notice
            messages[index].content = "这张问事笺已替换，请使用最新的问事笺。"
        }
        pendingPlan = plan; intakeSessionID = UUID(); intakeError = nil
        if appendMessage || !messages.contains(where: { $0.kind == .intake && $0.runID == nil && $0.deletedRunID == nil }) {
            let message = clarification ?? "请在问事资料中填写并核对信息。确认后开始推演，需要抽牌或投掷时会进入下一步。"
            messages.append(ChatMessage(role: .assistant, content: message, kind: .intake))
        }
        activityMessageID = messages.last(where: { $0.kind == .intake && $0.runID == nil })?.id
        progress("等待填写并确认问事资料", state: .waiting)
        showIntake = true; showInteraction = false
        phase = .awaitingIntake; operationID = nil; persist()
    }

    private func preparationParticipants(for plan: OraclePlan) -> [OracleProfile] {
        let people = defaultParticipants(for: plan)
        return plan.collectionDeclined == true && plan.subject == "多人" && people.count < 2 ? [] : people
    }

    private func initialIntakeParticipants(for plan: OraclePlan) -> [OracleProfile] {
        if let drafts = plan.draftParticipants {
            return drafts.map { draft in
                guard let saved = profiles.first(where: { $0.id == draft.id }) else { return draft }
                return ProfileDirectory.restoringKnownFields(in: draft, from: saved)
            }
        }
        let selected = preparationParticipants(for: plan)
        guard selected.isEmpty, plan.subject == "本人", selfProfileID == nil,
              (plan.participantIDs ?? []).isEmpty, (plan.participantNames ?? []).isEmpty,
              plan.collectionDeclined != true else { return selected }
        // A sole saved person is a visible form candidate, never an implicit
        // self binding or permission to calculate without confirmation.
        return profiles.count == 1 ? profiles : []
    }

    private func preparationNotes(_ report: ReadingPreparationReport) -> [String] {
        var notes = report.omissions.map { omission in
            "本次未采用\(omission.participantName.map { $0 + "的" } ?? "")\(omission.method.progressName)参考：\(omission.reason.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters)))。补齐资料后可以再看。"
        }
        notes += report.assessments.filter(\.canExecute).flatMap { assessment in
            assessment.limitations.map { "\(assessment.participantName.map { $0 + "：" } ?? "")\($0)" }
        }
        var seen = Set<String>()
        return notes.filter { seen.insert($0).inserted }
    }

    private func reusableResults(input: OracleInput, plan: OraclePlan) -> [OracleResult] {
        guard let id = plan.baseRunID, let base = runs.first(where: { $0.id == id }) else { return [] }
        return ReadingContinuationPolicy.reusableResults(from: base, for: input, methods: plan.methods).filter {
            registry.plugin($0.method)?.descriptor.version == $0.version
        }.filter { result in
            !(plan.omittedMethods ?? []).contains {
                $0.method == result.method && (!result.method.usesPersonalProfile || $0.participantID == nil || $0.participantID == result.participantID)
            }
        }
    }

    private func supplementInput(base: OracleRun, plan: OraclePlan, participants: [OracleProfile], numbers: [Int]) -> OracleInput {
        var input = base.input
        // Retain the question's casting instant, seed and completed operations.
        // A new person must not silently replace the global casting time zone.
        input.question = base.input.question; input.subject = plan.subject
        input.participants = participants; input.relationship = plan.relationship
        if let updated = participants.first(where: { $0.id == base.input.profile.id }) { input.profile = updated }
        input.numbers = numbers
        if numbers == base.input.numbers {
            if base.input.profile.unknownFields.contains(.numbers) { input.profile.unknownFields.insert(.numbers) }
            else { input.profile.unknownFields.remove(.numbers) }
        } else if numbers.count == 3, numbers.allSatisfy({ (1...999).contains($0) }) { input.profile.unknownFields.remove(.numbers) }
        return input
    }

    /// Returns false when every requested calculation is still valid; the caller
    /// then answers from the existing run without creating another record.
    private func prepareSupplement(_ proposed: OraclePlan, base: OracleRun, question: String) -> Bool {
        guard runs.contains(where: { $0.id == base.id }) else {
            operationID = nil; phase = waitingPhase
            progress("补充推演已取消", detail: "原推演记录已删除。", state: .cancelled)
            notice = "原推演记录已删除，无法继续这次补充推演。"; persist()
            return true
        }
        var plan = proposed
        plan.baseRunID = base.id; plan.followUpQuestion = question; plan.question = base.input.question
        plan.action = "supplement"; plan.subject = base.input.subject
        plan.relationship = proposed.relationship ?? base.input.relationship
        let available = base.results.filter { $0.status == .complete || $0.status == .partial }.map(\.method)
        let methods = Set(available + proposed.methods)
        plan.methods = OracleMethod.allCases.filter { methods.contains($0) }
        plan.requiredFields = Array(Set(proposed.requiredFields + registry.descriptors.filter { methods.contains($0.method) }.flatMap(\.requiredFields)))
        let originals = base.input.readingParticipants
        let selectedIDs = (proposed.participantIDs ?? []).isEmpty ? originals.map(\.id) : proposed.participantIDs ?? []
        var people = selectedIDs.compactMap { id -> OracleProfile? in
            guard let original = originals.first(where: { $0.id == id }) else { return profiles.first { $0.id == id } }
            guard let saved = profiles.first(where: { $0.id == id }) else { return original }
            return saved.updatedAt > original.updatedAt ? saved : ProfileDirectory.restoringKnownFields(in: original, from: saved)
        }
        if people.isEmpty, plan.methods.contains(where: \.usesPersonalProfile) {
            people = initialIntakeParticipants(for: plan)
        }
        plan.participantIDs = people.map(\.id); plan.participantNames = people.map(\.participantLabel)
        if people.count > 1 { plan.subject = "多人" }
        plan.draftParticipants = people; plan.draftNumbers = base.input.numbers
        let input = supplementInput(base: base, plan: plan, participants: people, numbers: base.input.numbers)
        let reused = reusableResults(input: input, plan: plan)
        let report = ReadingPreparationPolicy.evaluate(plan: plan, participants: people, descriptors: registry.descriptors)
        let needsCalculation = report.assessments.contains { assessment in
            !reused.contains { $0.method == assessment.method && (!assessment.method.usesPersonalProfile || $0.participantID == assessment.participantID) }
        }
        guard needsCalculation else { return false }
        let newPeople = people.contains { person in !originals.contains { $0.id == person.id } }
        let needsNumbers = OracleInteractionPolicy.requests(for: plan, numbers: input.numbers).contains { $0.kind == .numbers }
        if newPeople || needsNumbers || !report.canProceed || report.assessments.contains(where: { !$0.canExecute }) {
            prepareConversation(plan)
            return true
        }
        plan.omittedMethods = report.omissions; plan.preparationNotes = preparationNotes(report)
        plan.reviewedParticipants = people; plan.draftParticipants = nil; plan.draftNumbers = nil
        messages.append(ChatMessage(role: .assistant, content: "沿用已有结果，只补充新增方法或资料变化后需要更新的部分。", kind: .intake))
        activityMessageID = messages.last?.id
        launchPreparedReading(input: input, plan: plan)
        return true
    }

    private func launchPreparedReading(input: OracleInput, plan: OraclePlan) {
        let requests = OracleInteractionPolicy.requests(for: plan, numbers: input.numbers).filter { request in
            let response: OracleInteractionResponse
            switch request.kind {
            case .coins: response = .init(requestID: request.id, lines: input.manualLines)
            case .tarot: response = .init(requestID: request.id, tarotDraws: input.tarotDraws ?? [], revealedCount: input.tarotDraws?.count ?? 0)
            case .numbers: response = .init(requestID: request.id, numbers: input.numbers)
            }
            return !OracleInteractionPolicy.isValid(response, for: request, complete: true)
        }
        if !requests.isEmpty {
            pendingInteraction = OracleInteractionSession(input: input, plan: plan, requests: requests)
            pendingPlan = nil; showIntake = false; phase = .awaitingInteraction; operationID = nil
            presentRequestedInteraction()
        } else { startReading(input: input, plan: plan) }
    }

    private func methodsMentioned(in text: String, positiveRequestsOnly: Bool = false) -> [OracleMethod] {
        let aliases: [(OracleMethod, [String])] = [(.bazi, ["八字", "四柱"]), (.ziwei, ["紫微", "紫薇"]), (.liuyao, ["六爻"]), (.meihua, ["梅花"]), (.qimen, ["奇门"]), (.xiaoliuren, ["小六壬"]), (.chenggu, ["称骨"]), (.xingming, ["姓名五格", "五格"]), (.astrology, ["占星", "星盘"]), (.tarot, ["塔罗", "塔羅", "tarot"])]
        return aliases.filter { entry in
            entry.1.contains { alias in
                guard positiveRequestsOnly else { return text.localizedCaseInsensitiveContains(alias) }
                guard let expression = try? NSRegularExpression(pattern: NSRegularExpression.escapedPattern(for: alias), options: .caseInsensitive) else { return false }
                return expression.matches(in: text, range: NSRange(text.startIndex..<text.endIndex, in: text)).contains { match in
                    guard let range = Range(match.range, in: text) else { return false }
                    let prefix = String(text[..<range.lowerBound].suffix(16))
                    return prefix.range(of: #"(?:不|别|不要|不用|无需|不必|不想|不需要|并非)[^，,。；;\n]{0,5}$"#, options: .regularExpression) == nil
                }
            }
        }.map(\.0)
    }

    private func enforceRequestedMethods(_ plan: inout OraclePlan, text: String) {
        let named = methodsMentioned(in: text, positiveRequestsOnly: true)
        let required = ["只", "仅", "必须", "指定", "一定要"].contains(where: text.contains)
        let revision = ["换成", "改用", "改成", "换用", "改为", "改按"].contains(where: text.contains)
        if revision, !named.isEmpty { plan.methods = named; plan.mandatoryMethods = required || named.count == 1 ? named : [] }
        let specific = named.count == 1 && !["混合", "结合", "综合"].contains(where: text.contains) && ["按照", "用八字", "用紫微", "用紫薇"].contains(where: text.contains)
        if !named.isEmpty, required || specific {
            plan.mandatoryMethods = named
            if ["只", "仅"].contains(where: text.contains) { plan.methods = named }
            else { plan.methods = Array(Set(plan.methods + named)).sorted { $0.rawValue < $1.rawValue } }
        }
    }

    func tarotClarificationOffer(for message: ChatMessage) -> TarotClarificationSuggestion? {
        guard !isBusy, pendingInteraction == nil, pendingPlan == nil,
              messages.last?.id == message.id, message.role == .assistant,
              let base = latestRun, base.id == message.runID, ReadingContextBuilder.canSuggestTarotClarification(for: base),
              let offer = message.tarotClarificationOffer, offer.isValid else { return nil }
        return offer
    }

    func acceptTarotClarification(messageID: UUID) {
        guard let message = messages.last, message.id == messageID,
              let offer = tarotClarificationOffer(for: message), let base = latestRun else { return }
        let question = message.kind == .reading ? base.plan.followUpQuestion ?? base.input.question
            : messages.dropLast().last(where: { $0.role == .user })?.content ?? base.input.question
        messages.append(ChatMessage(role: .user, content: "补抽 1 张 · \(offer.focus)"))
        startTarotClarification(offer, base: base, question: question)
    }

    private func startTarotClarification(_ suggestion: TarotClarificationSuggestion, base: OracleRun, question: String) {
        let clarification = TarotClarificationRequest(focus: suggestion.focus, originalPosition: suggestion.originalPosition, question: question)
        var plan = base.plan
        plan.action = "supplement"; plan.baseRunID = base.id; plan.followUpQuestion = question
        plan.tarotClarification = suggestion
        let request = OracleInteractionRequest(method: .tarot, kind: .tarot, tarotClarification: clarification)
        beginActivitySession()
        messages.append(ChatMessage(role: .assistant, content: "请选择一张补牌。本轮关注「\(clarification.focus)」。", kind: .intake))
        activityMessageID = messages.last?.id
        pendingInteraction = OracleInteractionSession(input: base.input, plan: plan, requests: [request])
        phase = .awaitingInteraction
        presentRequestedInteraction()
    }

    private func tarotClarificationCommand(_ question: String) -> String? {
        let prefix = #"^(?:(?:我想|我要|可以|能否|请你|请|帮我|给我|再|继续|就)\s*)*"#
        let action = #"(?:(?:补抽|加抽|追加|补|再抽|继续抽)\s*(?:[一1１]\s*)?张\s*(?:塔罗牌?|澄清牌|牌)?|(?:补抽|加抽|追加|补)\s*(?:塔罗牌?|澄清牌|牌)|抽\s*(?:[一1１]\s*)?张\s*澄清牌)"#
        let suffix = #"(?:[吧吗]|可以吗)?(?:[。！!？?]*$|\s*[,，:：]\s*|\s*(?=看看|看|问|澄清|针对|确认))"#
        guard let command = question.range(of: prefix + action + suffix, options: .regularExpression),
              !ReadingContinuationPolicy.explicitlyRequestsNewReading(question) else { return nil }
        let focus = question[command.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        return String(focus.prefix(160))
    }

    private func handleTarotClarificationCommand(_ text: String, base: OracleRun) -> Bool {
        guard let focus = tarotClarificationCommand(text) else { return false }
        let offer = messages.last.flatMap { tarotClarificationOffer(for: $0) }
        messages.append(ChatMessage(role: .user, content: text))
        guard ReadingContextBuilder.canSuggestTarotClarification(for: base) else {
            let content = (base.input.tarotClarificationRounds?.count ?? 0) >= TarotClarificationRequest.maximumRounds
                ? "这次已补完两张牌，可以继续结合这五张牌追问。"
                : "请先完成当前塔罗牌阵的解读，再继续补牌。"
            messages.append(ChatMessage(role: .assistant, content: content, runID: base.id))
            persist(); return true
        }
        let defaultFocus = (base.input.tarotClarificationRounds ?? []).isEmpty ? "下一步的行动建议" : "行动前最值得核实的条件"
        let suggestion = focus.isEmpty ? offer ?? .init(focus: defaultFocus) : .init(focus: focus)
        let question = focus.isEmpty ? base.plan.followUpQuestion ?? base.input.question : text
        startTarotClarification(suggestion, base: base, question: question)
        return true
    }

    func canSendWhileAwaitingInteraction(_ text: String) -> Bool {
        pendingInteraction == nil || pendingInteraction?.currentRequest?.kind == .numbers
            || ReadingContinuationPolicy.explicitlyChangesScope(text, profiles: profiles)
    }

    func send(_ question: String) {
        let text = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isBusy else { return }
        guard text.count <= 6000 else { notice = "这次问题较长，请先整理到六千字以内。"; return }
        let bareTopicSwitch = text.range(of: #"^(?:先|我们|咱们)?(?:换(?:个|一个)?(?:新)?(?:问题|话题)|聊点别的|问点别的)(?:吧|好吗)?[。！!？?]*$"#, options: .regularExpression) != nil
        if bareTopicSwitch {
            let hadDraft = pendingInteraction != nil || pendingPlan != nil
            newConversation()
            messages.append(ChatMessage(role: .user, content: text))
            let prompt = hadDraft ? "上一问的进度可以从历史继续。现在想问哪件事？" : "现在想问哪件事？"
            messages.append(ChatMessage(role: .assistant, content: prompt))
            persist(); return
        }
        if (pendingInteraction != nil || pendingPlan != nil), ReadingContinuationPolicy.explicitlyChangesScope(text, profiles: profiles) {
            newConversation()
            messages.append(ChatMessage(role: .assistant, content: "上一问的操作进度已保存，可以从历史继续。", kind: .notice))
        }
        if let session = pendingInteraction, let request = session.currentRequest, request.kind == .numbers {
            messages.append(ChatMessage(role: .user, content: text))
            let parts = text.components(separatedBy: CharacterSet.decimalDigits.inverted).filter { !$0.isEmpty }
            let numbers = parts.compactMap(Int.init)
            guard text.range(of: #"[-−.．/:年月日]"#, options: .regularExpression) == nil,
                  numbers.count == 3, numbers.allSatisfy({ (1...999).contains($0) }) else {
                messages.append(ChatMessage(role: .assistant, content: "请留下三个1到999的整数，例如“12，23，6”。我会照你给出的数字继续。")); persist(); return
            }
            completeInteraction(.init(requestID: request.id, numbers: numbers), sessionID: session.id)
            return
        }
        guard pendingInteraction == nil else {
            notice = "先完成这次操作，先知便能接着为你解读。"; showInteraction = true; return
        }
        if pendingPlan == nil, let base = latestRun, base.input.tarotDraws != nil,
           handleTarotClarificationCommand(text, base: base) { return }
        if pendingPlan != nil, ConversationalIntake.isConfirmation(text) { confirmPendingIntake(); return }
        if var plan = pendingPlan, ["不对", "有问题", "需要修改", "不是", "不准确"].contains(text) {
            plan.preparationStage = .collecting; plan.reviewedParticipants = nil
            messages.append(ChatMessage(role: .user, content: text))
            prepareConversation(plan, clarification: "是哪一位的哪项信息需要更正？直接告诉我正确内容，我会重新整理给你核对。")
            return
        }
        if pendingPlan == nil, activities.last?.status == .waiting { finishActivity() }
        messages.append(ChatMessage(role: .user, content: text))
        beginActivitySession(); phase = .planning; progress("理解问题与确认询问对象")
        let id = UUID(); operationID = id; persist()
        task = Task { [weak self] in
            guard let self else { return }
            await prepareContext(operation: id)
            guard operationID == id, !Task.isCancelled else { return }
            let history = ContextCompressor.history(messages: Array(messages.dropLast()), summary: summary)
            let previousPlan = pendingPlan
            let currentRun = previousPlan == nil ? latestRun : nil
            let target = ReadingContinuationPolicy.participantIntent(in: text, profiles: profiles)
            let scope = ReadingContinuationPolicy.scopeChange(question: text, run: currentRun, profiles: profiles, selfProfileID: selfProfileID)
            let base = scope == .none ? currentRun : nil
            let changesPendingPeople = previousPlan.map { previous in
                let names = Set((previous.participantNames ?? []) + self.initialIntakeParticipants(for: previous).map(\.resolvedName))
                return !Set(target.names).isSubset(of: names) || !names.isDisjoint(with: target.excludedNames)
                    || (target.includesSelf && previous.subject == "他人")
                    || (target.isGroup && previous.subject != "多人")
            } ?? false
            let keepsPendingScope = scope == .none && !changesPendingPeople
            let scopedPending = keepsPendingScope ? previousPlan : nil
            var answer = scopedPending.map { ConversationalIntake.answer(text, plan: $0, profiles: self.profiles) } ?? IntakeAnswer()
            let pendingContextIDs = scopedPending?.requestedProfileID.map { [$0] } ?? scopedPending?.participantIDs ?? selfProfileID.map { [$0] } ?? []
            let ownFacts = ProfileDirectory.explicitSelfUpdates(in: text, profiles: profiles, selfProfileID: selfProfileID)
            let refersToSelf = target.includesSelf || ProfileDirectory.hasExplicitSelfFacts(in: text)
            let refersToOther = target.refersToOther || text.range(of: #"(?:^|[，,。；;])\s*(?:他|她)(?:的|出生|生日)"#, options: .regularExpression) != nil
            let introducesOtherPerson = ["另外", "另一个", "另一位", "其他人", "别人", "他人", "朋友", "同事", "同学", "家人", "亲戚", "对象", "伴侣", "对方", "父亲", "母亲", "爸爸", "妈妈", "孩子", "儿子", "女儿", "男友", "女友", "丈夫", "妻子", "老公", "老婆"]
                .contains(where: text.contains)
            let contextIDs: [UUID]
            if introducesOtherPerson || (refersToSelf && refersToOther) { contextIDs = [] }
            else if refersToSelf { contextIDs = selfProfileID.map { [$0] } ?? [] }
            else if refersToOther, pendingContextIDs.count == 1, pendingContextIDs.first == selfProfileID { contextIDs = [] }
            else { contextIDs = pendingContextIDs }
            if let requested = scopedPending?.requestedProfileID, !contextIDs.contains(requested),
               let person = profiles.first(where: { $0.id == requested }),
               !ProfileDirectory.referencedNames(in: text, profiles: profiles).contains(person.resolvedName) {
                answer = IntakeAnswer()
            }
            var explicitUpdates = ProfileDirectory.parseExplicitUpdates(in: text, profiles: profiles)
            explicitUpdates += ownFacts
            if text.contains("农历") || text.contains("阴历") { for index in explicitUpdates.indices { explicitUpdates[index].birthDate = nil } }
            if answer.clarification == nil { explicitUpdates += answer.updates }
            else { explicitUpdates = [] }
            if answer.clarification == nil, explicitUpdates.isEmpty, contextIDs.count == 1,
               ["出生", "生日", "性别", "时区"].contains(where: text.contains),
               let selected = profiles.first(where: { $0.id == contextIDs[0] }),
               !selected.resolvedName.isEmpty,
               !refersToSelf || selected.id == selfProfileID,
               !refersToOther || selected.id != selfProfileID,
               !introducesOtherPerson,
               !profiles.contains(where: { $0.id != selected.id && !$0.resolvedName.isEmpty && text.contains($0.resolvedName) }),
               (pendingPlan != nil || !["他", "她", "朋友"].contains(where: text.contains)) {
                explicitUpdates = ProfileDirectory.parseExplicitUpdates(in: "姓名：\(selected.resolvedName)，\(text)", profiles: profiles)
            }
            let collected = applyProfileUpdates(explicitUpdates)
            if let name = ProfileDirectory.explicitSelfName(in: text, profiles: profiles) {
                let own = ProfileDirectory.resolve(names: [name], in: profiles)
                selfProfileID = own.ids.count == 1 ? own.ids[0] : nil
                persist()
            }
            var plan = localPeoplePlan(question: text, collectedIDs: collected.appliedIDs)
            if var pending = previousPlan, pending.subject != "多人" {
                let matches = resolveSavedPeople([text]).ids
                if matches.count == 1, let person = profiles.first(where: { $0.id == matches.first }) {
                    pending.participantIDs = [person.id]; pending.participantNames = [person.participantLabel]
                    pending.draftParticipants = nil
                    prepareConversation(pending); return
                }
            }
            let clauses = text.components(separatedBy: CharacterSet(charactersIn: "，,。；;\n")).filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            let recastWithProfileUpdate = !explicitUpdates.isEmpty
                && clauses.contains(where: ReadingContinuationPolicy.isBareRecastRequest)
                && clauses.allSatisfy { ReadingContinuationPolicy.isBareRecastRequest($0)
                    || (!ProfileDirectory.parseExplicitUpdates(in: $0, profiles: self.profiles).isEmpty && !$0.contains("？") && !$0.contains("?")) }
            if previousPlan == nil, let original = base,
               ReadingContinuationPolicy.isBareRecastRequest(text) || recastWithProfileUpdate {
                // A bare recast changes the draw, not the question being asked.
                plan = OraclePlan(intent: original.plan.intent, subject: original.input.subject,
                                  methods: original.plan.methods, requiredFields: original.plan.requiredFields,
                                  note: "按原问题重新推演，请先核对这次资料。", question: original.input.question)
                plan.action = "intake"; plan.interactions = original.plan.interactions
                plan.participantIDs = original.input.readingParticipants.map(\.id)
                plan.participantNames = original.input.readingParticipants.map(\.participantLabel)
                plan.relationship = original.input.relationship
                plan.mandatoryMethods = original.plan.mandatoryMethods
                plan.collectionDeclined = original.plan.collectionDeclined
                enforceRequestedMethods(&plan, text: text)
                prepareConversation(plan); return
            }
            let methodChange = ReadingContinuationPolicy.bareMethodChange(in: text)
            let additionalMethods = methodChange.isEmpty ? ReadingContinuationPolicy.requestedAdditionalMethods(in: text) : methodChange
            let extendsExistingReading = !additionalMethods.isEmpty &&
                (!methodChange.isEmpty || ReadingContinuationPolicy.isMethodOnlyRequest(text) ||
                 !ReadingContinuationPolicy.requestedAdditionalMethods(in: text, requiresAdditiveWording: true).isEmpty)
            if let base, let draws = base.input.tarotDraws, TarotDeck.isValidInitialSpread(draws),
               base.results.contains(where: { $0.method == .tarot && ($0.status == .complete || $0.status == .partial) }),
               ReadingContinuationPolicy.isSavedTarotExplanation(text) {
                await answerFollowUp(text, history: history, operation: id, run: base)
                return
            }
            let followup = ReadingContinuationPolicy.shouldReuse(question: text, run: base, pendingPlan: previousPlan)
            // Offline fallback is conservative. Online planning can additionally
            // identify capabilities needed by a question without a method name.
            if base != nil, extendsExistingReading {
                plan.action = "supplement"; plan.methods = additionalMethods
                plan.interactions = plan.interactions?.filter { additionalMethods.contains($0.method) }
                plan.participantIDs = base?.input.readingParticipants.map(\.id)
                plan.participantNames = base?.input.readingParticipants.map(\.participantLabel)
            } else if followup, plan.action != "collect" {
                plan.action = "reply"; plan.methods = []; plan.interactions = []
            }
            let greeting = text.count < 20 && ["你好", "您好", "在吗", "你是谁", "你能做什么"].contains { text.contains($0) }
            if greeting, hasCredential, !localOnly {
                await answerFollowUp(text, history: history, operation: id, run: nil); return
            }
            progress("选择适用方法与所需资料")
            if hasCredential && !localOnly {
                do { plan = try await client.plan(question: text, profile: profile, plugins: registry.descriptors, history: history, profiles: profiles, pendingPlan: keepsPendingScope ? pendingPlan : nil, existingRun: base) }
                catch {
                    guard !Task.isCancelled else { return }
                    notice = error.localizedDescription + " 已改为本地准备问事笺。"
                }
            }
            guard operationID == id, !Task.isCancelled else { return }
            if AIPlanRouting.shouldOpenFormForProfileRequest(action: plan.action, note: plan.note, question: text, hasPendingQuestion: previousPlan != nil) {
                let updates = plan.profileUpdates
                plan = AIPlanRouting.isConcreteReadingQuestion(text) ? localPeoplePlan(question: text, collectedIDs: collected.appliedIDs) : previousPlan ?? plan
                plan.action = "intake"; plan.profileUpdates = updates
            }
            var grounded = answer.clarification == nil ? ProfileDirectory.groundedUpdates(plan.profileUpdates ?? [], in: text, profiles: profiles,
                                                           contextIDs: contextIDs) : []
            if text.contains("农历") || text.contains("阴历") { for index in grounded.indices { grounded[index].birthDate = nil } }
            let extracted = applyProfileUpdates(grounded)
            let changedIDs = Array(Set(collected.appliedIDs + extracted.appliedIDs))
            let requestsReading = changesPendingPeople || !additionalMethods.isEmpty
                || (scope == .explicit && !methodsMentioned(in: text, positiveRequestsOnly: true).isEmpty)
            if !keepsPendingScope, plan.action != "collect", plan.action != "clarify",
               plan.action != "reply" || requestsReading {
                let local = localPeoplePlan(question: text, collectedIDs: changedIDs)
                if plan.action == "reply" || plan.action == "supplement" { plan = local }
                plan.action = "intake"; plan.question = text
                plan.baseRunID = nil; plan.followUpQuestion = nil; plan.resumesPendingQuestion = false
                if target.refersToOther, target.names.isEmpty, !target.includesSelf {
                    plan.participantIDs = nil
                    plan.participantNames = plan.participantNames?.filter { text.contains($0) }
                }
            }
            resolveParticipants(in: &plan, question: text)
            if base != nil, extendsExistingReading { plan.action = "supplement" }
            else if let base, ReadingContinuationPolicy.explicitlyRequestsNewReading(text) {
                // Explicit fresh draws/questions take precedence over a model's
                // supplement suggestion, including requests with a new subject.
                plan.action = "intake"; plan.baseRunID = nil; plan.followUpQuestion = nil; plan.question = text
                if base.plan.methods == [.tarot], methodsMentioned(in: text, positiveRequestsOnly: true).isEmpty {
                    plan.methods = [.tarot]; plan.requiredFields = []; plan.interactions = []; plan.mandatoryMethods = nil
                } else if plan.methods.isEmpty { plan.methods = registry.localPlan(question: text, profile: profile).methods }
            }
            if previousPlan != nil || plan.action == nil || plan.action == "intake" || plan.action == "supplement" {
                enforceRequestedMethods(&plan, text: text)
            }
            if let base, previousPlan == nil, plan.action != "collect", plan.action != "clarify",
               plan.action == "supplement" || (followup && plan.action == "reply") {
                if plan.action == "supplement", !additionalMethods.isEmpty {
                    plan.methods = Array(Set(plan.methods + additionalMethods))
                }
                let onlyExplain = additionalMethods.isEmpty && text.range(of: #"(?:不要|不用|无需|不必|别).{0,5}(?:重算|重新|补算|再算)|只解释|(?:沿用|解释)原"#, options: .regularExpression) != nil
                if onlyExplain { await answerFollowUp(text, history: history, operation: id, run: base); return }
                if prepareSupplement(plan, base: base, question: text) { return }
                await answerFollowUp(text, history: history, operation: id, run: base, tarotOffer: plan.action == "reply" ? plan.tarotClarification : nil)
                return
            }
            if !(plan.mandatoryMethods ?? []).isEmpty, plan.action == "clarify" { plan.action = "intake" }
            let asksNewQuestion = ["？", "?", "看看", "如何", "怎样", "算卦", "问卦"].contains(where: text.contains)
            if keepsPendingScope, let previous = previousPlan, !asksNewQuestion, !methodsMentioned(in: text).isEmpty,
               (!(plan.mandatoryMethods ?? []).isEmpty && Set(plan.mandatoryMethods ?? []) != Set(previous.mandatoryMethods ?? [])) ||
                (["换成", "改用", "改成", "换用", "改为", "改按"].contains(where: text.contains) && Set(plan.methods) != Set(previous.methods)) {
                plan.question = previous.question
                if target.names.isEmpty, !target.includesSelf, !target.refersToOther {
                    plan.participantIDs = previous.participantIDs; plan.participantNames = previous.participantNames
                    plan.draftParticipants = pendingPlan?.draftParticipants
                }
                if plan.methods.contains(.meihua) { plan.draftNumbers = previous.draftNumbers }
                plan.subject = previous.subject; plan.relationship = plan.relationship ?? previous.relationship
                plan.action = "intake"
                prepareConversation(plan)
                return
            }
            if keepsPendingScope, var previous = previousPlan,
               plan.resumesPendingQuestion == true || (!asksNewQuestion && (!changedIDs.isEmpty || !answer.updates.isEmpty || answer.clarification != nil || answer.declinedName || !(previous.requestedFields ?? []).isEmpty || ConversationalIntake.isUnknown(text) || ConversationalIntake.isConfirmation(text))) {
                if previous.requestedFields?.contains(.name) == true, !changedIDs.isEmpty {
                    var ids = previous.participantIDs ?? []
                    for id in changedIDs where !ids.contains(id) { ids.append(id) }
                    previous.participantIDs = ids
                    previous.participantNames = ids.compactMap { id in self.profiles.first(where: { $0.id == id })?.resolvedName }
                    if previous.subject == "本人", ids.count == 1, selfProfileID == nil { selfProfileID = ids[0] }
                } else if plan.resumesPendingQuestion == true, let ids = plan.participantIDs, !ids.isEmpty {
                    previous.participantIDs = ids; previous.participantNames = plan.participantNames
                }
                if answer.declinedName { previous.collectionDeclined = true }
                if answer.clarification == nil { previous.pendingAnswer = nil }
                prepareConversation(previous, clarification: answer.clarification, pendingAnswer: answer.pendingAnswer)
                return
            }
            if plan.action == "collect" {
                if plan.resumesPendingQuestion == true, var pending = pendingPlan {
                    pending.participantIDs = plan.participantIDs ?? pending.participantIDs
                    pending.participantNames = pending.participantIDs?.compactMap { id in self.profiles.first(where: { $0.id == id })?.resolvedName }
                    pending.relationship = plan.relationship ?? pending.relationship
                    pendingPlan = pending
                }
                let names = changedIDs.compactMap { id in self.profiles.first(where: { $0.id == id })?.resolvedName }.sorted()
                let issues = collected.issues + extracted.issues
                let note: String
                if !issues.isEmpty { note = issues.map(\.message).joined(separator: "\n") }
                else if names.isEmpty { note = "请写下需要留存或补充的姓名和已知资料；未明确的内容先保留原样。" }
                else { note = "已分别记下\(names.joined(separator: "、"))的资料。问卦时会自动带入，不需要重复填写已知信息。" }
                messages.append(ChatMessage(role: .assistant, content: note))
                activityMessageID = messages.last?.id
                progress(names.isEmpty ? "等待明确人员资料" : "资料已按姓名分别留存", state: names.isEmpty ? .waiting : .completed)
                phase = waitingPhase; operationID = nil; showIntake = false; persist(); return
            }
            if !changedIDs.isEmpty {
                let names = changedIDs.compactMap { id in self.profiles.first(where: { $0.id == id })?.resolvedName }.sorted()
                messages.append(ChatMessage(role: .assistant, content: "已按姓名更新留存资料：\(names.joined(separator: "、"))。", kind: .notice))
            }
            if plan.action == "reply" {
                await answerFollowUp(text, history: history, operation: id, run: base, tarotOffer: plan.tarotClarification); return
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
            prepareConversation(plan)
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

    @discardableResult func confirmIntake(profile submittedProfile: OracleProfile, numbers: [Int], save: Bool) -> Bool {
        confirmGroupIntake(profiles: [submittedProfile], numbers: numbers, save: save)
    }
    @discardableResult func confirmGroupIntake(profiles submittedProfiles: [OracleProfile], numbers submittedNumbers: [Int], save: Bool,
                                               sessionID: UUID? = nil, useLocalFallback: Bool = false) -> Bool {
        guard var plan = pendingPlan, !isBusy,
              sessionID == nil || sessionID == intakeSessionID else { return false }
        if discardMissingSupplement() { persist(); return false }
        var seen = Set<UUID>()
        let participants = submittedProfiles.filter { seen.insert($0.id).inserted }
            .map(ProfileDirectory.assigningDefaultBirthTimeZone(to:))
        plan.draftParticipants = participants; plan.draftNumbers = submittedNumbers
        pendingPlan = plan
        if useLocalFallback {
            let original = ReadingPreparationPolicy.evaluate(plan: plan, participants: participants, descriptors: registry.descriptors)
            guard original.blockedMandatoryMethods.contains(where: \.usesPersonalProfile), registry.plugin(.xiaoliuren) != nil else { return false }
            plan.methods = [.xiaoliuren]; plan.mandatoryMethods = [.xiaoliuren]
            plan.requiredFields = []; plan.interactions = []
        }
        let numbers = useLocalFallback ? [] : submittedNumbers
        var issues: [String] = []
        if plan.subject == "多人", participants.count < 2 { issues.append("请至少添加两位参与人。每位的资料都可以留空。") }
        let report = ReadingPreparationPolicy.evaluate(plan: plan, participants: participants, descriptors: registry.descriptors)
        if !report.canProceed {
            for assessment in report.assessments {
                let owner = assessment.participantName.map { $0 + "：" } ?? ""
                issues += assessment.blocking.map { owner + assessment.method.progressName + "需要" + $0.field.title + "：" + $0.reason }
                if let reason = assessment.unavailableReason { issues.append(reason) }
            }
            if issues.isEmpty { issues.append("现有资料还不足以按这次要求推演，请补充标明的必要信息。") }
        }
        let requiresNumbers = OracleInteractionPolicy.requests(for: plan).contains { $0.kind == .numbers }
        if (requiresNumbers || !numbers.isEmpty), numbers.count != 3 || !numbers.allSatisfy({ (1...999).contains($0) }) {
            issues.append("请在同一张资料表中选择三个1到999的整数。")
        }
        if !issues.isEmpty {
            var seenIssues = Set<String>()
            intakeError = issues.filter { seenIssues.insert($0).inserted }.joined(separator: "\n")
            notice = intakeError; showIntake = true; phase = .awaitingIntake; persist(); return false
        }
        intakeError = nil; notice = nil
        plan.participantIDs = participants.map(\.id)
        plan.participantNames = participants.map(\.participantLabel)
        if participants.count > 1 { plan.subject = "多人" }
        let runnable = Set(report.runnableMethods)
        var included = Set<OracleMethod>()
        plan.methods = (plan.methods + report.runnableMethods).filter { runnable.contains($0) && included.insert($0).inserted }
        plan.omittedMethods = report.omissions
        plan.preparationNotes = preparationNotes(report)
        plan.reviewedParticipants = participants; plan.preparationStage = .confirming
        plan.draftParticipants = nil; plan.draftNumbers = nil
        if save { for person in participants { saveProfile(person) } }
        messages.append(ChatMessage(role: .user, content: "已核对问事资料，开始推演。"))
        let style = ["蓍草", "大衍"].contains { plan.question.contains($0) } ? "yarrow" : "coins"
        var input: OracleInput
        if let baseID = plan.baseRunID, let base = runs.first(where: { $0.id == baseID }) {
            input = supplementInput(base: base, plan: plan, participants: participants, numbers: numbers)
        } else {
            input = OracleInput(question: plan.question, profile: participants.first ?? OracleProfile(), numbers: numbers,
                                subject: plan.subject, castingStyle: style, participants: participants, relationship: plan.relationship)
            if !numbers.isEmpty { input.profile.unknownFields.remove(.numbers) }
        }
        launchPreparedReading(input: input, plan: plan)
        return true
    }

    func saveInteractionProgress(_ response: OracleInteractionResponse, sessionID: UUID) {
        guard var session = pendingInteraction, session.id == sessionID, !isBusy,
              session.saveProgress(response) else { return }
        pendingInteraction = session; persist()
    }

    func cancelTarotClarification(sessionID: UUID) {
        guard let session = pendingInteraction, session.id == sessionID, !isBusy,
              session.currentRequest?.tarotClarification != nil, (session.draft?.revealedCount ?? 0) == 0 else { return }
        pendingInteraction = nil; showInteraction = false; phase = waitingPhase
        if let index = messages.lastIndex(where: { $0.id == activityMessageID }) {
            messages[index].kind = .notice
            messages[index].content = "这轮补牌已取消，你可以继续问原来的牌阵。"
        }
        progress("已取消本轮补牌", state: .cancelled)
        persist()
    }

    func completeInteraction(_ response: OracleInteractionResponse, sessionID: UUID) {
        if discardMissingSupplement() { persist(); return }
        guard let pending = pendingInteraction, pending.id == sessionID, !isBusy else { return }
        let isClarification = pending.currentRequest?.tarotClarification != nil
        var session = pending
        guard session.complete(response) else { return }
        if isClarification, pending.draft != response {
            saveInteractionProgress(response, sessionID: sessionID)
        }
        pendingInteraction = session
        if session.currentRequest == nil {
            pendingInteraction = nil; showInteraction = false
            startReading(input: session.input, plan: session.plan, isTarotClarification: isClarification)
        } else { presentRequestedInteraction() }
    }

    private func presentRequestedInteraction() {
        guard pendingInteraction?.currentRequest != nil else { return }
        progress(interactionStatus, state: .waiting)
        showInteraction = true
        persist()
    }

    private func startReading(input: OracleInput, plan: OraclePlan, isTarotClarification: Bool = false) {
        guard plan.baseRunID == nil || runs.contains(where: { $0.id == plan.baseRunID }) else {
            notice = "原推演记录已删除，无法继续这次补充推演。"; phase = waitingPhase; operationID = nil
            progress("补充推演已取消", state: .cancelled); persist(); return
        }
        let base = plan.baseRunID.flatMap { id in runs.first { $0.id == id } }
        let reused = isTarotClarification ? (base?.results ?? []).filter { $0.method != .tarot }
            : reusableResults(input: input, plan: plan)
        let run = OracleRun(input: input, plan: plan, results: reused, weightsSnapshot: weights,
                            reusedResultIDs: plan.baseRunID == nil ? nil : reused.map(\.id))
        activityRunID = run.id
        runs.append(run); showIntake = false; pendingPlan = nil; phase = .calculating
        if let index = messages.lastIndex(where: { $0.kind == .intake && $0.runID == nil && $0.deletedRunID == nil }) {
            messages[index].runID = run.id
            if isTarotClarification { messages[index].content = "补牌已保存，正在结合全部牌面解读。" }
            else { messages[index].content = plan.baseRunID == nil ? "问事笺已收好。稍坐，我替你理一理。" : "已有结果继续沿用，只补充新增或条件变化的部分。" }
        }
        if !reused.isEmpty {
            progress("沿用已完成的推演结果", detail: reused.map { $0.displayTitle }.joined(separator: "、"), state: .completed)
        }
        progress("核对资料与已确认的选择")
        let operation = UUID(); operationID = operation; persist()
        let conversationID = activeConversationID
        task = Task { [weak self] in
            guard let self else { return }
            let results = await registry.calculate(input, methods: isTarotClarification ? [.tarot] : plan.methods,
                omissions: isTarotClarification ? [] : plan.omittedMethods ?? [], onParticipantStart: { [weak self] method, person, index, total in
                await self?.beginMethod(method, person: person, index: index, total: total, runID: run.id, operation: operation, conversationID: conversationID)
            }, reusedResults: isTarotClarification ? [] : reused, onProgress: { [weak self] result in
                await self?.receive(result, for: run.id, operation: operation)
            })
            guard operationID == operation, !Task.isCancelled else { return }
            if let index = runs.firstIndex(where: { $0.id == run.id }) { runs[index].results = isTarotClarification ? reused + results : results }
            await synthesize(runID: run.id, operation: operation)
        }
    }
    private func beginMethod(_ method: OracleMethod, person: OracleProfile?, index: Int, total: Int, runID: UUID, operation: UUID, conversationID: UUID) {
        guard operationID == operation, activeConversationID == conversationID,
              runs.contains(where: { $0.id == runID }), !Task.isCancelled else { return }
        let name = person?.participantLabel ?? ""
        progress("正在推演\(name.isEmpty ? "" : name + "的")\(method.progressName)", detail: "第 \(index) 项，共 \(total) 项推演", method: method)
    }
    private func receive(_ result: OracleResult, for runID: UUID, operation: UUID) {
        guard operationID == operation, let index = runs.firstIndex(where: { $0.id == runID }) else { return }
        runs[index].results.append(result)
        finishActivity(status: result.status == .failed ? .failed : .completed)
        let detail = result.status == .unavailable ? "资料不足，此项不参与解读。" : "\(result.rows.count) 项盘面数据 · \(result.evidence.count) 条规则线索"
        progress("整理\(result.participantName.map { $0 + "的" } ?? "")\(result.method.progressName)结果", detail: detail, method: result.method,
                 state: result.status == .failed ? .failed : .completed)
        persist()
    }
    func retrySynthesis(_ run: OracleRun) {
        guard !isBusy, runs.contains(where: { $0.id == run.id }) else { return }
        guard pendingInteraction == nil else { notice = "请先完成当前选择，再继续解读。"; return }
        beginActivitySession(); activityRunID = run.id
        progress("沿用已保存的推演结果", detail: run.results.map { $0.method.progressName }.joined(separator: "、"), state: .completed)
        phase = .synthesizing
        let operation = UUID(); operationID = operation
        task = Task { [weak self] in await self?.synthesize(runID: run.id, operation: operation) }
    }
    private func synthesize(runID: UUID, operation: UUID) async {
        guard operationID == operation, !Task.isCancelled,
              var run = runs.first(where: { $0.id == runID }) else { return }
        if run.plan.tarotClarification != nil, !(run.input.tarotClarificationRounds ?? []).isEmpty,
           !run.results.contains(where: { $0.method == .tarot && $0.status == .complete }) {
            // The draw is already committed. Rebuild its local result if the
            // process previously stopped between saving the draw and the result.
            let results = await registry.calculate(run.input, methods: [.tarot], onProgress: { _ in })
            guard operationID == operation, !Task.isCancelled,
                  let index = runs.firstIndex(where: { $0.id == runID }) else { return }
            runs[index].results.removeAll { $0.method == .tarot }
            runs[index].results += results
            run = runs[index]
            persist()
        }
        phase = .synthesizing
        let messageID = UUID()
        messages.append(ChatMessage(id: messageID, role: .assistant, content: "", kind: .reading, runID: runID))
        activityMessageID = messageID
        let transcript = messages.dropLast()
        let history: [AIConversationTurn]
        if run.plan.baseRunID == nil, let boundary = transcript.lastIndex(where: {
            $0.deletedRunID != nil || ($0.runID != nil && $0.runID != runID)
        }) {
            // A new reading has its own people and inputs. Its synthesis should
            // see the new question and confirmations, without older readings.
            history = ContextCompressor.history(messages: Array(transcript.suffix(from: transcript.index(after: boundary))), summary: .init())
        } else {
            history = ContextCompressor.history(messages: Array(transcript), summary: summary)
        }
        progress("准备解读已保存的结果")
        persist()
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
        if let notes = run.plan.preparationNotes, !notes.isEmpty {
            let missing = notes.filter { !synthesis.text.contains($0) }
            if !missing.isEmpty { synthesis.text += "\n\n资料说明：" + missing.joined(separator: "\n") }
        }
        if let index = messages.firstIndex(where: { $0.id == messageID }) {
            messages[index].content = synthesis.text
            if latestRun?.id == runID, ReadingContextBuilder.canSuggestTarotClarification(for: run),
               let offer = synthesis.tarotClarification, offer.isValid {
                messages[index].tarotClarificationOffer = offer
            }
        }
        if let index = runs.firstIndex(where: { $0.id == runID }) { runs[index].synthesis = synthesis; runs[index].completedAt = Date() }
        progress("解读已完成", state: .completed)
        phase = waitingPhase; operationID = nil; persist()
    }
    private func readingProgress(_ stage: AIReadingProgress, runID: UUID, operation: UUID) {
        guard operationID == operation, let run = runs.first(where: { $0.id == runID }), !Task.isCancelled else { return }
        var seen = Set<OracleMethod>()
        let methods = run.results.filter { ($0.status == .complete || $0.status == .partial) && seen.insert($0.method).inserted }.map { $0.method.progressName }
        switch stage {
        case .preparing: progress("汇集各项推演结果", detail: methods.joined(separator: "、"))
        case .requesting:
            let people = run.input.readingParticipants.map(\.participantLabel)
            if people.count > 1 {
                progress("综合解析\(people.prefix(3).joined(separator: "、"))的关系", detail: methods.joined(separator: "、"))
                return
            }
            let names = methods.prefix(2).joined(separator: "、") + (methods.count > 2 ? "等" : "")
            progress(methods.count == 1 ? "正在解读\(names)结果" : "综合解析\(names)结果",
                     detail: "结合问题、已保存结果与资料限制生成解读。")
        case .writing: progress("正在整理中文解读")
        case .validating: progress("核对解读与分歧选项")
        }
    }
    private func localReading(_ run: OracleRun, reason: String) -> ReadingSynthesis {
        let eligible = run.results.filter { $0.status == .complete || $0.status == .partial }
        if let round = run.input.tarotClarificationRounds?.last,
           let tarot = eligible.first(where: { $0.method == .tarot }) {
            let statements = tarot.evidence.map(\.statement).joined(separator: "\n\n")
            let focus = "本轮补牌 · \(round.request.focus)"
            return ReadingSynthesis(text: [reason, focus, tarot.headline, statements].filter { !$0.isEmpty }.joined(separator: "\n\n"), alternatives: [])
        }
        let statements = eligible.flatMap(\.evidence).map(\.statement)
        var seen = Set<String>()
        let unique = statements.filter { seen.insert($0).inserted }
        let body = unique.isEmpty ? "现有资料还不足以给出完整判断。点这条回复下方的「翻看数据」可以查看现有结果。" : String(unique.prefix(5).joined(separator: "\n\n").prefix(900))
        let uncertainty = eligible.contains { !$0.limitations.isEmpty } ? "\n\n有些资料或规则仍有限制，未确定的部分先留白。" : ""
        return ReadingSynthesis(text: reason + "\n\n" + body + uncertainty, alternatives: [])
    }
    private func answerFollowUp(_ question: String, history: [AIConversationTurn], operation: UUID,
                                run: OracleRun?, tarotOffer: TarotClarificationSuggestion? = nil) async {
        phase = .synthesizing; progress(run == nil ? "结合已确认资料生成回答" : "沿用已有卦象，解答追问")
        let messageID = UUID()
        messages.append(ChatMessage(id: messageID, role: .assistant, content: "", runID: run?.id))
        activityMessageID = messageID
        persist()
        if !hasCredential || localOnly {
            let reason = "沿用这次已保存的卦象，以下是本地规则摘要。" + (localOnly ? "详细追问需要开启 AI 解读。" : "设置解读密钥后可以继续细说。")
            let text = run.map { localReading($0, reason: reason).text } ?? "说说你想看的具体事情，我可以为你准备本地推演。"
            if let index = messages.firstIndex(where: { $0.id == messageID }) { messages[index].content = text }
            progress(run == nil ? "等待具体问题" : "已有结果已保留", state: .completed)
            phase = waitingPhase; operationID = nil; persist(); return
        }
        do {
            let text = try await client.followUp(question: question, run: run, profile: profile, history: history) { [weak self] delta in
                Task { @MainActor [weak self] in
                    guard let self, self.operationID == operation, let index = self.messages.firstIndex(where: { $0.id == messageID }) else { return }
                    if self.activities.last?.text != "正在整理补充回答" { self.progress("正在整理补充回答") }
                    self.messages[index].content += delta
                }
            }
            guard operationID == operation else { return }
            if let index = messages.firstIndex(where: { $0.id == messageID }) {
                messages[index].content = text
                let declines = question.range(of: #"(?:不要|不用|无需|不必|别|不想).{0,6}(?:补抽|加抽|追加|补牌|补一张|抽牌|再抽)"#, options: .regularExpression) != nil
                if let run, ReadingContextBuilder.canSuggestTarotClarification(for: run), !declines, let tarotOffer, tarotOffer.isValid {
                    messages[index].tarotClarificationOffer = tarotOffer
                }
            }
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
        exposeInterruptedTarotReading()
        persist()
    }

    #if DEBUG
    private func seedReadingLibraryPreview() {
        guard !vault.contains("reading-library-fixture") else { return }
        let people = ProfileDirectory.applying([ProfileUpdate(name: "陈平", birthDate: "1992-06-15", birthTime: "08:30", birthTimeZoneID: "Asia/Shanghai")], to: []).profiles
        profiles = people
        runs = (1...10).map { index in
            let question = "推演删除测试\(index)"
            let input = OracleInput(question: question, profile: people[0], castingDate: Date(timeIntervalSince1970: 1_700_000_000 + Double(index) * 60), participants: people)
            let plan = OraclePlan(intent: "删除记录验收", subject: "事件", methods: [.xiaoliuren], requiredFields: [], note: "", question: question)
            var run = OracleRun(input: input, plan: plan, results: [OracleResult(method: .xiaoliuren, headline: "本地测试记录\(index)", rows: [.init("测试编号", "\(index)")])])
            run.synthesis = ReadingSynthesis(text: "第\(index)份测试解读。", alternatives: [])
            run.completedAt = input.castingDate
            return run
        }
        messages = runs.flatMap { run in
            [ChatMessage(role: .user, content: run.input.question), ChatMessage(role: .assistant, content: run.synthesis!.text, kind: .reading, runID: run.id)]
        }
        try? vault.save(true, as: "reading-library-fixture")
        persist()
    }

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

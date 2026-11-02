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
        self.vault = vault
        let history = ConversationHistory.load(from: vault)
        conversations = history.archive.conversations
        activeConversationID = history.archive.activeConversationID
        let active = history.archive.conversations.first { $0.id == history.archive.activeConversationID }
        let originalProfiles = vault.load([OracleProfile].self, from: "profiles", fallback: [])
        let storedProfiles = originalProfiles.filter {
            !$0.resolvedName.isEmpty || $0.birthDate != nil || !$0.birthPlace.isEmpty
        }
        profiles = storedProfiles
        if vault.contains("self-profile-id") {
            selfProfileID = vault.load(UUID?.self, from: "self-profile-id", fallback: nil)
        } else {
            // Prior releases explicitly treated the first legacy record as self.
            // Named records created by the new directory never acquire this role.
            let originalSelf = originalProfiles.first
            selfProfileID = originalSelf?.name == nil && storedProfiles.contains(where: { $0.id == originalSelf?.id }) ? originalSelf?.id : nil
        }
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
        if let plan = pendingPlan { prepareConversation(plan, appendMessage: false) }
        else { restoreActivities() }
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--ui-testing-local") && ProcessInfo.processInfo.arguments.contains("--ui-testing-reading-library") {
            seedReadingLibraryPreview()
        }
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
        var copy = value; copy.updatedAt = Date()
        guard !copy.resolvedName.isEmpty else { notice = "请先填写姓名，再保存这份资料。"; return }
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
        func detach(_ transcript: inout [ChatMessage]) {
            for index in transcript.indices where transcript[index].runID == id {
                transcript[index].runID = nil; transcript[index].deletedRunID = id
            }
        }
        detach(&messages)
        for index in conversations.indices { detach(&conversations[index].messages) }
        persist()
    }
    func defaultParticipants(for plan: OraclePlan) -> [OracleProfile] {
        if let ids = plan.participantIDs, !ids.isEmpty {
            var seen = Set<UUID>()
            return ids.compactMap { id in seen.insert(id).inserted ? profiles.first(where: { $0.id == id }) : nil }
        }
        if let names = plan.participantNames, !names.isEmpty {
            let resolution = ProfileDirectory.resolve(names: names, in: profiles)
            return resolution.ids.compactMap { id in profiles.first(where: { $0.id == id }) }
        }
        if plan.subject == "本人", let selfProfileID, let own = profiles.first(where: { $0.id == selfProfileID }) { return [own] }
        return []
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
        let names = ProfileDirectory.referencedNames(in: question, profiles: profiles)
        let resolved = ProfileDirectory.resolve(names: names, in: profiles)
        if !names.isEmpty { plan.participantNames = names; plan.participantIDs = resolved.ids }
        if Set(names).count > 1 || ["我们", "两人", "双方", "合婚"].contains(where: question.contains) {
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
        let groundedNames = ProfileDirectory.referencedNames(in: question, profiles: profiles)
        if !groundedNames.isEmpty {
            plan.participantNames = groundedNames
            let match = ProfileDirectory.resolve(names: groundedNames, in: profiles)
            let selected = Set(pendingPlan?.participantIDs ?? [])
            plan.participantIDs = match.ids + match.issues.flatMap { issue in
                issue.candidateIDs.filter { selected.contains($0) }
            }
        }
        let hasExplicitIDs = !(plan.participantIDs ?? []).isEmpty
        var seenNames = Set<String>()
        let requestedNames = (plan.participantNames ?? []).filter { seenNames.insert($0).inserted }
        let newNames = requestedNames.filter { name in
            !name.isEmpty && !["我", "本人", "他人", "朋友", "对象"].contains(name) && question.contains(name)
                && !profiles.contains(where: { $0.resolvedName == name })
        }
        if !newNames.isEmpty { _ = applyProfileUpdates(newNames.map { ProfileUpdate(name: $0) }) }
        let validIDs = Set(profiles.map(\.id))
        if let ids = plan.participantIDs {
            var seen = Set<UUID>()
            plan.participantIDs = ids.filter { id in
                guard validIDs.contains(id), seen.insert(id).inserted, let person = profiles.first(where: { $0.id == id }) else { return false }
                let sameName = profiles.filter { $0.resolvedName == person.resolvedName }
                return sameName.count <= 1 || pendingPlan?.participantIDs?.contains(id) == true
            }
        }
        if !requestedNames.isEmpty {
            let match = ProfileDirectory.resolve(names: requestedNames, in: profiles)
            if !match.issues.isEmpty { notice = match.issues.map(\.message).joined(separator: "\n") }
            if !hasExplicitIDs { plan.participantIDs = match.ids }
        } else if (plan.participantIDs ?? []).isEmpty, plan.subject == "本人", let selfProfileID {
            plan.participantIDs = [selfProfileID]
        }
        if let ids = plan.participantIDs, !ids.isEmpty {
            plan.participantNames = ids.compactMap { id in profiles.first(where: { $0.id == id })?.resolvedName }
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
        clearConversationPresentation()
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

    var intakeParticipants: [OracleProfile] {
        guard let plan = pendingPlan else { return [] }
        return initialIntakeParticipants(for: plan)
    }
    var intakeNumbers: [Int] { pendingPlan?.draftNumbers ?? [] }

    func intakePreparationReport(for participants: [OracleProfile]) -> ReadingPreparationReport? {
        guard let plan = pendingPlan else { return nil }
        return ReadingPreparationPolicy.evaluate(plan: plan, participants: participants, descriptors: registry.descriptors)
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
        pendingPlan = plan; intakeSessionID = UUID(); intakeError = nil
        if appendMessage || !messages.contains(where: { $0.kind == .intake && $0.runID == nil && $0.deletedRunID == nil }) {
            messages.append(ChatMessage(role: .assistant, content: "请在问事资料中一次填写并核对这次信息。确认后直接开始；需要抽牌或投掷时，再接着完成操作。", kind: .intake))
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
        let candidates = profiles.filter { !$0.resolvedName.isEmpty }
        return candidates.count == 1 ? candidates : []
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

    private func methodsMentioned(in text: String) -> [OracleMethod] {
        let aliases: [(OracleMethod, [String])] = [(.bazi, ["八字", "四柱"]), (.ziwei, ["紫微", "紫薇"]), (.liuyao, ["六爻"]), (.meihua, ["梅花"]), (.qimen, ["奇门"]), (.xiaoliuren, ["小六壬"]), (.chenggu, ["称骨"]), (.xingming, ["姓名五格", "五格"]), (.astrology, ["占星", "星盘"]), (.tarot, ["塔罗", "塔羅", "tarot"])]
        return aliases.filter { $0.1.contains { text.localizedCaseInsensitiveContains($0) } }.map(\.0)
    }

    private func enforceRequestedMethods(_ plan: inout OraclePlan, text: String) {
        let named = methodsMentioned(in: text)
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

    func send(_ question: String) {
        let text = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isBusy else { return }
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
        guard text.count <= 6000 else { notice = "这次问题较长，请先整理到六千字以内。"; return }
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
            var answer = previousPlan.map { ConversationalIntake.answer(text, plan: $0, profiles: self.profiles) } ?? IntakeAnswer()
            let pendingContextIDs = previousPlan?.requestedProfileID.map { [$0] } ?? pendingPlan?.participantIDs ?? selfProfileID.map { [$0] } ?? []
            let refersToSelf = ["我", "本人"].contains(where: text.contains)
            let refersToOther = ["他", "她"].contains(where: text.contains)
            let introducesOtherPerson = ["另外", "另一个", "另一位", "其他人", "别人", "他人", "朋友", "同事", "同学", "家人", "亲戚", "对象", "伴侣", "对方", "父亲", "母亲", "爸爸", "妈妈", "孩子", "儿子", "女儿", "男友", "女友", "丈夫", "妻子", "老公", "老婆"]
                .contains(where: text.contains)
            let contextIDs: [UUID]
            if introducesOtherPerson || (refersToSelf && refersToOther) { contextIDs = [] }
            else if refersToSelf { contextIDs = selfProfileID.map { [$0] } ?? [] }
            else if refersToOther, pendingContextIDs.count == 1, pendingContextIDs.first == selfProfileID { contextIDs = [] }
            else { contextIDs = pendingContextIDs }
            if let requested = previousPlan?.requestedProfileID, !contextIDs.contains(requested),
               let person = profiles.first(where: { $0.id == requested }),
               !ProfileDirectory.referencedNames(in: text, profiles: profiles).contains(person.resolvedName) {
                answer = IntakeAnswer()
            }
            var explicitUpdates = ProfileDirectory.parseExplicitUpdates(in: text, profiles: profiles)
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
            if var pending = previousPlan, pending.subject != "多人",
               let person = profiles.first(where: { $0.resolvedName == text }),
               ProfileDirectory.resolve(names: [text], in: profiles).ids == [person.id] {
                pending.participantIDs = [person.id]; pending.participantNames = [person.resolvedName]
                pending.draftParticipants = nil
                prepareConversation(pending); return
            }
            let clauses = text.components(separatedBy: CharacterSet(charactersIn: "，,。；;\n")).filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            let recastWithProfileUpdate = !explicitUpdates.isEmpty
                && clauses.contains(where: ReadingContinuationPolicy.isBareRecastRequest)
                && clauses.allSatisfy { ReadingContinuationPolicy.isBareRecastRequest($0)
                    || (!ProfileDirectory.parseExplicitUpdates(in: $0, profiles: self.profiles).isEmpty && !$0.contains("？") && !$0.contains("?")) }
            if previousPlan == nil, let original = latestRun,
               ReadingContinuationPolicy.isBareRecastRequest(text) || recastWithProfileUpdate {
                // A bare recast changes the draw, not the question being asked.
                plan = OraclePlan(intent: original.plan.intent, subject: original.input.subject,
                                  methods: original.plan.methods, requiredFields: original.plan.requiredFields,
                                  note: "按原问题重新推演，请先核对这次资料。", question: original.input.question)
                plan.action = "intake"; plan.interactions = original.plan.interactions
                plan.participantIDs = original.input.readingParticipants.map(\.id)
                plan.participantNames = original.input.readingParticipants.map(\.resolvedName)
                plan.relationship = original.input.relationship
                plan.mandatoryMethods = original.plan.mandatoryMethods
                plan.collectionDeclined = original.plan.collectionDeclined
                enforceRequestedMethods(&plan, text: text)
                prepareConversation(plan); return
            }
            // Continue from the saved chart by default, before asking the planner
            // to choose methods. A detail question must not create fresh casts.
            let followup = ReadingContinuationPolicy.shouldReuse(question: text, run: latestRun, pendingPlan: previousPlan)
            if followup, plan.action != "collect" {
                if !collected.appliedIDs.isEmpty {
                    messages.append(ChatMessage(role: .assistant, content: "资料已更新；这次追问仍沿用原推演保存的资料与结果。需要按新资料重算时，直接告诉我。", kind: .notice))
                }
                await answerFollowUp(text, history: history, operation: id); return
            }
            let greeting = text.count < 20 && ["你好", "您好", "在吗", "你是谁", "你能做什么"].contains { text.contains($0) }
            if greeting, hasCredential, !localOnly {
                await answerFollowUp(text, history: history, operation: id); return
            }
            progress("选择适用方法与所需资料")
            if hasCredential && !localOnly && !followup {
                do { plan = try await client.plan(question: text, profile: profile, plugins: registry.descriptors, history: history, profiles: profiles, pendingPlan: pendingPlan) }
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
            resolveParticipants(in: &plan, question: text)
            enforceRequestedMethods(&plan, text: text)
            if !(plan.mandatoryMethods ?? []).isEmpty, plan.action == "clarify" { plan.action = "intake" }
            let asksNewQuestion = ["？", "?", "看看", "如何", "怎样", "算卦", "问卦"].contains(where: text.contains)
            if let previous = previousPlan, !asksNewQuestion, !methodsMentioned(in: text).isEmpty,
               (!(plan.mandatoryMethods ?? []).isEmpty && Set(plan.mandatoryMethods ?? []) != Set(previous.mandatoryMethods ?? [])) ||
                (["换成", "改用", "改成", "换用", "改为", "改按"].contains(where: text.contains) && Set(plan.methods) != Set(previous.methods)) {
                plan.question = previous.question
                if (plan.participantIDs ?? []).isEmpty { plan.participantIDs = previous.participantIDs; plan.participantNames = previous.participantNames }
                plan.subject = previous.subject; plan.relationship = plan.relationship ?? previous.relationship
                plan.action = "intake"
                prepareConversation(plan)
                return
            }
            if var previous = previousPlan,
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
    @discardableResult func confirmGroupIntake(profiles submittedProfiles: [OracleProfile], numbers: [Int], save: Bool, sessionID: UUID? = nil) -> Bool {
        guard var plan = pendingPlan, !isBusy,
              sessionID == nil || sessionID == intakeSessionID else { return false }
        var seen = Set<UUID>()
        let participants = submittedProfiles.filter { seen.insert($0.id).inserted }
        plan.draftParticipants = participants; plan.draftNumbers = numbers
        pendingPlan = plan
        var issues: [String] = []
        if plan.subject == "多人", participants.count < 2 { issues.append("请补充至少两人的资料，再一起看。") }
        if plan.methods.contains(where: \.usesPersonalProfile), participants.isEmpty { issues.append("请选择或新增这次问事对应的人员资料。") }
        if participants.contains(where: { $0.resolvedName.isEmpty }) { issues.append("请填写每位参与人的姓名。") }
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
        plan.participantNames = participants.map(\.resolvedName)
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
        let input = OracleInput(question: plan.question, profile: participants.first ?? OracleProfile(), numbers: numbers,
                                subject: plan.subject, castingStyle: style, participants: participants, relationship: plan.relationship)
        let requests = OracleInteractionPolicy.requests(for: plan, numbers: numbers)
        if !requests.isEmpty {
            pendingInteraction = OracleInteractionSession(input: input, plan: plan, requests: requests)
            pendingPlan = nil; showIntake = false; phase = .awaitingInteraction; operationID = nil
            presentRequestedInteraction(); return true
        }
        startReading(input: input, plan: plan)
        return true
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
        } else { presentRequestedInteraction() }
    }

    private func presentRequestedInteraction() {
        guard pendingInteraction?.currentRequest != nil else { return }
        progress(interactionStatus, state: .waiting)
        showInteraction = true
        persist()
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
            let results = await registry.calculate(input, methods: plan.methods, omissions: plan.omittedMethods ?? [], onParticipantStart: { [weak self] method, person, index, total in
                await self?.beginMethod(method, person: person, index: index, total: total, runID: run.id, operation: operation, conversationID: conversationID)
            }, onProgress: { [weak self] result in
                await self?.receive(result, for: run.id, operation: operation)
            })
            guard operationID == operation, !Task.isCancelled else { return }
            if let index = runs.firstIndex(where: { $0.id == run.id }) { runs[index].results = results }
            await synthesize(runID: run.id, operation: operation)
        }
    }
    private func beginMethod(_ method: OracleMethod, person: OracleProfile?, index: Int, total: Int, runID: UUID, operation: UUID, conversationID: UUID) {
        guard operationID == operation, activeConversationID == conversationID,
              runs.contains(where: { $0.id == runID }), !Task.isCancelled else { return }
        let name = person?.resolvedName ?? ""
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
        if let notes = run.plan.preparationNotes, !notes.isEmpty {
            let missing = notes.filter { !synthesis.text.contains($0) }
            if !missing.isEmpty { synthesis.text += "\n\n资料说明：" + missing.joined(separator: "\n") }
        }
        if let index = messages.firstIndex(where: { $0.id == messageID }) { messages[index].content = synthesis.text }
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
            let people = run.input.readingParticipants.map(\.resolvedName).filter { !$0.isEmpty }
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
        let statements = eligible.flatMap(\.evidence).map(\.statement)
        var seen = Set<String>()
        let unique = statements.filter { seen.insert($0).inserted }
        let body = unique.isEmpty ? "现有资料还不足以给出完整判断。你可以在数据簿查看已完成的部分，并补充不确定的资料。" : String(unique.prefix(5).joined(separator: "\n\n").prefix(900))
        let uncertainty = eligible.contains { !$0.limitations.isEmpty } ? "\n\n有些资料或规则仍有限制，未确定的部分先留白。" : ""
        return ReadingSynthesis(text: reason + "\n\n" + body + uncertainty, alternatives: [])
    }
    private func answerFollowUp(_ question: String, history: [AIConversationTurn], operation: UUID) async {
        let run = latestRun
        phase = .synthesizing; progress(run == nil ? "结合已确认资料生成回答" : "沿用已有卦象，解答追问")
        let messageID = UUID()
        messages.append(ChatMessage(id: messageID, role: .assistant, content: "", runID: run?.id))
        activityMessageID = messageID
        if let run, !hasCredential || localOnly {
            let reason = "沿用这次已保存的卦象，以下是本地规则摘要；" + (localOnly ? "详细追问需要开启 DeepSeek 解读。" : "设置解读密钥后可以继续细说。")
            if let index = messages.firstIndex(where: { $0.id == messageID }) { messages[index].content = localReading(run, reason: reason).text }
            progress("已有结果已保留", state: .completed)
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

import Foundation
import Combine

enum OraclePhase: String {
    case idle, planning, awaitingIntake, awaitingInteraction, calculating, synthesizing
    var isBusy: Bool { self == .planning || self == .calculating || self == .synthesizing }
}

/// A reading's place is independent of any participant's birth/current details.
/// Copy only the casting fields when projecting it onto legacy OracleInput.
struct CastingLocationDraft: Equatable, Sendable {
    var profile: OracleProfile

    init(profile source: OracleProfile) {
        profile = Self.applying(source, to: OracleProfile(id: source.id))
    }

    static func applying(_ source: OracleProfile, to target: OracleProfile) -> OracleProfile {
        var result = target
        let previousUnknown = target.unknownFields
        result.currentPlace = source.currentPlace
        result.currentLatitude = source.currentLatitude
        result.currentLongitude = source.currentLongitude
        result.currentTimeZoneID = source.currentTimeZoneID
        result.currentDistrictCode = source.currentDistrictCode
        result.unknownFields.remove(.currentLocation)
        if source.unknownFields.contains(.currentLocation) { result.unknownFields.insert(.currentLocation) }
        if target.declaredUnknownFields != nil || source.declaredUnknownFields != nil {
            var declared = target.declaredUnknownFields ?? previousUnknown
            declared.remove(.currentLocation)
            if source.declaredUnknownFields?.contains(.currentLocation) == true { declared.insert(.currentLocation) }
            result.declaredUnknownFields = declared
        }
        return result
    }

    mutating func select(_ district: ChinaDistrict) {
        profile.currentPlace = district.fullName
        profile.currentDistrictCode = district.id
        profile.currentLatitude = district.latitude
        profile.currentLongitude = district.longitude
        profile.currentTimeZoneID = district.timeZone
        profile.unknownFields.remove(.currentLocation)
        profile.declaredUnknownFields?.remove(.currentLocation)
    }

    mutating func clear() {
        profile.currentPlace = ""
        profile.currentDistrictCode = nil
        profile.currentLatitude = nil
        profile.currentLongitude = nil
        profile.currentTimeZoneID = OracleProfile.defaultChinaTimeZoneID
        profile.unknownFields.insert(.currentLocation)
        var declared = profile.declaredUnknownFields ?? []
        declared.insert(.currentLocation)
        profile.declaredUnknownFields = declared
    }
}

@MainActor final class OracleStore: ObservableObject {
    @Published var profiles: [OracleProfile]
    @Published var selfProfileID: UUID?
    @Published var messages: [ChatMessage]
    @Published var runs: [OracleRun]
    @Published var summary: ConversationSummary
    @Published var conversations: [OracleConversation]
    @Published var activeConversationID: UUID
    @Published private(set) var historyResetID = UUID()
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
    @Published private(set) var requiresTopUp = false
    @Published private(set) var hasCredential = false
    @Published private(set) var credentialIssue: String?
    @Published var selectedTab = 0
    let registry = PluginRegistry()
    private lazy var deepSeekClient = DeepSeekClient()
    private let aiClient: DeepSeekClient?
    private let quotaEndService: AIQuotaTaskService?
    var client: DeepSeekClient { aiClient ?? deepSeekClient }
    private let vault: LocalVault
    private let castingDefaults: UserDefaults
    private var task: Task<Void, Never>?
    private var operationID: UUID?
    @Published private(set) var quotaTaskID: UUID?
    private var quotaEndIntents: [String: String] = [:]
    private var activityRunID: UUID?
    @Published private var analysisAttempt: OracleAnalysisAttempt?
    var isBusy: Bool { phase.isBusy }
    var canRetryAnalysis: Bool {
        guard !isBusy, pendingInteraction == nil, let attempt = analysisAttempt else { return false }
        if let runID = attempt.runID, !runs.contains(where: { $0.id == runID }) { return false }
        return true
    }
    func canRetryAnalysis(for messageID: UUID) -> Bool {
        guard canRetryAnalysis, let attempt = analysisAttempt else { return false }
        if attempt.messageID == messageID { return true }
        return attempt.runID.map { runID in messages.contains { $0.id == messageID && $0.runID == runID } } ?? false
    }
    private var waitingPhase: OraclePhase { pendingInteraction != nil ? .awaitingInteraction : pendingPlan != nil ? .awaitingIntake : .idle }
    var profile: OracleProfile { profiles.first(where: { $0.id == selfProfileID }) ?? OracleProfile() }
    var latestRun: OracleRun? {
        guard let reference = messages.last(where: { $0.runID != nil || $0.deletedRunID != nil }),
              reference.deletedRunID == nil, let id = reference.runID else { return nil }
        return runs.first { $0.id == id }
    }
    private var activeReplyRun: OracleRun? {
        guard let reply = messages.last(where: \.isConversationTurn), reply.role == .assistant,
              reply.deletedRunID == nil, let runID = reply.runID else { return nil }
        return runs.first { $0.id == runID }
    }
    var pendingIntakeMessageID: UUID? { pendingPlan == nil ? nil : messages.last(where: { $0.kind == .intake && $0.runID == nil })?.id }
    // Deterministic test doubles are compiled out of the distributed app.
    // No persisted preference can switch production away from the online Agent.
    #if DEBUG
    private let usesTestAgent: Bool
    #else
    private let usesTestAgent = false
    #endif

    init(vault: LocalVault = .shared, bootstrapCredential: Bool = true, aiClient: DeepSeekClient? = nil,
         quotaEndService: AIQuotaTaskService? = nil, castingDefaults: UserDefaults = .standard) {
        DeepSeekConfiguration.migrateDefault()
        #if DEBUG
        usesTestAgent = aiClient == nil && (!bootstrapCredential || ProcessInfo.processInfo.arguments.contains("--ui-testing-local"))
        #endif
        self.vault = vault
        self.castingDefaults = castingDefaults
        quotaEndIntents = vault.load([String: String].self, from: ServiceEnvironment.current.endIntentsFilename, fallback: [:])
        self.aiClient = aiClient
        self.quotaEndService = quotaEndService
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
        try? vault.removeRetiredInterpretationPreferences()
        summary = active?.summary ?? ConversationSummary()
        pendingPlan = active?.pendingPlan
        pendingInteraction = active?.pendingInteraction
        analysisAttempt = active?.analysisAttempt
        quotaTaskID = active?.quotaTaskID ?? active?.pendingPlan?.quotaTaskID ?? active?.pendingInteraction?.plan.quotaTaskID
        phase = waitingPhase
        let recoveredClarification = recoverCommittedClarification()
        let discardedSupplement = discardMissingSupplement()
        if history.needsInitialSave {
            do { try vault.save(history.archive, as: ConversationHistory.filename) }
            catch { notice = L10n.text("历史对话暂未写入磁盘，请检查设备可用空间。", "Chat history could not be saved. Check your available storage.") }
        }
        if history.recoveredUnreadableFile {
            notice = history.recoveryCopyPreserved
                ? L10n.text("历史对话有部分内容无法读取，已尽可能恢复可用对话并保留原文件副本。", "Some chat history could not be read. The available chats were recovered and a copy of the original file was kept.")
                : L10n.text("历史对话有部分内容无法读取，原文件暂时无法备份，已阻止覆盖，请检查设备可用空间。", "Some chat history could not be read. The original file was preserved because it could not be backed up. Check your available storage.")
        }
        if aiClient != nil { hasCredential = true }
        else if bootstrapCredential { refreshCredential() }
        if let plan = pendingPlan, analysisAttempt == nil { prepareConversation(plan, appendMessage: false) }
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

    func refreshCredential(importBundledKey: Bool = true) {
        if aiClient != nil { return }
        #if DEBUG
        if usesTestAgent { hasCredential = true; return }
        #endif
        Task { [weak self] in
            let session = await AccountSessionManager.shared.snapshot()
            self?.hasCredential = session != nil
            self?.credentialIssue = nil
        }
    }

    /// Save the latest streamed text before the app can be suspended. The live
    /// task continues; only a later process restart marks its work interrupted.
    func checkpoint() { persist() }
    @discardableResult private func persist() -> Bool {
        syncActivities()
        captureCurrentConversation()
        do {
            try vault.save(profiles, as: "profiles")
            try vault.save(selfProfileID, as: "self-profile-id")
            try vault.save(runs, as: "readings")
            let history = OracleConversationArchive(activeConversationID: activeConversationID, conversations: conversations)
            try vault.save(history, as: ConversationHistory.filename)
            // Keep the previous single-chat files as a compatibility snapshot;
            // the versioned history remains authoritative after migration.
            try vault.save(messages, as: "conversation")
            try vault.save(summary, as: "context")
            try vault.save(pendingPlan, as: "pending-intake")
            // Completion intents are written after the answer/history snapshots, before any server end request.
            try vault.save(quotaEndIntents, as: ServiceEnvironment.current.endIntentsFilename)
            return true
        } catch { notice = L10n.text("本次资料暂未写入磁盘，请检查设备可用空间。", "Could not save these details. Check your available storage."); return false }
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
                messages[index].content = L10n.text("这份推演记录已删除。", "This reading has been deleted.")
            }
            activityRunID = nil; activityMessageID = nil
            activities = []; status = ""; activitySessionID = UUID()
            phase = waitingPhase
        }
        runs.removeAll { $0.id == id }
        if analysisAttempt?.runID == id { analysisAttempt = nil }
        _ = discardMissingSupplement()
        func detach(_ transcript: inout [ChatMessage]) {
            for index in transcript.indices where transcript[index].runID == id {
                transcript[index].runID = nil; transcript[index].deletedRunID = id
            }
        }
        detach(&messages)
        for index in conversations.indices {
            detach(&conversations[index].messages)
            if conversations[index].analysisAttempt?.runID == id { conversations[index].analysisAttempt = nil }
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
                result.issues.append(.init(kind: .ambiguousName, name: label, message: L10n.text("有多位人员使用称呼\(label)，请从档案中选取。", "Several people go by \(label). Choose a profile."),
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
        let asks = AIPlanRouting.isConcreteReadingQuestion(question) || ["？", "?", "看看", "算卦", "问卦", "如何", "怎样", "适合", "关系", "友情", "姻缘", "婚姻", "合作", "运势", "建议", "合不合", "感情"]
            .contains(where: question.contains)
        let deferReading = ["不要算", "先不算", "暂不算", "不需要解读"].contains(where: question.contains)
            || EnglishConversation.matches(question, #"\b(?:no reading yet|do not read|don['’]t calculate|just save)\b"#)
        if statement && (!asks || deferReading) {
            plan.action = "collect"; plan.methods = []; plan.requiredFields = []; plan.interactions = []
            let names = collectedIDs.compactMap { id in profiles.first(where: { $0.id == id })?.resolvedName }
            plan.note = names.isEmpty ? (notice ?? L10n.text("请明确需要补充哪位的资料。", "Whose details would you like to add?")) : L10n.text("已分别记下\(names.joined(separator: "、"))的资料。可以继续补充，或告诉我这次想问的事。", "I saved the details for \(names.joined(separator: ", ")). You can add more or tell me what you would like to ask.")
            return plan
        }
        let target = ReadingContinuationPolicy.participantIntent(in: question, profiles: profiles)
        if target.isGroup {
            plan.subject = "多人"
            let relationships = [("友情", "Friendship"), ("姻缘", "Romance"), ("婚姻", "Marriage"), ("合作", "Collaboration"), ("恋爱", "Relationship"), ("家庭", "Family")]
            let relationship = relationships.first { question.contains($0.0) || question.localizedCaseInsensitiveContains($0.1) }
            plan.relationship = L10n.text(relationship?.0 ?? "关系", relationship?.1 ?? "Relationship")
            if !plan.methods.contains(.tarot) && !plan.methods.contains(where: \.usesPersonalProfile) {
                plan.methods += [.bazi, .ziwei, .astrology]
                plan.requiredFields = Array(Set(plan.methods.flatMap { registry.plugin($0)?.descriptor.requiredFields ?? [] }))
            }
        }
        return plan
    }
    func resolveParticipants(in plan: inout OraclePlan, question: String, allowPersistentCreation: Bool? = nil) {
        let mayCreate = allowPersistentCreation ?? ProfileFactPolicy.allowsPersistence(in: question)
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
        if mayCreate, !newNames.isEmpty { _ = applyProfileUpdates(newNames.map { ProfileUpdate(name: $0) }) }
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
    func newConversation() {
        cancelConversationTask()
        captureCurrentConversation()
        if !messages.isEmpty || pendingPlan != nil || pendingInteraction != nil || !summary.text.isEmpty { activeConversationID = UUID() }
        messages = []; summary = ConversationSummary(); pendingPlan = nil; pendingInteraction = nil; analysisAttempt = nil; quotaTaskID = nil
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
        analysisAttempt = target.analysisAttempt
        quotaTaskID = target.quotaTaskID ?? target.pendingPlan?.quotaTaskID ?? target.pendingInteraction?.plan.quotaTaskID
        recoverCommittedClarification()
        clearConversationPresentation()
        _ = discardMissingSupplement()
        if let plan = pendingPlan, analysisAttempt == nil { prepareConversation(plan, appendMessage: false) }
        selectedTab = 0
        persist()
    }
    func deleteConversation(_ id: UUID) {
        guard conversations.contains(where: { $0.id == id }) else { return }
        let linkedRuns = Set(conversations.first(where: { $0.id == id })?.messages.compactMap(\.runID) ?? [])
        for index in runs.indices where linkedRuns.contains(runs[index].id) && runs[index].completedAt == nil { runs[index].plan.quotaTaskID = nil }
        if !usesTestAgent { Task { try? await AIQuotaTaskService.shared.eraseConversation(id) } }
        if id == activeConversationID {
            // Invalidate callbacks before removing the record. Do not capture
            // the deleted transcript again during the following persist.
            cancelConversationTask()
            conversations.removeAll { $0.id == id }
            activeConversationID = UUID()
            messages = []; summary = ConversationSummary(); pendingPlan = nil; pendingInteraction = nil; analysisAttempt = nil; quotaTaskID = nil
            clearConversationPresentation()
        } else { conversations.removeAll { $0.id == id } }
        persist()
    }
    func clearConversationHistory() {
        // Invalidate every async callback before dropping the active transcript.
        task?.cancel(); task = nil; operationID = nil
        for index in runs.indices where runs[index].completedAt == nil { runs[index].plan.quotaTaskID = nil }
        if !usesTestAgent { Task { try? await AIQuotaTaskService.shared.eraseConversation(nil) } }
        conversations = []; messages = []; summary = ConversationSummary()
        pendingPlan = nil; pendingInteraction = nil; analysisAttempt = nil; quotaTaskID = nil
        activeConversationID = UUID()
        clearConversationPresentation()
        historyResetID = UUID()
        persist()
        do { try vault.removeLegacyConversationArchives() }
        catch { notice = L10n.text("历史已清空，部分旧备份暂未移除，请稍后重试。", "History was cleared, but some older backups could not be removed. Try again later.") }
    }

    /// Called only after the server has confirmed account deletion. Signing
    /// out never calls this operation. Invalidate callbacks before the first
    /// suspension so a late streamed answer cannot restore erased content.
    func eraseLocalDataAfterAccountDeletion() async throws {
        task?.cancel(); task = nil; operationID = nil
        profiles = []; selfProfileID = nil; runs = []
        conversations = []; messages = []; summary = ConversationSummary()
        pendingPlan = nil; pendingInteraction = nil; analysisAttempt = nil; quotaTaskID = nil
        quotaEndIntents = [:]; activeConversationID = UUID()
        clearConversationPresentation(); phase = .idle
        requiresTopUp = false; hasCredential = false; credentialIssue = nil; selectedTab = 0
        historyResetID = UUID()
        // Write the durable lock before touching files; on a protected-file
        // failure, LocalVault refuses both old reads and stale callback writes.
        try vault.markAccountDeletionPending()
        if let quotaEndService { try await quotaEndService.eraseDataForDeletedAccount() }
        else if !usesTestAgent { try await AIQuotaTaskService.shared.eraseDataForDeletedAccount() }
        try vault.eraseDataForDeletedAccount()
    }

    func cancelPendingReading() {
        guard pendingPlan != nil || pendingInteraction != nil else { return }
        if let id = quotaTaskID ?? pendingPlan?.quotaTaskID ?? pendingInteraction?.plan.quotaTaskID { quotaEndIntents[id.uuidString.lowercased()] = "cancelled" }
        quotaTaskID = nil
        task?.cancel(); task = nil; operationID = nil
        pendingPlan = nil; pendingInteraction = nil; analysisAttempt = nil
        showIntake = false; showInteraction = false; intakeError = nil; notice = nil
        intakeSessionID = UUID()
        finishActivity(status: .cancelled)
        progress(L10n.text("本次操作已取消", "This reading was canceled"), state: .cancelled)
        messages.append(ChatMessage(role: .assistant,
            content: L10n.text("已取消这次未完成的操作。可以继续聊，也可以重新开始。", "The unfinished reading was canceled. You can keep chatting or start another reading."), kind: .notice))
        phase = .idle
        activityMessageID = nil; activityRunID = nil
        if persist(), !usesTestAgent { Task { await flushQuotaEnds() } }
    }
    private func captureCurrentConversation() {
        let previous = conversations.first { $0.id == activeConversationID }
        let snapshot = OracleConversation(id: activeConversationID, messages: messages, summary: summary,
                                          pendingPlan: pendingPlan, pendingInteraction: pendingInteraction,
                                          createdAt: previous?.createdAt, analysisAttempt: analysisAttempt, quotaTaskID: quotaTaskID)
        conversations.removeAll { $0.id == activeConversationID }
        if !snapshot.isEmpty { conversations.append(snapshot) }
        conversations = ConversationHistory.ordered(conversations)
    }
    private func cancelConversationTask() {
        if isBusy { interruptAnalysis(backgroundExpired: false) }
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
        notice = L10n.text("原推演记录已删除，这次未完成的补充推演已取消；请重新提出问题。", "The original reading was deleted, so the unfinished follow-up was canceled. Ask your question again to start a new reading.")
        progress(L10n.text("补充推演已取消", "Follow-up reading canceled"), detail: L10n.text("原推演记录已删除。", "The original reading was deleted."), state: .cancelled)
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
            messages[index].content = L10n.text("补牌已保存，可以继续结合完整牌阵解读。", "The clarifying card is saved. You can continue with the full spread.")
        }
        return true
    }
    private func beginActivitySession() {
        requiresTopUp = false
        if quotaTaskID == nil { quotaTaskID = UUID() }
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
        let attemptMessage = analysisAttempt?.messageID.flatMap { id in messages.first { $0.id == id } }
        let attemptRun = analysisAttempt?.runID.flatMap { id in runs.first { $0.id == id } }
        let historicalMessage = analysisAttempt == nil ? messages.last(where: {
            !($0.activities ?? []).isEmpty && (!awaitingUser || ($0.kind == .intake && $0.runID == nil))
        }) : nil
        if let message = attemptMessage ?? historicalMessage {
            activityMessageID = message.id
            activityRunID = message.kind == .reading || message.kind == .intake ? message.runID : nil
            activities = message.activities ?? []; activitySessionID = message.id
            if activities.last?.status == .running { finishActivity(status: .cancelled); interrupted = true }
            status = activities.last?.text ?? ""
        } else if let run = attemptRun ?? (analysisAttempt == nil && !awaitingUser ? latestRun : nil),
                  let saved = run.activities, !saved.isEmpty {
            activities = saved; activityRunID = run.id; activitySessionID = run.id
            activityMessageID = messages.last(where: { $0.runID == run.id && $0.kind == .reading })?.id
            if activities.last?.status == .running { finishActivity(status: .cancelled); interrupted = true }
            status = activities.last?.text ?? ""
        }
        if !interrupted, let attempt = analysisAttempt, attempt.runID != nil, activities.last?.status == .completed {
            // A calculation can be saved between two local methods.
            progress(L10n.text("上次处理已中断", "The last request was interrupted"), state: .cancelled)
            interrupted = true
        }
        if interrupted {
            if analysisAttempt == nil, let index = messages.firstIndex(where: { $0.id == activityMessageID }) {
                let message = messages[index]
                if let runID = message.runID, message.kind == .reading || message.kind == .intake {
                    analysisAttempt = .reading(runID: runID, messageID: message.id, needsCalculation: message.kind == .intake)
                } else if message.kind == .text, message.role == .assistant,
                          let question = messages[..<index].last(where: { $0.role == .user }) {
                    analysisAttempt = .followUp(questionID: question.id, replyID: message.id, runID: message.runID, tarotOffer: nil)
                }
            }
            if let id = activityMessageID, let index = messages.firstIndex(where: { $0.id == id }),
               messages[index].role == .assistant, messages[index].content.isEmpty {
                messages[index].content = L10n.text("上次回答中断，已保存的资料与结果仍保留。", "The last answer was interrupted. Your saved details and results are still available.")
            }
            notice = notice ?? L10n.text("上次处理已中断，已保存的资料、部分回答与推演结果仍保留。", "The last request was interrupted. Your saved details, partial answer, and reading results are still available.")
        }
        if !awaitingUser, exposeInterruptedTarotReading() { interrupted = true }
        if awaitingUser, analysisAttempt == nil {
            activityRunID = nil
            activityMessageID = messages.last(where: { $0.kind == .intake && $0.runID == nil })?.id
            progress(pendingInteraction != nil ? interactionStatus : L10n.text("等待你确认问事资料", "Waiting for you to review the reading details"), state: .waiting)
        }
        return interrupted
    }

    @discardableResult private func exposeInterruptedTarotReading() -> Bool {
        guard let run = latestRun, run.plan.tarotClarification != nil, run.synthesis == nil,
              !messages.contains(where: { $0.runID == run.id && $0.kind == .reading }),
              let index = messages.lastIndex(where: { $0.runID == run.id && $0.kind == .intake }) else { return false }
        messages[index].kind = .reading
        messages[index].content = L10n.text("补牌已保存，可以继续结合完整牌阵解读。", "The clarifying card is saved. You can continue with the full spread.")
        return true
    }
    private var interactionStatus: String {
        if pendingInteraction?.currentRequest?.tarotClarification != nil { return L10n.text("等待你选择并翻开一张补牌", "Waiting for you to choose and reveal a clarifying card") }
        return switch pendingInteraction?.currentRequest?.kind {
        case .tarot: L10n.text("等待你选牌并翻开", "Waiting for you to choose and reveal the cards")
        case .numbers: pendingInteraction?.currentRequest?.requiredNumberCount == 2
            ? L10n.text("等待你留下两个数字", "Waiting for your two numbers")
            : L10n.text("等待你留下三个数字", "Waiting for your three numbers")
        case .coins: L10n.text("等待你依次留下六爻", "Waiting for you to cast the six lines")
        case nil: L10n.text("等待你确认选择", "Waiting for your confirmation")
        }
    }

    var intakeParticipants: [OracleProfile] {
        guard let plan = pendingPlan else { return [] }
        return initialIntakeParticipants(for: plan).map(ProfileDirectory.assigningDefaultBirthTimeZone(to:))
    }
    var intakeNumbers: [Int] { pendingPlan?.draftNumbers ?? [] }
    var intakeCastingProfile: OracleProfile? {
        guard let plan = pendingPlan else { return nil }
        return castingProfileSnapshot(for: plan)
    }

    func intakePreparationReport(for participants: [OracleProfile]) -> ReadingPreparationReport? {
        guard let plan = pendingPlan else { return nil }
        return ReadingPreparationPolicy.evaluate(plan: plan, participants: participants.map(ProfileDirectory.assigningDefaultBirthTimeZone(to:)),
                                                 descriptors: registry.descriptors, castingProfile: castingProfileSnapshot(for: plan), numbers: plan.draftNumbers)
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

    func saveIntakeDraft(profiles: [OracleProfile], numbers: [Int], castingProfile: OracleProfile? = nil, sessionID: UUID) {
        guard sessionID == intakeSessionID, var plan = pendingPlan, !isBusy else { return }
        initializeCastingProfile(in: &plan)
        plan.draftParticipants = profiles
        plan.draftNumbers = numbers
        if let castingProfile { plan.castingProfile = CastingLocationDraft(profile: castingProfile).profile }
        pendingPlan = plan
        persist()
    }

    private func initializeCastingProfile(in plan: inout OraclePlan) {
        guard plan.castingProfile == nil else { return }
        plan.castingProfile = castingProfileSnapshot(for: plan)
    }

    private func castingProfileSnapshot(for plan: OraclePlan) -> OracleProfile {
        if let casting = plan.castingProfile { return casting }
        // A new question must acquire its own current place. A saved person's
        // old location is not evidence of where this casting takes place.
        // Supplements keep the original casting snapshot and physical instant.
        let source = plan.baseRunID.flatMap { id in runs.first(where: { $0.id == id })?.input.profile } ?? OracleProfile(id: intakeSessionID)
        return CastingLocationDraft(profile: source).profile
    }

    /// The local method page owns these choices. Model output cannot replace
    /// them; an existing question keeps the settings it was started with.
    private func captureCastingPreferences(in plan: inout OraclePlan, inheriting previous: OraclePlan? = nil,
                                           base: OracleRun? = nil) {
        if plan.methods.contains(.meihua) {
            if let base, base.plan.methods.contains(.meihua) || base.results.contains(where: { $0.method == .meihua }) {
                let unknown = base.input.profile.unknownFields.union(base.input.profile.declaredUnknownFields ?? [])
                let count = unknown.contains(.numbers) ? 0 : base.input.numbers.count
                plan.meihuaCastingMode = base.plan.meihuaCastingMode
                    ?? (count >= 3 ? .threeNumbers : count == 2 ? .twoNumbers : .time)
            } else if let previous, previous.methods.contains(.meihua) {
                plan.meihuaCastingMode = previous.meihuaCastingMode
            } else {
                plan.meihuaCastingMode = CastingMethodPreferences.meihua(in: castingDefaults)
            }
            if let mode = plan.meihuaCastingMode {
                plan.interactions?.removeAll { $0.method == .meihua }
                plan.requiredFields.removeAll { $0 == .numbers }
                if mode == .time { plan.draftNumbers = nil }
                else { plan.requiredFields.append(.numbers) }
            }
        } else { plan.meihuaCastingMode = nil }
        if plan.methods.contains(.liuyao) {
            if let base, base.plan.methods.contains(.liuyao) || base.results.contains(where: { $0.method == .liuyao }) {
                plan.liuyaoCastingMode = base.plan.liuyaoCastingMode
                    ?? LiuyaoCastingMode(rawValue: base.input.castingStyle?.lowercased() ?? "")
            } else if let previous, previous.methods.contains(.liuyao) {
                plan.liuyaoCastingMode = previous.liuyaoCastingMode
            } else {
                plan.liuyaoCastingMode = CastingMethodPreferences.liuyao(in: castingDefaults)
            }
            if plan.liuyaoCastingMode != nil { plan.interactions?.removeAll { $0.method == .liuyao } }
        } else { plan.liuyaoCastingMode = nil }
    }

    private func castingNumbers(for plan: OraclePlan, supplied: [Int]) -> [Int] {
        plan.methods.contains(.meihua) && plan.meihuaCastingMode == .time ? [] : supplied
    }

    private func prepareConversation(_ proposed: OraclePlan, clarification: String? = nil, pendingAnswer: String? = nil, appendMessage: Bool = true) {
        var plan = proposed
        // Narrowing a mixed proposal must not promote an optional place into
        // a hard requirement. Meihua's time/two-number location requirement is
        // evaluated separately from the confirmed numbers by the local policy.
        let requiresPlace = registry.descriptors.contains {
            plan.methods.contains($0.method) && $0.requiredFields.contains(.currentLocation)
        }
        if !requiresPlace { plan.requiredFields.removeAll { $0 == .currentLocation } }
        initializeCastingProfile(in: &plan)
        plan.quotaTaskID = quotaTaskID ?? proposed.quotaTaskID ?? UUID()
        quotaTaskID = plan.quotaTaskID
        // Legacy field-by-field preparations reopen as one complete form.
        plan.preparationStage = .collecting
        plan.requestedProfileID = nil; plan.requestedFields = nil
        plan.reviewedParticipants = nil; plan.pendingAnswer = nil
        let people = initialIntakeParticipants(for: plan)
        let report = ReadingPreparationPolicy.evaluate(plan: plan, participants: people, descriptors: registry.descriptors,
                                                       castingProfile: plan.castingProfile, numbers: plan.draftNumbers)
        plan.omittedMethods = report.omissions; plan.preparationNotes = preparationNotes(report)
        if appendMessage, pendingPlan != nil, let old = pendingIntakeMessageID,
           let index = messages.firstIndex(where: { $0.id == old }) {
            messages[index].kind = .notice
            messages[index].content = L10n.text("这张问事笺已替换，请使用最新的问事笺。", "This form was replaced. Use the latest one.")
        }
        pendingPlan = plan; intakeSessionID = UUID(); intakeError = nil
        if appendMessage || !messages.contains(where: { $0.kind == .intake && $0.runID == nil && $0.deletedRunID == nil }) {
            let message = clarification ?? L10n.text("请在问事资料中填写并核对信息。确认后开始推演，需要抽牌或投掷时会进入下一步。", "Enter and review the reading details. Once you confirm, the reading starts or opens the next step if you need to draw cards or cast.")
            messages.append(ChatMessage(role: .assistant, content: message, kind: .intake))
        }
        activityMessageID = messages.last(where: { $0.kind == .intake && $0.runID == nil })?.id
        progress(L10n.text("等待填写并确认问事资料", "Waiting for you to complete and confirm the reading details"), state: .waiting)
        showIntake = true; showInteraction = false
        finishOperation()
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
            L10n.text("本次未采用\(omission.participantName.map { $0 + "的" } ?? "")\(omission.method.progressName)参考：\(omission.reason.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters)))。补齐资料后可以再看。", "\(omission.method.progressName)\(omission.participantName.map { " for " + $0 } ?? "") was skipped. \(omission.reason) You can revisit it after adding the details.")
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
        input.question = plan.question; input.subject = plan.subject
        input.participants = participants; input.relationship = plan.relationship
        if let updated = participants.first(where: { $0.id == base.input.profile.id }) { input.profile = updated }
        input.profile = CastingLocationDraft.applying(plan.castingProfile ?? base.input.profile, to: input.profile)
        input.numbers = castingNumbers(for: plan, supplied: numbers)
        if plan.methods.contains(.meihua), !base.plan.methods.contains(.meihua),
           !base.results.contains(where: { $0.method == .meihua }) {
            input.interactionResponses?.removeAll { $0.requestID == OracleMethod.meihua.rawValue }
        }
        if let style = plan.liuyaoCastingMode { input.castingStyle = style.rawValue }
        if plan.methods.contains(.liuyao), !base.plan.methods.contains(.liuyao),
           !base.results.contains(where: { $0.method == .liuyao }) {
            input.manualLines = []
            input.interactionResponses?.removeAll { $0.requestID == OracleMethod.liuyao.rawValue }
        }
        if numbers == base.input.numbers {
            if base.input.profile.unknownFields.contains(.numbers) { input.profile.unknownFields.insert(.numbers) }
            else { input.profile.unknownFields.remove(.numbers) }
        } else if [2, 3].contains(input.numbers.count), input.numbers.allSatisfy({ (1...999).contains($0) }) { input.profile.unknownFields.remove(.numbers) }
        return input
    }

    /// Returns false when every requested calculation is still valid; the caller
    /// then answers from the existing run without creating another record.
    private func prepareSupplement(_ proposed: OraclePlan, base: OracleRun, question: String) -> Bool {
        guard runs.contains(where: { $0.id == base.id }) else {
            progress(L10n.text("补充推演已取消", "Follow-up reading canceled"), detail: L10n.text("原推演记录已删除。", "The original reading was deleted."), state: .cancelled)
            notice = L10n.text("原推演记录已删除，无法继续这次补充推演。", "The original reading was deleted, so this follow-up cannot continue.")
            finishOperation()
            return true
        }
        var plan = proposed
        plan.baseRunID = base.id; plan.followUpQuestion = question; plan.question = base.input.question
        // A newly proposed supplement inherits the original question's place.
        // Only edits on its subsequent confirmation form replace that snapshot.
        plan.castingProfile = CastingLocationDraft(profile: base.input.profile).profile
        plan.action = "supplement"; plan.subject = base.input.subject
        plan.relationship = proposed.relationship ?? base.input.relationship
        let available = base.results.filter { $0.status == .complete || $0.status == .partial }.map(\.method)
        let requested = ReadingContinuationPolicy.requestedCalculationMethods(in: question)
        let selectsOnlyMethods = !requested.isEmpty && (
            question.range(of: #"(?:只|仅)(?:要|用|看|算|按|采用)"#, options: .regularExpression) != nil
                || EnglishConversation.matches(question, #"\b(?:only|just)\b"#))
        let methods = Set(selectsOnlyMethods ? requested : available + proposed.methods)
        plan.methods = OracleMethod.allCases.filter { methods.contains($0) }
        if selectsOnlyMethods {
            plan.mandatoryMethods = plan.methods
            plan.question = questionUpdatingMethods(base.input.question, from: base.plan.methods, to: plan.methods)
        }
        plan.requiredFields = Array(Set(proposed.requiredFields + registry.descriptors.filter { methods.contains($0.method) }.flatMap(\.requiredFields)))
        captureCastingPreferences(in: &plan, base: base)
        retainConfirmedTwoNumberMode(in: &plan, base: base, numbers: base.input.numbers)
        let originals = base.input.readingParticipants
        let selectedIDs = (proposed.participantIDs ?? []).isEmpty ? originals.map(\.id) : proposed.participantIDs ?? []
        var people = selectedIDs.compactMap { id -> OracleProfile? in
            guard let original = originals.first(where: { $0.id == id }) else { return profiles.first { $0.id == id } }
            guard let saved = profiles.first(where: { $0.id == id }) else { return original }
            return saved.updatedAt >= original.updatedAt ? saved : ProfileDirectory.restoringKnownFields(in: original, from: saved)
        }
        if people.isEmpty, plan.methods.contains(where: \.usesPersonalProfile) {
            people = initialIntakeParticipants(for: plan)
        }
        plan.participantIDs = people.map(\.id); plan.participantNames = people.map(\.participantLabel)
        if people.count > 1 { plan.subject = "多人" }
        let hadMeihua = base.plan.methods.contains(.meihua) || base.results.contains(where: { $0.method == .meihua })
        let numbers = castingNumbers(for: plan, supplied: hadMeihua ? base.input.numbers : [])
        plan.draftParticipants = people; plan.draftNumbers = numbers
        let input = supplementInput(base: base, plan: plan, participants: people, numbers: numbers)
        let reused = reusableResults(input: input, plan: plan)
        let report = ReadingPreparationPolicy.evaluate(plan: plan, participants: people, descriptors: registry.descriptors,
                                                       castingProfile: plan.castingProfile, numbers: numbers)
        let needsCalculation = report.assessments.contains { assessment in
            !reused.contains { $0.method == assessment.method && (!assessment.method.usesPersonalProfile || $0.participantID == assessment.participantID) }
        }
        let methodScopeChanged = selectsOnlyMethods && Set(base.plan.methods) != methods
        guard needsCalculation || methodScopeChanged else { return false }
        let newPeople = people.contains { person in !originals.contains { $0.id == person.id } }
        let needsNumbers = OracleInteractionPolicy.requests(for: plan, numbers: input.numbers).contains { $0.kind == .numbers }
        if newPeople || needsNumbers || !report.canProceed || report.assessments.contains(where: { !$0.canExecute }) {
            prepareConversation(plan)
            return true
        }
        plan.omittedMethods = report.omissions; plan.preparationNotes = preparationNotes(report)
        plan.reviewedParticipants = people; plan.draftParticipants = nil; plan.draftNumbers = nil
        messages.append(ChatMessage(role: .assistant, content: L10n.text("沿用已有结果，只补充新增方法或资料变化后需要更新的部分。", "I’ll keep the existing results and add what’s needed for the new methods or updated details."), kind: .intake))
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
            pendingPlan = nil; showIntake = false; analysisAttempt = nil
            phase = .awaitingInteraction; operationID = nil; task = nil
            presentRequestedInteraction()
        } else { startReading(input: input, plan: plan) }
    }

    /// A completed historical two-number cast is not an unfinished three-number
    /// draft. Supplements keep its confirmed mode and snapshot; a fresh reading
    /// has no base and must complete its newly requested interaction instead.
    private func retainConfirmedTwoNumberMode(in plan: inout OraclePlan, base: OracleRun, numbers: [Int]) {
        let unknown = base.input.profile.unknownFields.union(base.input.profile.declaredUnknownFields ?? [])
        guard plan.baseRunID == base.id, numbers == base.input.numbers,
              numbers.count == 2, numbers.allSatisfy({ (1...999).contains($0) }),
              !unknown.contains(.numbers),
              base.results.contains(where: { $0.method == .meihua && [.complete, .partial].contains($0.status) }) else { return }
        plan.requiredFields.removeAll { $0 == .numbers }
        plan.interactions?.removeAll { $0.method == .meihua && $0.kind == .numbers }
    }

    private func methodsMentioned(in text: String, positiveRequestsOnly: Bool = false) -> [OracleMethod] {
        let aliases: [(OracleMethod, [String])] = [(.bazi, ["八字", "四柱"]), (.ziwei, ["紫微", "紫薇"]), (.liuyao, ["六爻"]), (.meihua, ["梅花"]), (.qimen, ["奇门"]), (.xiaoliuren, ["小六壬"]), (.chenggu, ["称骨"]), (.xingming, ["姓名五格", "五格"]), (.astrology, ["占星", "星盘"]), (.tarot, ["塔罗", "塔羅"])]
        let english = EnglishConversation.methods(in: text, positiveOnly: positiveRequestsOnly)
        let chinese = aliases.filter { entry in
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
        return OracleMethod.allCases.filter { english.contains($0) || chinese.contains($0) }
    }

    private func enforceRequestedMethods(_ plan: inout OraclePlan, text: String, keepsPendingScope: Bool = false) {
        let named = methodsMentioned(in: text, positiveRequestsOnly: true)
        let calculations = ReadingContinuationPolicy.requestedCalculationMethods(in: text)
        let englishMethod = EnglishConversation.requestedMethods(in: text, additive: false, allowFreshScope: true)
        let only = ["只", "仅"].contains(where: text.contains)
            || !englishMethod.isEmpty && EnglishConversation.matches(text, #"\b(?:only|just)\b"#)
        let required = only || ["必须", "指定", "一定要"].contains(where: text.contains)
            || !englishMethod.isEmpty && EnglishConversation.matches(text, #"\b(?:must|required|have to)\b"#)
        let revision = ["换成", "改用", "改成", "换用", "改为", "改按"].contains(where: text.contains)
            || !englishMethod.isEmpty && EnglishConversation.matches(text, #"\bswitch to\b|\binstead\b"#)
        if revision, !named.isEmpty { plan.methods = named; plan.mandatoryMethods = required || named.count == 1 ? named : [] }
        let specific = named.count == 1 && !["混合", "结合", "综合"].contains(where: text.contains) && ["按照", "用八字", "用紫微", "用紫薇"].contains(where: text.contains)
        if !named.isEmpty, required || specific {
            plan.mandatoryMethods = named
            if only { plan.methods = named }
            else { plan.methods = Array(Set(plan.methods + named)).sorted { $0.rawValue < $1.rawValue } }
        }
        // A direct request must survive an incomplete model plan, including
        // methods that need a new draw or additional personal details.
        if !calculations.isEmpty {
            let mixed = (["混合", "结合", "综合", "配合"].contains(where: text.contains)
                || EnglishConversation.matches(text, #"\b(?:combine|mix|combined|mixed)\b"#))
                && (text.range(of: #"其他方法|别的方法|多种方法|所有方法|多法"#, options: .regularExpression) != nil
                    || EnglishConversation.matches(text, #"\b(?:other|multiple|all) methods\b"#))
            let addingToPending = keepsPendingScope && pendingPlan != nil && !revision && !only
                && !ReadingContinuationPolicy.requestedAdditionalMethods(in: text, requiresAdditiveWording: true).isEmpty
            let retained = mixed ? plan.methods : addingToPending ? pendingPlan?.methods ?? [] : []
            let retainedMandatory = mixed ? plan.mandatoryMethods ?? [] : addingToPending ? pendingPlan?.mandatoryMethods ?? [] : []
            let selected = Set(retained + calculations)
            let mandatory = Set(retainedMandatory + calculations)
            plan.methods = OracleMethod.allCases.filter { selected.contains($0) }
            plan.mandatoryMethods = OracleMethod.allCases.filter { mandatory.contains($0) }
            let descriptors = registry.descriptors.filter { selected.contains($0.method) }
            let permittedFields = Set(descriptors.flatMap { $0.requiredFields + $0.optionalFields })
            plan.requiredFields = plan.requiredFields.filter { permittedFields.contains($0) }
            plan.interactions = plan.interactions?.filter { selected.contains($0.method) }
        }
    }

    private func questionUpdatingMethods(_ question: String, from previous: [OracleMethod], to methods: [OracleMethod]) -> String {
        let aliases: [OracleMethod: String] = [
            .bazi: "八字|四柱", .ziwei: "紫微斗数|紫微|紫薇", .tarot: "塔罗牌|塔罗|塔羅|tarot",
            .meihua: "梅花易数|梅花", .liuyao: "六爻", .qimen: "奇门遁甲|奇门", .xiaoliuren: "小六壬",
            .chenggu: "称骨", .xingming: "姓名五格|五格|姓名学", .astrology: "西方占星|占星|星盘"
        ]
        let replacement = methods.map(\.progressName).joined(separator: "、")
        guard !replacement.isEmpty else { return question }
        let allAliases = previous.compactMap { aliases[$0] }.joined(separator: "|")
        guard !allAliases.isEmpty else { return question }
        let name = "(?:" + allAliases + ")"
        return question.replacingOccurrences(of: "(用|按|按照|采用|加上|补算)" + name + "(?:(?:和|与|及|、|以及)" + name + ")*",
                                             with: "$1" + replacement, options: [.regularExpression, .caseInsensitive])
    }

    private func pendingPreparationContext() -> String? {
        if let plan = pendingPlan {
            let report = ReadingPreparationPolicy.evaluate(plan: plan, participants: intakeParticipants, descriptors: registry.descriptors,
                                                           castingProfile: castingProfileSnapshot(for: plan), numbers: plan.draftNumbers)
            return "当前尚未完成的问事：\(plan.question)\n当前方法：\(plan.methods.map(\.progressName).joined(separator: "、"))\n应用实际准备状态：\(report.summary)\n必需和可选字段以上述准备状态为准；未完成确认，不能声称已得到结果。"
        }
        if let session = pendingInteraction, let request = session.currentRequest {
            let positions = request.kind == .tarot
                ? "\n本次实际牌位（按顺序）：\(request.tarotPositions.joined(separator: "、"))。解释抽牌规则时使用这些牌位，可翻译名称，不得自行更换为另一套牌位。" : ""
            return "当前问事：\(session.input.question)\n正在等待用户完成：\(request.method.progressName)，操作类型 \(request.kind.rawValue)。已翻开 \(session.draft?.revealedCount ?? 0) 张牌。\(positions)\n未完成的选择不是已确认结果，不能编造剩余牌面或爻值。用户可以提问规则、稍后继续、取消或换方法。"
        }
        return nil
    }

    func singleOtherParticipantFocus(_ question: String, references: [ConversationPlanningReference], transcript: [ChatMessage]) -> (OracleRun, String)? {
        let focusRequest = question.filter { !$0.isWhitespace && !$0.isPunctuation }
        guard let selfProfileID,
              focusRequest.range(of: #"^(?:那)?(?:只|单独)(?:看|问)(?:他|她)(?:呢|吧)?(?:先)?(?:不看|不问|不要看|别看)我(?:了)?$"#, options: .regularExpression) != nil,
              ReadingContinuationPolicy.requestedCalculationMethods(in: question).isEmpty,
              !ReadingContinuationPolicy.explicitlyRequestsNewReading(question),
              let original = references.compactMap(\.run).first else { return nil }
        let lastUser = transcript.last(where: { $0.role == .user })?.content ?? ""
        let updates = ProfileDirectory.explicitSelfUpdates(in: lastUser, profiles: profiles, selfProfileID: selfProfileID)
            + ProfileDirectory.parseExplicitUpdates(in: lastUser, profiles: profiles)
        let people = original.input.readingParticipants
        let updatesOnlyOriginalPeople = !updates.isEmpty && updates.allSatisfy { update in
            people.contains { person in
                if let id = update.id { return id == person.id }
                return update.name == person.resolvedName
            }
        }
        guard transcript.last(where: \.isConversationTurn)?.runID == original.id || updatesOnlyOriginalPeople else { return nil }
        guard people.count == 2, people.contains(where: { $0.id == selfProfileID }),
              let person = people.first(where: { $0.id != selfProfileID }) else { return nil }
        var focused = original
        focused.input.profile = CastingLocationDraft.applying(original.input.profile, to: person)
        focused.input.participants = [person]; focused.input.subject = "他人"
        focused.plan.castingProfile = CastingLocationDraft(profile: original.input.profile).profile
        focused.plan.subject = "他人"; focused.plan.participantIDs = [person.id]; focused.plan.participantNames = [person.participantLabel]
        focused.results = original.results.filter { !$0.method.usesPersonalProfile || $0.participantID == person.id }
        guard !focused.results.isEmpty, calculationInputsAreCurrent(for: focused) else { return nil }
        return (focused, "接着「\(original.input.question)」，本条仅看\(person.participantLabel)，不分析本人。")
    }

    func calculationInputsAreCurrent(for run: OracleRun) -> Bool {
        let latestPeople = run.input.readingParticipants.map { original in
            guard let saved = profiles.first(where: { $0.id == original.id }), saved.updatedAt >= original.updatedAt else { return original }
            return saved
        }
        var candidate = run.input
        if run.input.participants != nil { candidate.participants = latestPeople }
        if let current = latestPeople.first(where: { $0.id == candidate.profile.id }) { candidate.profile = current }
        // Refresh personal birth details without replacing the question's
        // frozen casting point with a person's subsequently edited location.
        candidate.profile = CastingLocationDraft.applying(run.input.profile, to: candidate.profile)
        let usable = run.results.filter { $0.status == .complete || $0.status == .partial }
        let reused = ReadingContinuationPolicy.reusableResults(from: run, for: candidate, methods: usable.map(\.method))
        let retainedIDs = Set(reused.map(\.id))
        return usable.allSatisfy { retainedIDs.contains($0.id) }
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
        let question = message.resolvedQuestion ?? (message.kind == .reading ? base.plan.followUpQuestion ?? base.input.question
            : messages.dropLast().last(where: { $0.role == .user })?.content ?? base.input.question)
        messages.append(ChatMessage(role: .user, content: L10n.text("补抽 1 张 · \(offer.focus)", "Draw one clarifying card · \(offer.focus)")))
        startTarotClarification(offer, base: base, question: question)
    }

    private func startTarotClarification(_ suggestion: TarotClarificationSuggestion, base: OracleRun, question: String) {
        quotaTaskID = UUID()
        let clarification = TarotClarificationRequest(focus: suggestion.focus, originalPosition: suggestion.originalPosition, question: question)
        var plan = base.plan
        plan.quotaTaskID = quotaTaskID
        plan.action = "supplement"; plan.baseRunID = base.id; plan.followUpQuestion = question
        plan.tarotClarification = suggestion
        let request = OracleInteractionRequest(method: .tarot, kind: .tarot, tarotClarification: clarification)
        beginActivitySession()
        messages.append(ChatMessage(role: .assistant, content: L10n.text("请选择一张补牌。本轮关注「\(clarification.focus)」。", "Choose one clarifying card. This round focuses on “\(clarification.focus)”."), kind: .intake))
        activityMessageID = messages.last?.id
        pendingInteraction = OracleInteractionSession(input: base.input, plan: plan, requests: [request])
        phase = .awaitingInteraction
        presentRequestedInteraction()
    }

    private func tarotClarificationCommand(_ question: String) -> String? {
        if let focus = EnglishConversation.clarifierFocus(question) { return focus }
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
                ? L10n.text("这次已补完两张牌，可以继续结合这五张牌追问。", "You’ve drawn both clarifying cards. You can ask about any of the five cards.")
                : L10n.text("请先完成当前塔罗牌阵的解读，再继续补牌。", "Finish this Tarot reading before drawing a clarifying card.")
            messages.append(ChatMessage(role: .assistant, content: content, runID: base.id))
            persist(); return true
        }
        let defaultFocus = (base.input.tarotClarificationRounds ?? []).isEmpty ? L10n.text("下一步的行动建议", "What to do next") : L10n.text("行动前最值得核实的条件", "What to check before taking action")
        let suggestion = focus.isEmpty ? offer ?? .init(focus: defaultFocus) : .init(focus: focus)
        let question = focus.isEmpty ? base.plan.followUpQuestion ?? base.input.question : text
        startTarotClarification(suggestion, base: base, question: question)
        return true
    }

    func canSendWhileAwaitingInteraction(_ text: String) -> Bool { true }

    private func isCancellationRequest(_ text: String) -> Bool {
        guard ReadingContinuationPolicy.requestedCalculationMethods(in: text).isEmpty,
              ReadingContinuationPolicy.bareMethodChange(in: text).isEmpty,
              !ReadingExecutionPolicy.isExplicitCalculationCommand(text),
              !ReadingContinuationPolicy.explicitlyRequestsNewReading(text) else { return false }
        let compact = text.filter { !$0.isWhitespace }
        return compact.range(of: #"^(?:(?:那(?:就)?|我|我们|请|这次|先|暂时))*(?:不(?:想)?(?:算|抽|掷|测)(?:(?:新|这|本|当前)?(?:卦|牌|牌阵|次))?(?:了|啦|吧)|取消(?:这次|本次|当前)?(?:的)?(?:问事|抽牌|塔罗牌?|投币|投掷|推演|操作|补牌|占卜|测算)?|停止(?:这次|本次|当前)?(?:的)?(?:推演|问事|抽牌|投币|操作)?)(?:[。！!，,；;]|$)"#, options: .regularExpression) != nil
            || EnglishConversation.matches(text, #"^\s*(?:please\s+)?(?:cancel|stop|never mind|nevermind|don['’]t (?:draw|cast|calculate))(?:\s+(?:this|the|current|reading|draw|cast|operation|it))*[.!?,;]?"#)
    }

    private func isSameQuestionMethodSelection(_ text: String) -> Bool {
        let clauses = text.components(separatedBy: CharacterSet(charactersIn: "，,。；;！!？?\n")).filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        let isSelection: (String) -> Bool = { ReadingContinuationPolicy.isMethodOnlyRequest($0) || !ReadingContinuationPolicy.bareMethodChange(in: $0).isEmpty }
        return clauses.contains(where: isSelection) && clauses.allSatisfy { isSelection($0) || isCancellationRequest($0) }
    }

    private func answerWhileAwaitingInteraction(_ message: ChatMessage) {
        quotaTaskID = UUID()
        beginActivitySession(); notice = nil; showInteraction = false
        activityMessageID = message.id; analysisAttempt = .planning(questionID: message.id)
        phase = .planning
        let operation = UUID(); operationID = operation; persist()
        let base = pendingInteraction?.plan.baseRunID.flatMap { id in runs.first { $0.id == id } }
        let history = ContextCompressor.history(messages: Array(messages.prefix { $0.id != message.id }), summary: summary)
        task = Task { [weak self] in
            await self?.answerFollowUp(message.content, history: history, operation: operation, run: base)
        }
    }

    func send(_ question: String) {
        let text = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        guard text.count <= 6000 else { notice = L10n.text("这次问题较长，请先整理到六千字以内。", "Keep your question to 6,000 characters or fewer."); return }
        let wasBusy = isBusy
        if isBusy { interruptAnalysis(backgroundExpired: false) }
        if isCancellationRequest(text), pendingPlan != nil || pendingInteraction != nil || wasBusy {
            let message = ChatMessage(role: .user, content: text)
            messages.append(message)
            if pendingPlan != nil || pendingInteraction != nil { cancelPendingReading() }
            else { analysisAttempt = nil; persist() }
            if text.range(of: #"陪我|聊聊|聊一聊|告诉我|给我|想聊|talk|tell me|give me"#, options: [.regularExpression, .caseInsensitive]) != nil {
                planQuestion(message)
            }
            return
        }
        let bareTopicSwitch = EnglishConversation.isBareTopicSwitch(text) || text.range(of: #"^(?:先|我们|咱们)?(?:换(?:个|一个)?(?:新)?(?:问题|话题)|聊点别的|问点别的)(?:吧|好吗)?[。！!？?]*$"#, options: .regularExpression) != nil
        if bareTopicSwitch {
            let hadDraft = pendingInteraction != nil || pendingPlan != nil
            newConversation()
            messages.append(ChatMessage(role: .user, content: text))
            let prompt = hadDraft ? L10n.text("上一问的进度可以从历史继续。现在想问哪件事？", "You can resume your previous reading from History. What would you like to ask now?") : L10n.text("现在想问哪件事？", "What would you like to ask now?")
            messages.append(ChatMessage(role: .assistant, content: prompt))
            persist(); return
        }
        if (pendingInteraction != nil || pendingPlan != nil), ReadingContinuationPolicy.explicitlyChangesScope(text, profiles: profiles) {
            newConversation()
            messages.append(ChatMessage(role: .assistant, content: L10n.text("上一问的操作进度已保存，可以从历史继续。", "Your progress is saved. You can resume that reading from History."), kind: .notice))
        }
        if let session = pendingInteraction, let request = session.currentRequest, request.kind == .numbers,
           text.range(of: #"^[\s\d，,、。.;；+-]+$"#, options: .regularExpression) != nil {
            messages.append(ChatMessage(role: .user, content: text))
            let parts = text.components(separatedBy: CharacterSet.decimalDigits.inverted).filter { !$0.isEmpty }
            let numbers = parts.compactMap(Int.init)
            guard text.range(of: #"[-−.．/:年月日]"#, options: .regularExpression) == nil,
                  numbers.count == request.requiredNumberCount, numbers.allSatisfy({ (1...999).contains($0) }) else {
                let prompt = request.requiredNumberCount == 2
                    ? L10n.text("请留下两个1到999的整数，例如“12，23”。我会照你给出的数字继续。", "Enter two whole numbers from 1 to 999, such as 12 and 23. I’ll use those numbers for the reading.")
                    : L10n.text("请留下三个1到999的整数，例如“12，23，6”。我会照你给出的数字继续。", "Enter three whole numbers from 1 to 999, such as 12, 23, and 6. I’ll use those numbers for the reading.")
                messages.append(ChatMessage(role: .assistant, content: prompt)); persist(); return
            }
            completeInteraction(.init(requestID: request.id, numbers: numbers), sessionID: session.id)
            return
        }
        if let session = pendingInteraction {
            let changesMethod = !ReadingContinuationPolicy.requestedCalculationMethods(in: text).isEmpty
                || !ReadingContinuationPolicy.bareMethodChange(in: text).isEmpty
                || ReadingContinuationPolicy.explicitlyRequestsNewReading(text)
                || ReadingExecutionPolicy.isExplicitCalculationCommand(text)
            if changesMethod {
                var pending = session.plan
                pending.draftParticipants = session.input.readingParticipants
                pending.draftNumbers = session.input.numbers
                pending.castingProfile = CastingLocationDraft(profile: session.input.profile).profile
                pendingPlan = pending; pendingInteraction = nil; showInteraction = false
                intakeSessionID = UUID(); phase = .awaitingIntake
            } else {
                let message = ChatMessage(role: .user, content: text)
                messages.append(message)
                answerWhileAwaitingInteraction(message)
                return
            }
        }
        if pendingPlan == nil, let base = !usesTestAgent ? activeReplyRun : latestRun, base.input.tarotDraws != nil,
           handleTarotClarificationCommand(text, base: base) { return }
        if pendingPlan != nil, ConversationalIntake.isConfirmation(text) { confirmPendingIntake(); return }
        if var plan = pendingPlan, ["不对", "有问题", "需要修改", "不是", "不准确"].contains(text)
            || EnglishConversation.matches(text, #"^(?:that['’]s (?:wrong|not right)|not correct|i need to make a correction|i need to change something)[.!]?$"#) {
            plan.preparationStage = .collecting; plan.reviewedParticipants = nil
            messages.append(ChatMessage(role: .user, content: text))
            prepareConversation(plan, clarification: L10n.text("是哪一位的哪项信息需要更正？直接告诉我正确内容，我会重新整理给你核对。", "Whose details should I correct, and what should they be? I’ll update them for you to review."))
            return
        }
        if pendingPlan == nil, activities.last?.status == .waiting { finishActivity() }
        let message = ChatMessage(role: .user, content: text)
        messages.append(message)
        planQuestion(message)
    }

    private func planQuestion(_ message: ChatMessage) {
        let isPlanningRetry: Bool
        if case .planning(let previousID) = analysisAttempt { isPlanningRetry = previousID == message.id }
        else { isPlanningRetry = false }
        if !isPlanningRetry {
            let parent = pendingPlan?.quotaTaskID ?? pendingInteraction?.plan.quotaTaskID
            if let parent { quotaTaskID = parent }
            else if activities.last?.status != .waiting || quotaTaskID == nil { quotaTaskID = UUID() }
        }
        let text = message.content
        let questionID = message.id
        beginActivitySession(); notice = nil
        activityMessageID = questionID
        analysisAttempt = .planning(questionID: questionID)
        phase = .planning; progress(L10n.text("理解问题与确认询问对象", "Understanding the question and who it concerns"))
        let id = UUID(); operationID = id; persist()
        let replyLanguage = EnglishConversation.replyLanguage(in: text) ?? AppLanguage.current
        task = Task { [weak self] in
            guard let self else { return }
            await prepareContext(operation: id, language: replyLanguage)
            guard operationID == id, !Task.isCancelled else { return }
            let transcript = Array(messages.prefix { $0.id != questionID })
            let history = ContextCompressor.history(messages: transcript, summary: summary, language: replyLanguage)
            let previousPlan = pendingPlan
            let usesAI = !usesTestAgent
            let references = usesAI ? ConversationPlanningReference.candidates(in: transcript, runs: runs) : []
            if previousPlan == nil, let (focused, resolved) = singleOtherParticipantFocus(text, references: references, transcript: transcript) {
                if let index = messages.firstIndex(where: { $0.id == questionID }) { messages[index].resolvedQuestion = resolved }
                await answerFollowUp(text, history: history, operation: id, run: focused, resolvedQuestion: resolved)
                return
            }
            let currentRun = previousPlan == nil ? (usesAI ? references.first?.run : latestRun) : nil
            let target = ReadingContinuationPolicy.participantIntent(in: text, profiles: profiles)
            let scope = ReadingContinuationPolicy.scopeChange(question: text, run: currentRun, profiles: profiles, selfProfileID: selfProfileID)
            var base = scope == .none ? currentRun : nil
            let changesPendingPeople = previousPlan.map { previous in
                let names = Set((previous.participantNames ?? []) + self.initialIntakeParticipants(for: previous).map(\.resolvedName))
                return !Set(target.names).isSubset(of: names) || !names.isDisjoint(with: target.excludedNames)
                    || (target.includesSelf && previous.subject == "他人")
                    || (target.isGroup && previous.subject != "多人")
            } ?? false
            let keepsPendingScope = scope == .none && !changesPendingPeople
            // Deciding to calculate a hypothetical case is separate from
            // asserting that its personal details are true permanent records.
            let mayPersistProfileFacts = ProfileFactPolicy.allowsPersistence(in: text)
            let scopedPending = keepsPendingScope ? previousPlan : nil
            var answer = scopedPending.map { ConversationalIntake.answer(text, plan: $0, profiles: self.profiles) } ?? IntakeAnswer()
            let pendingContextIDs = scopedPending?.requestedProfileID.map { [$0] } ?? scopedPending?.participantIDs ?? selfProfileID.map { [$0] } ?? []
            let ownFacts = mayPersistProfileFacts
                ? ProfileDirectory.explicitSelfUpdates(in: text, profiles: profiles, selfProfileID: selfProfileID) : []
            let refersToSelf = target.includesSelf || ProfileDirectory.hasExplicitSelfFacts(in: text)
            let refersToOther = target.refersToOther || EnglishConversation.refersToOtherProfile(text) || text.range(of: #"(?:^|[，,。；;])\s*(?:他|她)(?:的|出生|生日)"#, options: .regularExpression) != nil
            let introducesOtherPerson = ["另外", "另一个", "另一位", "其他人", "别人", "他人", "朋友", "同事", "同学", "家人", "亲戚", "对象", "伴侣", "对方", "父亲", "母亲", "爸爸", "妈妈", "孩子", "儿子", "女儿", "男友", "女友", "丈夫", "妻子", "老公", "老婆"]
                .contains(where: text.contains) || EnglishConversation.introducesOtherPerson(text)
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
            if EnglishConversation.isLunarDate(text) { for index in explicitUpdates.indices { explicitUpdates[index].birthDate = nil } }
            if answer.clarification == nil { explicitUpdates += answer.updates }
            else { explicitUpdates = [] }
            if answer.clarification == nil, explicitUpdates.isEmpty, contextIDs.count == 1,
               (["出生", "生日", "性别", "时区"].contains(where: text.contains)
                   || EnglishConversation.matches(text, #"\b(?:born|birth(?:day| date| time|place)?|sex|gender|time zone)\b"#)),
               let selected = profiles.first(where: { $0.id == contextIDs[0] }),
               !selected.resolvedName.isEmpty,
               !refersToSelf || selected.id == selfProfileID,
               !refersToOther || selected.id != selfProfileID,
               !introducesOtherPerson,
               !profiles.contains(where: { $0.id != selected.id && !$0.resolvedName.isEmpty && text.contains($0.resolvedName) }),
               (pendingPlan != nil || !["他", "她", "朋友"].contains(where: text.contains)) {
                explicitUpdates = ProfileDirectory.parseExplicitUpdates(in: "姓名：\(selected.resolvedName)，\(text)", profiles: profiles)
            }
            if !mayPersistProfileFacts { explicitUpdates = [] }
            let collected = applyProfileUpdates(explicitUpdates)
            if mayPersistProfileFacts, let name = ProfileDirectory.explicitSelfName(in: text, profiles: profiles) {
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
            if usesTestAgent, previousPlan == nil, let original = base,
               ReadingContinuationPolicy.isBareRecastRequest(text) || recastWithProfileUpdate {
                // A bare recast changes the draw, not the question being asked.
                plan = OraclePlan(intent: original.plan.intent, subject: original.input.subject,
                                  methods: original.plan.methods, requiredFields: original.plan.requiredFields,
                                  note: L10n.text("按原问题重新推演，请先核对这次资料。", "Review the details before starting a new reading for the same question."),
                                  question: references.first?.resolvedQuestion ?? original.input.question)
                plan.action = "intake"; plan.interactions = original.plan.interactions
                plan.participantIDs = original.input.readingParticipants.map(\.id)
                plan.participantNames = original.input.readingParticipants.map(\.participantLabel)
                plan.relationship = original.input.relationship
                plan.mandatoryMethods = original.plan.mandatoryMethods
                plan.collectionDeclined = original.plan.collectionDeclined
                enforceRequestedMethods(&plan, text: text)
                captureCastingPreferences(in: &plan)
                prepareConversation(plan); return
            }
            let methodChange = ReadingContinuationPolicy.bareMethodChange(in: text)
            let additionalMethods = methodChange.isEmpty ? ReadingContinuationPolicy.requestedAdditionalMethods(in: text) : methodChange
            let extendsExistingReading = !additionalMethods.isEmpty &&
                (!methodChange.isEmpty || ReadingContinuationPolicy.isMethodOnlyRequest(text) ||
                 !ReadingContinuationPolicy.requestedAdditionalMethods(in: text, requiresAdditiveWording: true).isEmpty)
            if usesTestAgent, let base, let draws = base.input.tarotDraws, TarotDeck.isValidInitialSpread(draws),
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
            let greeting = text.count < 20 && ["你好", "您好", "在吗", "你是谁", "你能做什么", "谢谢", "先聊到这里", "再见"].contains { text.contains($0) }
                || EnglishConversation.matches(text, #"^(?:hi|hello|hey|thank you|thanks|who are you|what can you do)[.!? ]*$"#)
            if greeting, !ReadingExecutionPolicy.isExplicitCalculationCommand(text),
               additionalMethods.isEmpty, methodsMentioned(in: text, positiveRequestsOnly: true).isEmpty {
                await answerFollowUp(text, history: history, operation: id, run: nil); return
            }
            if ReadingContinuationPolicy.isMethodConsultation(text), !ReadingExecutionPolicy.isExplicitCalculationCommand(text) {
                await answerFollowUp(text, history: history, operation: id, run: base, resolvedQuestion: text)
                return
            }
            progress(L10n.text("选择适用方法与所需资料", "Choosing methods and checking what details they need"))
            if usesAI {
                do {
                    plan = try await AIQuotaTaskScope.$stage.withValue(quotaStage("plan:" + questionID.uuidString.lowercased())) {
                        try await self.client.plan(question: text, profile: self.profile, plugins: self.registry.descriptors, history: history, profiles: self.profiles, pendingPlan: keepsPendingScope ? self.pendingPlan : nil, existingRun: base, references: references, language: replyLanguage)
                    }
                }
                catch {
                    guard operationID == id, !Task.isCancelled else { return }
                    failAnalysis(L10n.text("暂未能处理这次问题", "Couldn’t process this question"), error: error)
                    return
                }
            }
            guard operationID == id, !Task.isCancelled else { return }
            let requestsFreshReading = ReadingContinuationPolicy.explicitlyRequestsNewReading(text)
            let preservedRecastQuestion = ReadingContinuationPolicy.isBareRecastRequest(text)
                ? previousPlan?.question ?? base?.input.question ?? currentRun?.input.question : nil
            let sameQuestionReference = isSameQuestionMethodSelection(text) || text.range(of: #"刚才|同一件|同一事|这件|那件|原问题|原来的问题|same (?:question|topic)|earlier (?:question|topic)"#, options: [.regularExpression, .caseInsensitive]) != nil
            let effectiveQuestion = resolveConversationUnderstanding(in: &plan, references: references, rawQuestion: text,
                                                                     base: &base, pending: previousPlan)
            if let effectiveQuestion, let index = messages.firstIndex(where: { $0.id == questionID }) {
                messages[index].resolvedQuestion = effectiveQuestion
                messages[index].referenceMessageID = plan.understanding?.referenceMessageID
            }
            if let executionAction = ReadingExecutionPolicy.validatedAction(understanding: plan.understanding,
                rawQuestion: text, proposedAction: plan.action ?? "clarify", hasRelatedRun: base != nil) {
                // The validated reference chooses context; the execution intent
                // chooses work. No later legacy shortcut may turn an intake
                // back into an explanation or upgrade an answer into a cast.
                let executionReference = plan.understanding?.referenceMessageID.flatMap { referenceID in
                    references.first(where: { $0.messageID == referenceID })
                }
                let referencedRun = executionReference?.run.flatMap { referenced in
                    self.runs.first(where: { $0.id == referenced.id })
                }
                switch executionAction {
                case "reply":
                    if let parent = pendingPlan?.quotaTaskID, parent == quotaTaskID {
                        // A side answer must not occupy the unfinished reading's
                        // stable final-answer stage or end its admission ticket.
                        quotaTaskID = UUID()
                        persist()
                    }
                    await answerFollowUp(text, history: history, operation: id, run: base,
                                         tarotOffer: plan.tarotClarification, resolvedQuestion: effectiveQuestion)
                case "clarify":
                    clarifyReadingExecution(plan.action == "clarify" ? plan.note : nil)
                case "collect":
                    let grounded = mayPersistProfileFacts ? ProfileDirectory.groundedUpdates(plan.profileUpdates ?? [], in: text,
                                                                      profiles: profiles, contextIDs: contextIDs) : []
                    let extracted = applyProfileUpdates(grounded)
                    let changed = Set(collected.appliedIDs + extracted.appliedIDs)
                    let names = profiles.filter { changed.contains($0.id) }.map(\.resolvedName).sorted()
                    let issues = collected.issues + extracted.issues
                    let note = !issues.isEmpty ? issues.map(\.message).joined(separator: "\n")
                        : names.isEmpty
                            ? L10n.text("请写下需要留存或更正的人员和资料。", "Tell me whose details to save or correct.")
                            : L10n.text("已分别记下\(names.joined(separator: "、"))的资料。", "Saved the details for \(names.joined(separator: ", ")).")
                    messages.append(ChatMessage(role: .assistant, content: note))
                    activityMessageID = messages.last?.id
                    showIntake = false
                    progress(names.isEmpty ? L10n.text("等待明确人员资料", "Waiting for profile details") : L10n.text("资料已分别留存", "Profiles saved"), state: names.isEmpty ? .waiting : .completed)
                    finishOperation()
                case "supplement":
                    guard let base else { clarifyReadingExecution(nil); return }
                    let grounded = mayPersistProfileFacts ? ProfileDirectory.groundedUpdates(plan.profileUpdates ?? [], in: text,
                                                                      profiles: profiles, contextIDs: contextIDs) : []
                    _ = applyProfileUpdates(grounded)
                    resolveParticipants(in: &plan, question: text, allowPersistentCreation: mayPersistProfileFacts)
                    plan.action = "supplement"
                    if !prepareSupplement(plan, base: base, question: effectiveQuestion ?? text) {
                        await answerFollowUp(text, history: history, operation: id, run: base,
                                             resolvedQuestion: effectiveQuestion)
                    }
                case "intake":
                    let source = referencedRun ?? base ?? (plan.understanding == nil ? currentRun : nil)
                    let requested = ReadingContinuationPolicy.requestedCalculationMethods(in: text)
                    if !requested.isEmpty { plan.methods = requested }
                    if plan.methods.isEmpty { plan.methods = source?.plan.methods ?? previousPlan?.methods ?? [] }
                    plan.methods = plan.methods.filter { self.registry.plugin($0) != nil }
                    guard !plan.methods.isEmpty else { clarifyReadingExecution(nil); return }
                    let sourcePeople = source?.input.readingParticipants ?? []
                    let sourceIDs = Set(sourcePeople.map(\.id))
                    let sourceNames = Set(sourcePeople.flatMap { [$0.resolvedName, $0.participantLabel] })
                    let requestedIDs = Set(plan.participantIDs ?? [])
                    let requestedNames = Set(plan.participantNames ?? [])
                    // Reference validation may already have copied these IDs
                    // into the plan. They still need an editable draft when
                    // the person no longer exists in the permanent directory.
                    let keepsSourcePeople = (requestedIDs.isEmpty || requestedIDs == sourceIDs)
                        && requestedNames.isSubset(of: sourceNames)
                    if plan.understanding?.relation != .changedParticipants,
                       scope == .none, let source, keepsSourcePeople {
                        plan.subject = source.input.subject
                        plan.participantIDs = source.input.readingParticipants.map(\.id)
                        plan.participantNames = source.input.readingParticipants.map(\.participantLabel)
                        plan.draftParticipants = source.input.readingParticipants.map { original in
                            self.profiles.first(where: { $0.id == original.id }) ?? original
                        }
                        plan.relationship = plan.relationship ?? source.input.relationship
                    } else { plan.draftParticipants = nil }
                    // A short redraw command refers to the selected turn's
                    // question, which can already be more specific than the
                    // old cast. Do not roll that target back to run.input.
                    let referencedQuestion = executionReference?.resolvedQuestion?.trimmingCharacters(in: .whitespacesAndNewlines)
                    let anchoredBareQuestion = plan.understanding?.execution != nil
                        && ReadingContinuationPolicy.isBareRecastRequest(text)
                        && referencedQuestion?.isEmpty == false ? referencedQuestion : nil
                    plan.question = anchoredBareQuestion ?? preservedRecastQuestion ?? effectiveQuestion ?? text
                    plan.action = "intake"
                    plan.baseRunID = nil; plan.followUpQuestion = nil; plan.resumesPendingQuestion = false
                    plan.castingProfile = nil; plan.draftNumbers = nil; plan.interactions = nil
                    plan.reviewedParticipants = nil; plan.omittedMethods = nil; plan.preparationNotes = nil
                    plan.tarotClarification = nil
                    let freshQuestion = plan.question
                    resolveParticipants(in: &plan, question: freshQuestion, allowPersistentCreation: mayPersistProfileFacts)
                    enforceRequestedMethods(&plan, text: text)
                    // A changed pending question is a new logical AI task, not
                    // permission to reuse the old task's bound final stage.
                    let replacedTask = previousPlan?.quotaTaskID.flatMap { $0 == self.quotaTaskID ? $0 : nil }
                    if let replacedTask {
                        quotaEndIntents[replacedTask.uuidString.lowercased()] = "cancelled"
                        quotaTaskID = UUID()
                    }
                    plan.quotaTaskID = quotaTaskID
                    captureCastingPreferences(in: &plan)
                    prepareConversation(plan)
                    if replacedTask != nil, persist(), !usesTestAgent { Task { await self.flushQuotaEnds() } }
                default:
                    clarifyReadingExecution(nil)
                }
                return
            }
            if ReadingContinuationPolicy.isBareRecastRequest(text),
               var fresh = previousPlan ?? (base ?? currentRun)?.plan {
                fresh.question = preservedRecastQuestion ?? fresh.question
                fresh.action = "intake"; fresh.understanding = nil
                fresh.baseRunID = nil; fresh.followUpQuestion = nil; fresh.resumesPendingQuestion = false
                fresh.castingProfile = nil; fresh.draftNumbers = nil; fresh.interactions = nil
                fresh.reviewedParticipants = nil; fresh.omittedMethods = nil; fresh.preparationNotes = nil
                fresh.tarotClarification = nil
                enforceRequestedMethods(&fresh, text: text, keepsPendingScope: keepsPendingScope)
                captureCastingPreferences(in: &fresh)
                prepareConversation(fresh)
                return
            }
            if !additionalMethods.isEmpty, previousPlan == nil, scope == .none,
               (sameQuestionReference || extendsExistingReading), let currentRun,
               plan.action == "clarify" || plan.understanding?.relation == .ambiguous {
                // The user has already identified the topic and methods. Missing
                // participant details belong in the form, not a generic topic question.
                base = currentRun; plan.action = "supplement"; plan.understanding = nil
                plan.methods = additionalMethods; plan.note = ""
            }
            if let effectiveQuestion, let index = messages.firstIndex(where: { $0.id == questionID }) {
                messages[index].resolvedQuestion = effectiveQuestion
                messages[index].referenceMessageID = plan.understanding?.referenceMessageID
            }
            // A verified continuation can answer directly even if the planner
            // proposed a fresh form. Profile corrections and method requests still
            // go through the existing calculation and reuse checks below.
            var grounded = mayPersistProfileFacts && answer.clarification == nil ? ProfileDirectory.groundedUpdates(plan.profileUpdates ?? [], in: text, profiles: profiles,
                                                                                           contextIDs: contextIDs) : []
            if EnglishConversation.isLunarDate(text) { for index in grounded.indices { grounded[index].birthDate = nil } }
            let isContextualReply = previousPlan == nil && plan.understanding?.relation == .continuation
                && effectiveQuestion != nil && !requestsFreshReading && additionalMethods.isEmpty
                && explicitUpdates.isEmpty && grounded.isEmpty
                && (base.map { self.calculationInputsAreCurrent(for: $0) } ?? true)
                && (plan.action == "reply" || plan.action == "intake")
            if isContextualReply {
                await answerFollowUp(text, history: history, operation: id, run: base,
                                     tarotOffer: plan.action == "reply" ? plan.tarotClarification : nil,
                                     resolvedQuestion: effectiveQuestion)
                return
            }
            let contextualPlan = plan.understanding != nil && previousPlan == nil
            if AIPlanRouting.shouldOpenFormForProfileRequest(action: plan.action, note: plan.note, question: text, hasPendingQuestion: previousPlan != nil) {
                let updates = plan.profileUpdates
                plan = AIPlanRouting.isConcreteReadingQuestion(text) ? localPeoplePlan(question: text, collectedIDs: collected.appliedIDs) : previousPlan ?? plan
                plan.action = "intake"; plan.profileUpdates = updates
            }
            let extracted = applyProfileUpdates(grounded)
            let changedIDs = Array(Set(collected.appliedIDs + extracted.appliedIDs))
            if contextualPlan, plan.understanding?.relation == .changedConditions {
                let updatedParticipants = base?.input.readingParticipants.contains { changedIDs.contains($0.id) } == true
                if !updatedParticipants {
                    // A change to the underlying situation cannot be treated as
                    // the same cast simply because plugin inputs look identical.
                    if plan.action == "supplement" { plan.action = "intake" }
                    base = nil
                    plan.baseRunID = nil
                    plan.followUpQuestion = nil
                }
            }
            let requestsReading = changesPendingPeople || !additionalMethods.isEmpty
                || (scope == .explicit && !methodsMentioned(in: text, positiveRequestsOnly: true).isEmpty)
            if !contextualPlan, !keepsPendingScope, plan.action != "collect", plan.action != "clarify",
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
            resolveParticipants(in: &plan, question: text, allowPersistentCreation: mayPersistProfileFacts)
            if base != nil, !additionalMethods.isEmpty,
               extendsExistingReading || sameQuestionReference || plan.understanding?.relation == .continuation,
               plan.action != "clarify", plan.action != "collect" {
                plan.action = "supplement"
                plan.methods = Array(Set(plan.methods + additionalMethods))
            } else if requestsFreshReading, let base = base ?? (scope == .none ? currentRun : nil),
                    plan.action != "clarify", plan.action != "collect" {
                // Explicit fresh draws/questions take precedence over a model's
                // supplement suggestion, including requests with a new subject.
                plan.action = "intake"; plan.baseRunID = nil; plan.followUpQuestion = nil; plan.question = preservedRecastQuestion ?? text
                if base.plan.methods == [.tarot], methodsMentioned(in: text, positiveRequestsOnly: true).isEmpty {
                    plan.methods = [.tarot]; plan.requiredFields = []; plan.interactions = []; plan.mandatoryMethods = nil
                } else if plan.methods.isEmpty { plan.methods = registry.localPlan(question: text, profile: profile).methods }
            }
            if plan.action == "reply", !additionalMethods.isEmpty || !ReadingContinuationPolicy.requestedCalculationMethods(in: text).isEmpty {
                // A new or text-only topic has no saved calculation to extend.
                // Start the requested method instead of answering without it.
                plan.action = "intake"
            }
            if previousPlan != nil || plan.action == nil || plan.action == "intake" || plan.action == "supplement" {
                enforceRequestedMethods(&plan, text: text, keepsPendingScope: keepsPendingScope)
            }
            if let base, previousPlan == nil, plan.action != "collect", plan.action != "clarify",
               plan.action == "supplement" || ((contextualPlan || followup) && plan.action == "reply") {
                if plan.action == "supplement", !additionalMethods.isEmpty {
                    plan.methods = Array(Set(plan.methods + additionalMethods))
                }
                let onlyExplain = additionalMethods.isEmpty && (text.range(of: #"(?:不要|不用|无需|不必|别).{0,5}(?:重算|重新|补算|再算)|只解释|(?:沿用|解释)原"#, options: .regularExpression) != nil
                    || EnglishConversation.declinesClarifier(text)
                    || EnglishConversation.matches(text, #"\b(?:just explain|only explain|without recalculating|do not recalculate|don['’]t recalculate)\b"#))
                if onlyExplain { await answerFollowUp(text, history: history, operation: id, run: base, resolvedQuestion: effectiveQuestion); return }
                if prepareSupplement(plan, base: base, question: text) { return }
                await answerFollowUp(text, history: history, operation: id, run: base,
                                     tarotOffer: plan.action == "reply" ? plan.tarotClarification : nil, resolvedQuestion: effectiveQuestion)
                return
            }
            if !(plan.mandatoryMethods ?? []).isEmpty, plan.action == "clarify", plan.understanding?.relation != .ambiguous {
                plan.action = "intake"
            }
            if keepsPendingScope, let previous = previousPlan,
               !ReadingContinuationPolicy.requestedCalculationMethods(in: text).isEmpty || !methodChange.isEmpty,
               sameQuestionReference || ReadingContinuationPolicy.isMethodOnlyRequest(text)
                    || !ReadingContinuationPolicy.bareMethodChange(in: text).isEmpty {
                plan.question = questionUpdatingMethods(previous.question, from: previous.methods, to: plan.methods)
                plan.subject = previous.subject; plan.relationship = previous.relationship
                plan.participantIDs = previous.participantIDs; plan.participantNames = previous.participantNames
                plan.draftParticipants = previous.draftParticipants
                plan.castingProfile = previous.castingProfile
                if plan.methods.contains(.meihua) { plan.draftNumbers = previous.draftNumbers }
                plan.action = "intake"
                captureCastingPreferences(in: &plan, inheriting: previous)
                prepareConversation(plan)
                return
            }
            let bareMethodSwitch = !ReadingContinuationPolicy.bareMethodChange(in: text).isEmpty
            let asksNewQuestion = !bareMethodSwitch && ["？", "?", "看看", "如何", "怎样", "算卦", "问卦"].contains(where: text.contains)
            if keepsPendingScope, let previous = previousPlan, !asksNewQuestion, !methodsMentioned(in: text).isEmpty,
               (!(plan.mandatoryMethods ?? []).isEmpty && Set(plan.mandatoryMethods ?? []) != Set(previous.mandatoryMethods ?? [])) ||
                ((bareMethodSwitch || ["换成", "改用", "改成", "换用", "改为", "改按"].contains(where: text.contains)) && Set(plan.methods) != Set(previous.methods)) {
                plan.question = questionUpdatingMethods(previous.question, from: previous.methods, to: plan.methods)
                if target.names.isEmpty, !target.includesSelf, !target.refersToOther {
                    plan.participantIDs = previous.participantIDs; plan.participantNames = previous.participantNames
                    plan.draftParticipants = pendingPlan?.draftParticipants
                }
                if plan.methods.contains(.meihua) { plan.draftNumbers = previous.draftNumbers }
                plan.castingProfile = previous.castingProfile
                plan.subject = previous.subject; plan.relationship = plan.relationship ?? previous.relationship
                plan.action = "intake"
                captureCastingPreferences(in: &plan, inheriting: previous)
                prepareConversation(plan)
                return
            }
            if keepsPendingScope, var previous = previousPlan, plan.understanding?.relation != .ambiguous,
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
                else if names.isEmpty { note = L10n.text("请写下需要留存或补充的姓名和已知资料；未明确的内容先保留原样。", "Enter the name and details you’d like to save or update. You can leave the rest as it is.") }
                else { note = L10n.text("已分别记下\(names.joined(separator: "、"))的资料。问卦时会自动带入，不需要重复填写已知信息。", "I saved the details for \(names.joined(separator: ", ")). They’ll be available in future readings.") }
                messages.append(ChatMessage(role: .assistant, content: note))
                activityMessageID = messages.last?.id
                progress(names.isEmpty ? L10n.text("等待明确人员资料", "Waiting for profile details") : L10n.text("资料已按姓名分别留存", "Profiles saved by name"), state: names.isEmpty ? .waiting : .completed)
                showIntake = false; finishOperation(); return
            }
            if !changedIDs.isEmpty {
                let names = changedIDs.compactMap { id in self.profiles.first(where: { $0.id == id })?.resolvedName }.sorted()
                messages.append(ChatMessage(role: .assistant, content: L10n.text("已按姓名更新留存资料：\(names.joined(separator: "、"))。", "Updated profiles for \(names.joined(separator: ", "))."), kind: .notice))
            }
            if plan.action == "reply" {
                if let parent = pendingPlan?.quotaTaskID, parent == quotaTaskID { quotaTaskID = UUID(); persist() }
                await answerFollowUp(text, history: history, operation: id, run: base,
                                     tarotOffer: plan.tarotClarification, resolvedQuestion: effectiveQuestion); return
            }
            if plan.action == "clarify" {
                messages.append(ChatMessage(role: .assistant, content: plan.note.isEmpty ? L10n.text("你最想问的是哪一件具体的事？", "What specific question is on your mind?") : plan.note))
                activityMessageID = messages.last?.id
                progress(L10n.text("等待你补充确认所问事项", "Waiting for you to clarify the question"), state: .waiting)
                finishOperation(); return
            }
            // A union of declared requirements prevents a model from bypassing local validation.
            if let effectiveQuestion, plan.baseRunID == nil, plan.resumesPendingQuestion != true {
                plan.question = preservedRecastQuestion ?? effectiveQuestion
            }
            let requirements = registry.descriptors.filter { plan.methods.contains($0.method) }.flatMap(\.requiredFields)
            plan.requiredFields = Array(Set(plan.requiredFields + requirements))
            captureCastingPreferences(in: &plan)
            prepareConversation(plan)
        }
    }

    private func resolveConversationUnderstanding(in plan: inout OraclePlan, references: [ConversationPlanningReference],
                                                  rawQuestion: String, base: inout OracleRun?, pending: OraclePlan?) -> String? {
        guard let understanding = plan.understanding else { return nil }
        if pending != nil, understanding.execution == nil,
           plan.resumesPendingQuestion == true || plan.action == "collect" || plan.action == "intake" {
            // The pending form owns its question and confirmed participants.
            return nil
        }
        let reference = references.first { $0.messageID == understanding.referenceMessageID }
        let question = understanding.resolvedQuestion.trimmingCharacters(in: .whitespacesAndNewlines)
        let needsReference = understanding.relation != .newQuestion && understanding.relation != .ambiguous

        if understanding.relation == .ambiguous || (needsReference && (reference == nil || question.isEmpty)) {
            base = nil
            plan.baseRunID = nil
            plan.understanding?.relation = .ambiguous
            plan.action = "clarify"
            plan.mandatoryMethods = []
            plan.profileUpdates = []
            return nil
        }

        base = nil
        plan.baseRunID = nil
        if understanding.relation == .continuation || understanding.relation == .changedConditions,
           let saved = reference?.run,
           let current = runs.first(where: { $0.id == saved.id }),
           current.results.contains(where: { $0.status == .complete || $0.status == .partial }) {
            let participantIDs = Set(current.input.readingParticipants.map(\.id))
            let proposedIDs = Set(plan.participantIDs ?? [])
            let participantNames = Set(current.input.readingParticipants.flatMap { [$0.resolvedName, $0.participantLabel] })
            let matchesParticipants = (proposedIDs.isEmpty || proposedIDs == participantIDs)
                && Set(plan.participantNames ?? []).isSubset(of: participantNames)
            let matchesScope = [rawQuestion, question].allSatisfy {
                ReadingContinuationPolicy.scopeChange(question: $0, run: current, profiles: profiles, selfProfileID: selfProfileID) == .none
            }
            if matchesParticipants, matchesScope {
                base = current
                plan.subject = current.input.subject
                plan.participantIDs = current.input.readingParticipants.map(\.id)
                plan.participantNames = current.input.readingParticipants.map(\.participantLabel)
            } else if (understanding.relation == .continuation || plan.action == "reply")
                        && !ReadingContinuationPolicy.explicitlyRequestsNewReading(rawQuestion) {
                // A rejected reference/scope must stay rejected when the
                // execution policy is applied again by this store.
                plan.understanding?.relation = .ambiguous
                plan.action = "clarify"
                plan.note = ""
                plan.mandatoryMethods = []
                plan.profileUpdates = []
                return nil
            }
        }
        if base == nil, plan.action == "supplement" {
            plan.action = "intake"
            plan.followUpQuestion = nil
        }
        if base == nil { plan.tarotClarification = nil }
        if understanding.relation == .continuation, let reference, reference.run == nil {
            let knownPeople = profiles + references.flatMap { $0.run?.input.readingParticipants ?? [] }
            let expandedNames = Set(ProfileDirectory.referencedNames(in: question, profiles: knownPeople))
            let citedQuestion = reference.resolvedQuestion ?? reference.excerpt
            let groundedNames = Set([rawQuestion, citedQuestion, reference.excerpt].flatMap {
                ProfileDirectory.referencedNames(in: $0, profiles: knownPeople)
            })
            if !expandedNames.isSubset(of: groundedNames) {
                // Keep the referenced topic without importing an ungrounded person.
                let language = EnglishConversation.replyLanguage(in: rawQuestion) ?? AppLanguage.current
                return L10n.text("接着前面「\(citedQuestion)」这件事回答本轮「\(rawQuestion)」。",
                                 "Continue the earlier topic “\(citedQuestion)” and answer this request: “\(rawQuestion)”.",
                                 language: language)
            }
        }
        return question.isEmpty ? nil : question
    }

    private func clarifyReadingExecution(_ note: String?) {
        let text = note?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        messages.append(ChatMessage(role: .assistant, content: text.isEmpty ? L10n.text(
            "这次想沿用已有结果，还是按新的问题重新推演？", "Would you like to use the saved reading or start a new reading for this question?") : text))
        activityMessageID = messages.last?.id
        progress(L10n.text("等待确认本次所问", "Waiting for you to confirm the question"), state: .waiting)
        finishOperation()
    }

    private func prepareContext(operation: UUID, language: AppLanguage) async {
        guard operationID == operation, !Task.isCancelled else { return }
        guard ContextCompressor.shouldCompress(messages: messages, summary: summary) else { return }
        progress(L10n.text("整理此前对话与已确认资料", "Reviewing earlier messages and confirmed details"))
        if !usesTestAgent {
            do {
                let newSummary = try await AIQuotaTaskScope.$stage.withValue(quotaStage("summary:" + (activityMessageID ?? activeConversationID).uuidString.lowercased()), operation: {
                    try await ContextCompressor.compact(messages: self.messages, summary: self.summary, using: self.client, language: language)
                })
                if let newSummary {
                    guard operationID == operation, !Task.isCancelled else { return }
                    summary = newSummary; persist(); return
                }
            } catch { if Task.isCancelled { return } }
        }
        guard operationID == operation, !Task.isCancelled else { return }
        #if DEBUG
        if usesTestAgent { summary = LocalContextPolicy.compact(messages: messages, previous: summary); persist() }
        #endif
    }

    @discardableResult func confirmIntake(profile submittedProfile: OracleProfile, numbers: [Int], save: Bool,
                                        castingProfile: OracleProfile? = nil) -> Bool {
        confirmGroupIntake(profiles: [submittedProfile], numbers: numbers, save: save, castingProfile: castingProfile)
    }
    @discardableResult func confirmGroupIntake(profiles submittedProfiles: [OracleProfile], numbers submittedNumbers: [Int], save: Bool,
                                               castingProfile: OracleProfile? = nil, sessionID: UUID? = nil) -> Bool {
        guard var plan = pendingPlan, !isBusy,
              sessionID == nil || sessionID == intakeSessionID else { return false }
        if discardMissingSupplement() { persist(); return false }
        if let baseID = plan.baseRunID, let base = runs.first(where: { $0.id == baseID }) {
            retainConfirmedTwoNumberMode(in: &plan, base: base, numbers: submittedNumbers)
        }
        initializeCastingProfile(in: &plan)
        if let castingProfile { plan.castingProfile = CastingLocationDraft(profile: castingProfile).profile }
        var seen = Set<UUID>()
        let participants = submittedProfiles.filter { seen.insert($0.id).inserted }
            .map(ProfileDirectory.assigningDefaultBirthTimeZone(to:))
        let numbers = castingNumbers(for: plan, supplied: submittedNumbers)
        plan.draftParticipants = participants; plan.draftNumbers = numbers
        pendingPlan = plan
        var issues: [String] = []
        if plan.subject == "多人", plan.methods.contains(where: \.usesPersonalProfile), participants.count < 2 {
            issues.append(L10n.text("请至少添加两位参与人。每位的资料都可以留空。", "Add at least two participants. You can leave their details blank."))
        }
        let report = ReadingPreparationPolicy.evaluate(plan: plan, participants: participants, descriptors: registry.descriptors,
                                                       castingProfile: plan.castingProfile, numbers: numbers)
        if !report.canProceed {
            for assessment in report.assessments {
                let owner = assessment.participantName.map { $0 + "：" } ?? ""
                issues += assessment.blocking.map { issue in
                    L10n.text(owner + assessment.method.progressName + "需要" + issue.field.title + "：" + issue.reason,
                              owner + assessment.method.progressName + " requires " + issue.field.title + ". " + issue.reason)
                }
                if let reason = assessment.unavailableReason { issues.append(reason) }
            }
            if issues.isEmpty { issues.append(L10n.text("现有资料还不足以按这次要求推演，请补充标明的必要信息。", "Add the required details marked on the form to start this reading.")) }
        }
        let awaitsNumbers = ReadingPreparationPolicy.awaitsNumberInteraction(plan: plan, numbers: numbers)
        if !awaitsNumbers, !numbers.isEmpty,
           (![2, 3].contains(numbers.count) || !numbers.allSatisfy({ (1...999).contains($0) })) {
            issues.append(L10n.text("所留数字尚未有效，请在留数环节重新确认。", "Review the numbers in the number-selection step before continuing."))
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
        messages.append(ChatMessage(role: .user, content: L10n.text("已核对问事资料，开始推演。", "I’ve reviewed the details. Start the reading.")))
        let legacyStyle = ["蓍草", "大衍"].contains { plan.question.contains($0) }
            || EnglishConversation.matches(plan.question, #"\byarrow(?: stalks?)?\b"#) ? "yarrow" : "coins"
        let style = plan.liuyaoCastingMode?.rawValue ?? legacyStyle
        var input: OracleInput
        if let baseID = plan.baseRunID, let base = runs.first(where: { $0.id == baseID }) {
            input = supplementInput(base: base, plan: plan, participants: participants, numbers: numbers)
        } else {
            input = OracleInput(question: plan.question, profile: participants.first ?? OracleProfile(), numbers: numbers,
                                subject: plan.subject, castingStyle: style, participants: participants, relationship: plan.relationship)
            if let casting = plan.castingProfile { input.profile = CastingLocationDraft.applying(casting, to: input.profile) }
        }
        if !awaitsNumbers, !numbers.isEmpty {
            input.profile.unknownFields.remove(.numbers)
            input.profile.declaredUnknownFields?.remove(.numbers)
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
            messages[index].content = L10n.text("这轮补牌已取消，你可以继续问原来的牌阵。", "The clarifying draw was canceled. You can still ask about the original spread.")
        }
        progress(L10n.text("已取消本轮补牌", "Clarifying draw canceled"), state: .cancelled)
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
            notice = L10n.text("原推演记录已删除，无法继续这次补充推演。", "The original reading was deleted, so this follow-up cannot continue.")
            progress(L10n.text("补充推演已取消", "Follow-up reading canceled"), state: .cancelled); finishOperation(); return
        }
        let base = plan.baseRunID.flatMap { id in runs.first { $0.id == id } }
        let reused = isTarotClarification ? (base?.results ?? []).filter { $0.method != .tarot }
            : reusableResults(input: input, plan: plan)
        let run = OracleRun(input: input, plan: plan, results: reused,
                            reusedResultIDs: plan.baseRunID == nil ? nil : reused.map(\.id))
        activityRunID = run.id
        runs.append(run); showIntake = false; pendingPlan = nil
        if let index = messages.lastIndex(where: { $0.kind == .intake && $0.runID == nil && $0.deletedRunID == nil }) {
            messages[index].runID = run.id
            activityMessageID = messages[index].id
            if isTarotClarification { messages[index].content = L10n.text("补牌已保存，正在结合全部牌面解读。", "The clarifying card is saved. I’m reading the cards together.") }
            else { messages[index].content = plan.baseRunID == nil ? L10n.text("问事笺已收好。稍坐，我替你理一理。", "I have the details. Give me a moment to work through them.") : L10n.text("已有结果继续沿用，只补充新增或条件变化的部分。", "I’ll keep the existing results and update the parts affected by the new details.") }
        }
        if !reused.isEmpty {
            progress(L10n.text("沿用已完成的推演结果", "Using completed results"), detail: reused.map { $0.displayTitle }.joined(separator: L10n.text("、", ", ")), state: .completed)
        }
        calculateReading(run)
    }

    private func calculateReading(_ run: OracleRun) {
        quotaTaskID = quotaTaskID ?? run.plan.quotaTaskID ?? UUID()
        if let index = runs.firstIndex(where: { $0.id == run.id }) { runs[index].plan.quotaTaskID = quotaTaskID }
        let input = run.input
        let plan = run.plan
        let isTarotClarification = input.tarotClarificationRounds?.last.map { round in
            plan.tarotClarification == TarotClarificationSuggestion(focus: round.request.focus, originalPosition: round.request.originalPosition)
                && (round.request.question == nil || plan.followUpQuestion == round.request.question)
        } ?? false
        let unchanged = isTarotClarification ? run.results.filter { $0.method != .tarot } : []
        let reusable = run.results.filter {
            ($0.status == .complete || $0.status == .partial) && (!isTarotClarification || $0.method == .tarot)
        }
        if let index = runs.firstIndex(where: { $0.id == run.id }) { runs[index].results = unchanged + reusable }
        analysisAttempt = .reading(runID: run.id, messageID: activityMessageID, needsCalculation: true)
        phase = .calculating
        progress(L10n.text("核对资料与已确认的选择", "Checking details and confirmed choices"))
        let operation = UUID(); operationID = operation; persist()
        let conversationID = activeConversationID
        task = Task { [weak self] in
            guard let self else { return }
            let results = await registry.calculate(input, methods: isTarotClarification ? [.tarot] : plan.methods,
                omissions: isTarotClarification ? [] : plan.omittedMethods ?? [], onParticipantStart: { [weak self] method, person, index, total in
                await self?.beginMethod(method, person: person, index: index, total: total, runID: run.id, operation: operation, conversationID: conversationID)
            }, reusedResults: reusable, onProgress: { [weak self] result in
                await self?.receive(result, for: run.id, operation: operation)
            })
            guard operationID == operation, !Task.isCancelled else { return }
            let allResults = unchanged + results
            if let index = runs.firstIndex(where: { $0.id == run.id }) { runs[index].results = allResults }
            if !allResults.contains(where: { $0.status == .complete || $0.status == .partial }),
               allResults.contains(where: { $0.status == .failed }) {
                failAnalysis(L10n.text("本次推演暂未完成", "The calculation couldn’t finish"))
                return
            }
            await synthesize(runID: run.id, operation: operation)
        }
    }
    private func beginMethod(_ method: OracleMethod, person: OracleProfile?, index: Int, total: Int, runID: UUID, operation: UUID, conversationID: UUID) {
        guard operationID == operation, activeConversationID == conversationID,
              runs.contains(where: { $0.id == runID }), !Task.isCancelled else { return }
        let name = person?.participantLabel ?? ""
        progress(L10n.text("正在推演\(name.isEmpty ? "" : name + "的")\(method.progressName)", "Calculating \(method.progressName)\(name.isEmpty ? "" : " for " + name)"), detail: L10n.text("第 \(index) 项，共 \(total) 项推演", "Calculation \(index) of \(total)"), method: method)
    }
    private func receive(_ result: OracleResult, for runID: UUID, operation: UUID) {
        guard operationID == operation, let index = runs.firstIndex(where: { $0.id == runID }) else { return }
        runs[index].results.append(result)
        finishActivity(status: result.status == .failed ? .failed : .completed)
        let detail = result.status == .unavailable ? L10n.text("资料不足，此项不参与解读。", "This method was skipped because required details were missing.") : L10n.text("\(result.rows.count) 项盘面数据 · \(result.evidence.count) 条规则线索", "\(result.rows.count) data points · \(result.evidence.count) rule references")
        progress(L10n.text("整理\(result.participantName.map { $0 + "的" } ?? "")\(result.method.progressName)结果", "Preparing \(result.method.progressName) results\(result.participantName.map { " for " + $0 } ?? "")"), detail: detail, method: result.method,
                 state: result.status == .failed ? .failed : .completed)
        persist()
    }
    func retrySynthesis(_ run: OracleRun) {
        guard !isBusy, let current = runs.first(where: { $0.id == run.id }) else { return }
        guard pendingInteraction == nil else { notice = L10n.text("请先完成当前选择，再继续解读。", "Finish your current selection to continue."); return }
        if analysisAttempt?.runID == run.id { retryAnalysis(); return }
        resumeReading(current, messageID: nil, needsCalculation: false)
    }
    private func resumeReading(_ run: OracleRun, messageID: UUID?, needsCalculation: Bool) {
        if run.completedAt == nil { quotaTaskID = run.plan.quotaTaskID ?? quotaTaskID ?? UUID() }
        else if analysisAttempt?.runID != run.id { quotaTaskID = UUID() }
        beginActivitySession(); notice = nil; activityRunID = run.id
        activityMessageID = messageID
        progress(L10n.text("沿用已保存的推演结果", "Using saved results"), detail: run.results.map { $0.method.progressName }.joined(separator: L10n.text("、", ", ")), state: .completed)
        if needsCalculation { calculateReading(run); return }
        analysisAttempt = .reading(runID: run.id, messageID: messageID, needsCalculation: false)
        phase = .synthesizing
        let operation = UUID(); operationID = operation; persist()
        task = Task { [weak self] in await self?.synthesize(runID: run.id, operation: operation, replyID: messageID) }
    }
    private func synthesize(runID: UUID, operation: UUID, replyID: UUID? = nil) async {
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
        let messageID: UUID
        if let replyID, let index = messages.firstIndex(where: { $0.id == replyID && $0.kind == .reading }) {
            messageID = replyID
            messages[index].content = ""
        } else {
            messageID = UUID()
            messages.append(ChatMessage(id: messageID, role: .assistant, content: "", kind: .reading, runID: runID))
        }
        activityMessageID = messageID
        analysisAttempt = .reading(runID: runID, messageID: messageID, needsCalculation: false)
        let transcript = messages.prefix { $0.id != messageID }.filter {
            !(run.plan.baseRunID == nil && $0.role == .user && ReadingContinuationPolicy.isBareRecastRequest($0.content))
        }
        let replyLanguage = EnglishConversation.replyLanguage(in: run.plan.followUpQuestion ?? run.input.question) ?? AppLanguage.current
        let history: [AIConversationTurn]
        if run.plan.baseRunID == nil, let boundary = transcript.lastIndex(where: {
            $0.deletedRunID != nil || ($0.runID != nil && $0.runID != runID)
        }) {
            // A new reading has its own people and inputs. Its synthesis should
            // see the new question and confirmations, without older readings.
            history = ContextCompressor.history(messages: Array(transcript.suffix(from: transcript.index(after: boundary))), summary: .init(), language: replyLanguage)
        } else {
            history = ContextCompressor.history(messages: Array(transcript), summary: summary, language: replyLanguage)
        }
        progress(L10n.text("准备解读已保存的结果", "Preparing to interpret the saved results"))
        persist()
        var synthesis: ReadingSynthesis
        do {
            synthesis = try await requestAgentReading(run, history: history, language: replyLanguage,
                                                     messageID: messageID, operation: operation)
        } catch {
            guard operationID == operation, !Task.isCancelled else { return }
            failAnalysis(L10n.text("解读暂未完成，结果已保留", "Reading interrupted. Results saved."), error: error)
            return
        }
        guard operationID == operation, !Task.isCancelled else { return }
        if let notes = run.plan.preparationNotes, !notes.isEmpty {
            let missing = notes.filter { !synthesis.text.contains($0) }
            if !missing.isEmpty { synthesis.text += L10n.text("\n\n资料说明：", "\n\nNotes on the available details:\n", language: replyLanguage) + missing.joined(separator: "\n") }
        }
        if let index = messages.firstIndex(where: { $0.id == messageID }) {
            messages[index].content = synthesis.text
            if latestRun?.id == runID, ReadingContextBuilder.canSuggestTarotClarification(for: run),
               let offer = synthesis.tarotClarification, offer.isValid {
                messages[index].tarotClarificationOffer = offer
            }
        }
        if let index = runs.firstIndex(where: { $0.id == runID }) { runs[index].synthesis = synthesis; runs[index].completedAt = Date() }
        progress(L10n.text("解读已完成", "Reading complete"), state: .completed)
        finishOperation()
    }
    private func requestAgentReading(_ run: OracleRun, history: [AIConversationTurn], language: AppLanguage,
                                     messageID: UUID, operation: UUID) async throws -> ReadingSynthesis {
        #if DEBUG
        if usesTestAgent {
            return testAgentReading(run, reason: L10n.text("这次推演已完成。", "Your reading is ready.", language: language), language: language)
        }
        #endif
        return try await AIQuotaTaskScope.$stage.withValue(quotaStage("answer")) {
        try await client.synthesize(run: run, history: history, language: language,
                                           voice: OracleVoiceStyle.current, onProgress: { [weak self] stage in
            await self?.readingProgress(stage, runID: run.id, operation: operation)
        }) { [weak self] delta in
            await self?.appendStreamDelta(delta, to: messageID, operation: operation)
        }
        }
    }

    private func readingProgress(_ stage: AIReadingProgress, runID: UUID, operation: UUID) {
        guard operationID == operation, let run = runs.first(where: { $0.id == runID }), !Task.isCancelled else { return }
        var seen = Set<OracleMethod>()
        let methods = run.results.filter { ($0.status == .complete || $0.status == .partial) && seen.insert($0.method).inserted }.map { $0.method.progressName }
        switch stage {
        case .preparing: progress(L10n.text("汇集各项推演结果", "Gathering results"), detail: methods.joined(separator: L10n.text("、", ", ")))
        case .requesting:
            let people = run.input.readingParticipants.map(\.participantLabel)
            if people.count > 1 {
                progress(L10n.text("综合解析\(people.prefix(3).joined(separator: "、"))的关系", "Reading the relationship between \(people.prefix(3).joined(separator: ", "))"), detail: methods.joined(separator: L10n.text("、", ", ")))
                return
            }
            let names = methods.prefix(2).joined(separator: L10n.text("、", ", ")) + (methods.count > 2 ? L10n.text("等", ", and more") : "")
            progress(methods.count == 1 ? L10n.text("正在解读\(names)结果", "Interpreting \(names) results") : L10n.text("综合解析\(names)结果", "Combining \(names) results"),
                     detail: L10n.text("结合问题、已保存结果与资料限制生成解读。", "Using your question, saved results, and available details."))
        case .writing: progress(L10n.text("正在整理中文解读", "Writing the reading"))
        case .validating: progress(L10n.text("核对解读与分歧说明", "Reviewing the reading and any differing interpretations"))
        }
    }
    #if DEBUG
    private func testAgentReading(_ run: OracleRun, reason: String, language: AppLanguage = .current) -> ReadingSynthesis {
        func sourceText(_ value: String) -> String {
            guard language.isEnglish, EnglishConversation.matches(value, #"\p{Han}"#) else { return value }
            return "Saved source text (original language)\n\n" + value
        }
        let eligible = run.results.filter { $0.status == .complete || $0.status == .partial }
        if let round = run.input.tarotClarificationRounds?.last,
           let tarot = eligible.first(where: { $0.method == .tarot }) {
            let statements = tarot.evidence.map(\.statement).joined(separator: "\n\n")
            let focus = L10n.text("本轮补牌 · \(round.request.focus)", "Clarifying card · \(round.request.focus)", language: language)
            return ReadingSynthesis(text: [reason, focus, sourceText([tarot.headline, statements].filter { !$0.isEmpty }.joined(separator: "\n\n"))].filter { !$0.isEmpty }.joined(separator: "\n\n"))
        }
        let statements = eligible.flatMap(\.evidence).map(\.statement)
        var seen = Set<String>()
        let unique = statements.filter { seen.insert($0).inserted }
        let body = unique.isEmpty ? L10n.text("现有资料还不足以给出完整判断。点这条回复下方的「翻看数据」可以查看现有结果。", "There isn’t enough information for a full reading. Tap View Reading below this reply to see what’s available.", language: language) : sourceText(String(unique.prefix(5).joined(separator: "\n\n").prefix(900)))
        let uncertainty = eligible.contains { !$0.limitations.isEmpty } ? L10n.text("\n\n有些资料或规则仍有限制，未确定的部分先留白。", "\n\nSome details or rules are limited, so parts of this reading remain uncertain.", language: language) : ""
        return ReadingSynthesis(text: reason + "\n\n" + body + uncertainty)
    }
    #endif
    private func answerFollowUp(_ question: String, history: [AIConversationTurn], operation: UUID,
                                run: OracleRun?, tarotOffer: TarotClarificationSuggestion? = nil,
                                retryReplyID: UUID? = nil, resolvedQuestion: String? = nil) async {
        guard operationID == operation, !Task.isCancelled else { return }
        let citedQuestion: String?
        switch analysisAttempt {
        case let .planning(questionID), let .followUp(questionID, _, _, _):
            let transcript = Array(messages.prefix { $0.id != questionID })
            let referenceID = messages.first { $0.id == questionID }?.referenceMessageID
            let reference = referenceID.flatMap { id in
                ConversationPlanningReference.candidates(in: transcript, runs: runs).first { $0.messageID == id }
            }
            citedQuestion = reference.map { $0.resolvedQuestion ?? $0.excerpt }
        default:
            citedQuestion = nil
        }
        let messageID: UUID
        if let retryReplyID, let index = messages.firstIndex(where: { $0.id == retryReplyID }) {
            messageID = retryReplyID
            messages[index].content = ""
        } else {
            messageID = UUID()
            messages.append(ChatMessage(id: messageID, role: .assistant, content: "", runID: run?.id,
                                        resolvedQuestion: resolvedQuestion))
        }
        if case let .planning(questionID) = analysisAttempt {
            analysisAttempt = .followUp(questionID: questionID, replyID: messageID, runID: run?.id, tarotOffer: tarotOffer)
        }
        phase = .synthesizing
        activityMessageID = messageID
        progress(run == nil ? L10n.text("结合已确认资料生成回答", "Answering with the confirmed details") : L10n.text("沿用已有卦象，解答追问", "Answering with the saved reading"))
        persist()
        let replyLanguage = EnglishConversation.replyLanguage(in: question) ?? AppLanguage.current
        #if DEBUG
        if usesTestAgent {
            let reason = L10n.text("沿用这次已保存的卦象。", "Using your saved reading.", language: replyLanguage)
            let text = run.map { testAgentReading($0, reason: reason, language: replyLanguage).text }
                ?? L10n.text("说说你想看的具体事情。", "Tell me what you would like to explore.", language: replyLanguage)
            if let index = messages.firstIndex(where: { $0.id == messageID }) { messages[index].content = text }
            progress(run == nil ? L10n.text("等待具体问题", "Waiting for a specific question") : L10n.text("已有结果已保留", "Previous results saved"), state: .completed)
            finishOperation(); return
        }
        #endif
        do {
            let text = try await AIQuotaTaskScope.$stage.withValue(quotaStage("answer")) {
            try await client.followUp(question: question, run: run, profile: profile, history: history,
                                                resolvedQuestion: resolvedQuestion, citedQuestion: citedQuestion,
                                                preparationContext: pendingPreparationContext(), language: replyLanguage, voice: OracleVoiceStyle.current) { [weak self] delta in
                await self?.appendStreamDelta(delta, to: messageID, operation: operation, followUp: true)
            }
            }
            guard operationID == operation, !Task.isCancelled else { return }
            if let index = messages.firstIndex(where: { $0.id == messageID }) {
                messages[index].content = text
                let declines = EnglishConversation.declinesClarifier(question) || question.range(of: #"(?:不要|不用|无需|不必|别|不想).{0,6}(?:补抽|加抽|追加|补牌|补一张|抽牌|再抽)"#, options: .regularExpression) != nil
                if let run, ReadingContextBuilder.canSuggestTarotClarification(for: run), !declines, let tarotOffer, tarotOffer.isValid {
                    messages[index].tarotClarificationOffer = tarotOffer
                }
            }
        } catch {
            guard operationID == operation, !Task.isCancelled else { return }
            failAnalysis(L10n.text("补充回答暂未完成", "The follow-up couldn’t finish"), error: error)
            return
        }
        progress(L10n.text("补充回答已完成", "Follow-up complete"), state: .completed)
        finishOperation()
    }

    private func appendStreamDelta(_ delta: String, to messageID: UUID, operation: UUID, followUp: Bool = false) {
        guard operationID == operation, !Task.isCancelled,
              let index = messages.firstIndex(where: { $0.id == messageID }) else { return }
        if followUp, messages[index].content.isEmpty { progress(L10n.text("正在整理补充回答", "Writing a follow-up")) }
        messages[index].content += delta
    }

    func retryAnalysis() {
        guard canRetryAnalysis, let attempt = analysisAttempt else { return }
        switch attempt {
        case let .planning(questionID):
            guard let question = messages.first(where: { $0.id == questionID }) else { return }
            planQuestion(question)
        case let .followUp(questionID, replyID, runID, tarotOffer):
            guard let index = messages.firstIndex(where: { $0.id == questionID }) else { return }
            let question = messages[index]
            let run = runID.flatMap { id in runs.first { $0.id == id } }
            let language = EnglishConversation.replyLanguage(in: question.content) ?? AppLanguage.current
            let history = ContextCompressor.history(messages: Array(messages.prefix(upTo: index)), summary: summary, language: language)
            beginActivitySession(); notice = nil; activityMessageID = replyID
            let operation = UUID(); operationID = operation; phase = .synthesizing
            task = Task { [weak self] in
                await self?.answerFollowUp(question.content, history: history, operation: operation, run: run,
                                           tarotOffer: tarotOffer, retryReplyID: replyID, resolvedQuestion: question.resolvedQuestion)
            }
        case let .reading(runID, messageID, needsCalculation):
            guard let run = runs.first(where: { $0.id == runID }) else { return }
            resumeReading(run, messageID: messageID, needsCalculation: needsCalculation)
        }
    }

    private func quotaStage(_ name: String) -> AIQuotaStage {
        if quotaTaskID == nil { quotaTaskID = UUID(); persist() }
        return AIQuotaStage(taskID: quotaTaskID!, stageID: name, conversationID: activeConversationID)
    }
    private func finishOperation(keepRetry: Bool = false) {
        task = nil; operationID = nil
        let pendingID = pendingPlan?.quotaTaskID ?? pendingInteraction?.plan.quotaTaskID
        let completedID = !keepRetry && activities.last?.status != .waiting && pendingID != quotaTaskID ? quotaTaskID : nil
        if !keepRetry { analysisAttempt = nil }
        if completedID != nil { quotaTaskID = nil }
        if let completedID { quotaEndIntents[completedID.uuidString.lowercased()] = "completed" }
        phase = waitingPhase
        let saved = persist()
        if saved, completedID != nil, !usesTestAgent { Task { await flushQuotaEnds() } }
    }
    func flushQuotaEnds() async {
        guard !usesTestAgent else { return }
        let service = quotaEndService ?? AIQuotaTaskService.shared
        var changed = false
        for (key, status) in quotaEndIntents {
            guard let id = UUID(uuidString: key) else { continue }
            await service.end(id, status: status)
            if !(await service.containsTask(id)) { quotaEndIntents.removeValue(forKey: key); changed = true }
        }
        if changed { persist() }
    }

    private func failAnalysis(_ text: String, error: Error? = nil) {
        if let error, case DeepSeekError.http(402) = error { requiresTopUp = true }
        notice = error?.localizedDescription
        finishActivity(status: .failed)
        progress(text, state: .failed)
        fillEmptyActiveReply(with: text)
        finishOperation(keepRetry: true)
    }

    private func fillEmptyActiveReply(with text: String) {
        if let index = messages.firstIndex(where: { $0.id == activityMessageID && $0.role == .assistant && $0.content.isEmpty }) {
            messages[index].content = text
        }
    }
    func stop() {
        interruptAnalysis(backgroundExpired: false)
    }
    func suspendAnalysisForBackgroundExpiration() {
        interruptAnalysis(backgroundExpired: true)
    }
    private func interruptAnalysis(backgroundExpired: Bool) {
        guard isBusy else { return }
        task?.cancel()
        operationID = nil
        finishActivity(status: .cancelled)
        let text = backgroundExpired
            ? L10n.text("后台解读已中断，可重试", "The background reading was interrupted. You can retry.")
            : L10n.text("已停下，已有资料与结果仍保留", "Stopped. Your details and results are saved.")
        progress(text, state: .cancelled)
        fillEmptyActiveReply(with: text)
        exposeInterruptedTarotReading()
        finishOperation(keepRetry: true)
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
            run.synthesis = ReadingSynthesis(text: "第\(index)份测试解读。")
            if index == 10, ProcessInfo.processInfo.arguments.contains("--ui-testing-archived-conflicts") {
                run.synthesis?.archivedConflictDetails = "原记录分歧：一处倾向先推进，另一处倾向先核对条件。"
            }
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
        let savedQuestion = "已保存的旧推演"
        let savedPlan = OraclePlan(intent: savedQuestion, subject: "事件", methods: [.xiaoliuren], requiredFields: [], note: "", question: savedQuestion)
        var savedRun = OracleRun(input: OracleInput(question: savedQuestion, profile: OracleProfile(), seed: 42), plan: savedPlan,
                                 results: [OracleResult(method: .xiaoliuren, headline: "已保存的旧结果", rows: [.init("建议", "先核对条件")])])
        savedRun.synthesis = ReadingSynthesis(text: "这是已经完成并保存的解读。")
        savedRun.completedAt = Date()
        runs.append(savedRun)
        for index in 1...3 {
            messages.append(ChatMessage(role: .user, content: "第\(index)次问事：接下来如何安排手头的计划？"))
            let paragraph = "先把手头的事情排出轻重，把需要确认的信息写下来。推进之前，留一点时间核对现实条件，再决定下一步。"
            messages.append(ChatMessage(role: .assistant, content: Array(repeating: paragraph, count: 3).joined(separator: "\n\n"), kind: index == 1 ? .reading : .text, runID: index == 1 ? savedRun.id : nil))
        }
        let question = ChatMessage(role: .user, content: "请结合八字和紫微斗数，看看未来一个月的工作节奏。")
        messages.append(question)
        let messageID = UUID()
        messages.append(ChatMessage(id: messageID, role: .assistant, content: ""))
        activityMessageID = messageID
        analysisAttempt = .followUp(questionID: question.id, replyID: messageID, runID: nil, tarotOffer: nil)
        let titles = [L10n.text("理解问题与确认询问对象", "Understanding the question and who it concerns"), L10n.text("选择适用方法与所需资料", "Choosing methods and checking what details they need"), "核对资料与已确认的交互结果",
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
        persist()
        guard !paused else { return }
        task = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(10))
                guard let self, self.operationID == operation, !Task.isCancelled else { return }
                progress(L10n.text("正在整理中文解读", "Writing the reading"))
                if let index = messages.firstIndex(where: { $0.id == messageID }) {
                    messages[index].content = "接下来可以先稳住手头的安排，再逐步推进新的计划。把尚未确定的条件留出来核实，能让选择更从容。"
                }
                try await Task.sleep(for: .seconds(6))
                guard operationID == operation, !Task.isCancelled else { return }
                progress(L10n.text("解读已完成", "Reading complete"), state: .completed)
                finishOperation()
            } catch { }
        }
    }
    #endif
}

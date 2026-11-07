import SwiftUI

struct ChatView: View {
    @EnvironmentObject private var store: OracleStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Binding var draft: String
    @State private var showHistory = false
    @State private var topUpPresented = false
    @State private var aiConsentPresented = false
    @State private var pendingConsentSubmission = false
    @State private var resumeSubmissionAfterConsent = false
    @State private var checkingAIConsent = false
    @State private var selectedReading: ReadingReference?
    @State private var inspectingActivities = false
    @State private var followsLatest = true
    @FocusState private var composing: Bool
    private let suggestions = [L10n.text("最近的工作，该进还是该守？", "Is it time to make a move at work, or should I stay put?"), L10n.text("这段关系，我该如何往前走？", "How should I move forward in this relationship?"), L10n.text("心里有件事，想听一句建议。", "Something’s on my mind. Can you offer some advice?")]

    var body: some View {
        NavigationStack {
            ZStack {
                PaperBackground()
                VStack(spacing: 0) {
                  ScrollViewReader { proxy in
                    ScrollView {
                        VStack(spacing: 26) {
                            if store.messages.isEmpty { welcome }
                            else {
                                HStack(spacing: 10) {
                                    OracleMark(size: 30)
                                    Text(L10n.text("一事一问，慢慢说。 ", "One question at a time. Take your time.")).font(.system(size: 12, design: .serif)).foregroundStyle(InkTheme.secondary)
                                    Spacer()
                                }.padding(.top, 8)
                            }
                            LazyVStack(spacing: 24) {
                                ForEach(store.messages.prefix(activityInsertionIndex)) { message in
                                    messageView(message).id(message.id)
                                }
                                if !store.activities.isEmpty {
                                    OracleProcessingView(activities: store.activities, isBusy: store.isBusy, onExpansionChanged: { expanded in
                                        inspectingActivities = expanded
                                        if !expanded { followsLatest = true }
                                        let sessionID = store.activitySessionID
                                        Task { @MainActor in
                                            await Task.yield()
                                            guard store.activitySessionID == sessionID, inspectingActivities == expanded, selectedReading == nil else { return }
                                            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.22)) {
                                                if expanded { proxy.scrollTo(sessionID, anchor: .top) }
                                                else { proxy.scrollTo("bottom", anchor: .bottom) }
                                            }
                                        }
                                    })
                                        .id(store.activitySessionID)
                                }
                                ForEach(store.messages.dropFirst(activityInsertionIndex)) { message in
                                    messageView(message).id(message.id)
                                }
                            }
                            if let session = store.pendingInteraction, let request = session.currentRequest {
                                interactionCard(request)
                            }
                            if let notice = store.notice {
                                HStack(alignment: .top, spacing: 8) {
                                    Image(systemName: "info.circle")
                                    Text(notice).textSelection(.enabled)
                                    if store.requiresTopUp {
                                        Button(L10n.text("补充额度", "Replenish")) { topUpPresented = true }
                                            .accessibilityIdentifier("chatTopUpEntry")
                                    }
                                    Spacer(minLength: 0)
                                    Button { store.notice = nil } label: { Image(systemName: "xmark") }.accessibilityLabel(L10n.text("收起提示", "Dismiss notice"))
                                }.font(.system(size: 12)).foregroundStyle(InkTheme.secondary).padding(12)
                                    .background(InkTheme.wash.opacity(0.6), in: RoundedRectangle(cornerRadius: 12))
                            }
                            Color.clear.frame(height: 1).id("bottom")
                        }.frame(maxWidth: 720).padding(.horizontal, 24).padding(.bottom, 18).frame(maxWidth: .infinity)
                            .accessibilityHidden(showHistory)
                    }
                    .scrollDismissesKeyboard(.interactively)
                    .modifier(TranscriptEdgeEffect())
                    .contentShape(Rectangle())
                    .simultaneousGesture(TapGesture().onEnded { composing = false })
                    .simultaneousGesture(DragGesture(minimumDistance: 12).onChanged { value in
                        guard abs(value.translation.height) > abs(value.translation.width) else { return }
                        followsLatest = false
                    })
                    .accessibilityIdentifier("chatTranscript")
                    .onAppear {
                        Task { @MainActor in
                            await Task.yield()
                            guard followsLatest, selectedReading == nil else { return }
                            proxy.scrollTo("bottom", anchor: .bottom)
                        }
                    }
                    .onChange(of: store.messages.last?.content) { _, _ in
                        guard followsLatest, !inspectingActivities, selectedReading == nil, !showHistory else { return }
                        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) { proxy.scrollTo("bottom", anchor: .bottom) }
                    }
                    .onChange(of: store.messages.count) { _, _ in
                        guard followsLatest, !inspectingActivities, selectedReading == nil, !showHistory else { return }
                        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.25)) { proxy.scrollTo("bottom", anchor: .bottom) }
                    }
                    .onChange(of: store.activities.last?.id) { _, _ in
                        guard followsLatest, !inspectingActivities, selectedReading == nil, !showHistory else { return }
                        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) { proxy.scrollTo("bottom", anchor: .bottom) }
                    }
                    .onChange(of: store.activitySessionID) { _, _ in inspectingActivities = false }
                    .onChange(of: store.activeConversationID) { _, _ in
                        draft = ""; selectedReading = nil; inspectingActivities = false
                        followsLatest = true
                        Task { @MainActor in
                            await Task.yield()
                            proxy.scrollTo("bottom", anchor: .bottom)
                        }
                    }
                    .onChange(of: store.historyResetID) { _, _ in
                        draft = ""; selectedReading = nil; inspectingActivities = false
                        composing = false; showHistory = false
                        followsLatest = true
                    }
                  }
                  .frame(maxWidth: .infinity, maxHeight: .infinity)
                  .clipped()
                  composer.accessibilityHidden(showHistory)
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        composing = false
                        withAnimation(.spring(response: 0.32, dampingFraction: 0.9)) { showHistory.toggle() }
                    } label: { HistoryMenuIcon().foregroundStyle(InkTheme.ink) }
                    .accessibilityLabel(L10n.text("历史", "History"))
                    .accessibilityIdentifier("historyButton")
                    .accessibilityHidden(showHistory)
                }
                ToolbarItem(placement: .principal) {
                    HStack(spacing: 6) {
                        Text(L10n.text("瞎子", "BlindOracle"))
                            .font(.system(size: 20, weight: .medium, design: .serif))
                            .tracking(AppLanguage.current.isEnglish ? 0.7 : 3)
                            .foregroundStyle(InkTheme.ink)
                            .accessibilityIdentifier("chatTitle")
                        TestEnvironmentBadge()
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { composing = false }
                    .accessibilityHidden(showHistory)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        composing = false
                        pendingConsentSubmission = false
                        aiConsentPresented = true
                    } label: { Image(systemName: "hand.raised").font(.system(size: 16)).foregroundStyle(InkTheme.secondary) }
                        .accessibilityLabel(L10n.text("AI 数据使用", "AI data use"))
                        .accessibilityIdentifier("aiDataSharingSettings")
                        .accessibilityHidden(showHistory)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        composing = false
                        store.newConversation()
                    } label: { Image(systemName: "square.and.pencil").font(.system(size: 17)).foregroundStyle(InkTheme.secondary) }
                        .disabled(store.isBusy || store.messages.isEmpty).accessibilityLabel(L10n.text("开启新对话", "New conversation"))
                        .accessibilityIdentifier("newConversationButton")
                        .accessibilityHidden(showHistory)
                }
            }
            .toolbarBackground(InkTheme.paper, for: .navigationBar).toolbarBackground(.visible, for: .navigationBar)
            .navigationBarTitleDisplayMode(.inline)
            .sheet(isPresented: Binding(get: {
                (store.showIntake || store.showInteraction) && !showHistory && selectedReading == nil
            }, set: { presented in
                if !presented { store.showIntake = false; store.showInteraction = false }
            })) {
                if store.showIntake, let plan = store.pendingPlan {
                    let sessionID = store.intakeSessionID
                    GroupIntakeView(plan: plan, profiles: store.intakeParticipants, numbers: store.intakeNumbers,
                                    castingProfile: store.intakeCastingProfile, onDraftChange: { profiles, numbers, castingProfile in
                        store.saveIntakeDraft(profiles: profiles, numbers: numbers, castingProfile: castingProfile, sessionID: sessionID)
                    }, onConfirm: { profiles, numbers, castingProfile, save in
                        store.confirmGroupIntake(profiles: profiles, numbers: numbers, save: save, castingProfile: castingProfile, sessionID: sessionID)
                    }).id(sessionID)
                } else if let session = store.pendingInteraction {
                    OracleInteractionView(session: session, onProgress: { response in
                        store.saveInteractionProgress(response, sessionID: session.id)
                    }, onComplete: { response in
                        store.completeInteraction(response, sessionID: session.id)
                    }, onCancel: {
                        store.cancelPendingReading()
                    })
                    .id("\(session.id.uuidString)-\(session.currentIndex)")
                    .interactiveDismissDisabled(false)
                }
            }
            .sheet(isPresented: $topUpPresented) { NavigationStack { AccountTopUpView() } }
            .sheet(isPresented: $aiConsentPresented, onDismiss: consentDismissed) {
                AIDataSharingConsentView(onContinue: {
                    resumeSubmissionAfterConsent = pendingConsentSubmission
                }, onDecline: {
                    pendingConsentSubmission = false
                    resumeSubmissionAfterConsent = false
                })
            }
            .sheet(item: $selectedReading) { reference in
                ReadingResultsSheet(runID: reference.id)
            }
        }
        .toolbar(showHistory ? .hidden : .visible, for: .tabBar)
        .onChange(of: store.selectedTab) { _, _ in composing = false }
        .accessibilityHidden(showHistory)
        .overlay {
            if showHistory {
                ConversationHistorySidebar(isPresented: $showHistory)
                    .transition(.opacity)
            }
        }
    }

    private var activityInsertionIndex: Int {
        guard let messageID = store.activityMessageID,
              let index = store.messages.firstIndex(where: { $0.id == messageID }) else { return store.messages.count }
        return store.messages[index].role == .user ? index + 1 : index
    }

    private var welcome: some View {
        VStack(spacing: 0) {
            Text(L10n.text("X I A  Z I", "BLINDORACLE")).font(.system(size: 10, weight: .medium)).tracking(2)
                .foregroundStyle(InkTheme.secondary.opacity(0.8)).padding(.top, 35)
            Image("OraclePortrait").resizable().scaledToFit().frame(width: 220, height: 220)
                .blendMode(.multiply)
                .mask { RadialGradient(stops: [.init(color: .black, location: 0), .init(color: .black, location: 0.68), .init(color: .clear, location: 1)], center: .center, startRadius: 0, endRadius: 120) }
                .padding(.top, 18).accessibilityLabel(L10n.text("水墨绘制的瞎子", "Ink portrait of the Oracle"))
            Text(L10n.text("问一事，听一言。", "Ask a question. Hear a thought."))
                .font(.system(size: 27, weight: .regular, design: .serif)).tracking(AppLanguage.current.isEnglish ? 0 : 3)
                .foregroundStyle(InkTheme.ink).multilineTextAlignment(.center).padding(.top, 10)
            Text(L10n.text("坐吧。把心里那件事，说给我听。", "Take a seat. Tell me what’s on your mind."))
                .font(.system(size: 14, design: .serif)).foregroundStyle(InkTheme.secondary)
                .multilineTextAlignment(.center).padding(.top, 14)
            HStack(spacing: 12) {
                Rectangle().fill(InkTheme.line).frame(width: 30, height: 0.6)
                Text(L10n.text("此刻 · 此地 · 此问", "This moment · This place · This question")).font(.system(size: 10))
                    .tracking(AppLanguage.current.isEnglish ? 0.6 : 3).multilineTextAlignment(.center)
                    .foregroundStyle(InkTheme.secondary)
                Rectangle().fill(InkTheme.line).frame(width: 30, height: 0.6)
            }.padding(.top, 30).padding(.bottom, 24)
            VStack(spacing: 0) {
                ForEach(Array(suggestions.enumerated()), id: \.offset) { index, item in
                    Button { draft = item; submit() } label: {
                        HStack(spacing: 14) {
                            Text(InkTheme.stepNumber(at: index)).font(.system(size: 11, design: .serif)).foregroundStyle(InkTheme.cinnabar.opacity(0.7))
                            Text(item).font(.system(size: 14, design: .serif)).foregroundStyle(InkTheme.ink.opacity(0.85))
                            Spacer(minLength: 2)
                            Image(systemName: "arrow.up.left").font(.system(size: 10)).foregroundStyle(InkTheme.secondary.opacity(0.6))
                        }.padding(.vertical, 15)
                    }.buttonStyle(.plain)
                    if index < 2 { Divider().overlay(InkTheme.line.opacity(0.5)) }
                }
            }.padding(.horizontal, 18).background(.white.opacity(0.24), in: RoundedRectangle(cornerRadius: 16))
        }.frame(maxWidth: 430)
    }

    @ViewBuilder private func messageView(_ message: ChatMessage) -> some View {
        if message.role == .assistant, message.content.isEmpty,
           message.id == store.activityMessageID, !store.activities.isEmpty {
            EmptyView()
        } else if message.role == .user {
            HStack {
                Spacer(minLength: 35)
                Text(message.content).font(.system(size: 16, design: .serif)).lineSpacing(6).textSelection(.enabled)
                    .padding(.horizontal, 17).padding(.vertical, 13).foregroundStyle(InkTheme.ink)
                    .background(InkTheme.wash, in: UnevenRoundedRectangle(topLeadingRadius: 18, bottomLeadingRadius: 18, bottomTrailingRadius: 5, topTrailingRadius: 18))
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("userBubble-\(message.id.uuidString)")
        } else {
            HStack(alignment: .bottom, spacing: 0) {
              VStack(alignment: .leading, spacing: 12) {
                if message.content.isEmpty {
                    Text(L10n.text("稍坐片刻…", "One moment…")).font(.system(size: 16, design: .serif)).foregroundStyle(InkTheme.secondary)
                } else {
                    Text(.init(message.content)).font(.system(size: 16, design: .serif)).lineSpacing(6).foregroundStyle(InkTheme.ink).textSelection(.enabled).tint(InkTheme.cinnabar)
                }
                if message.kind == .intake {
                    if message.id == store.pendingIntakeMessageID {
                        intakeCard
                    } else if message.runID != nil {
                        Label(L10n.text("问事笺已确认", "Details confirmed"), systemImage: "checkmark.seal").font(.system(size: 12)).foregroundStyle(InkTheme.sage)
                    }
                }
                if let deletedID = message.deletedRunID {
                    Label(L10n.text("推演记录已删除", "Reading deleted"), systemImage: "trash")
                        .font(.system(size: 11)).foregroundStyle(InkTheme.secondary)
                        .accessibilityIdentifier("deletedReading-\(deletedID.uuidString)")
                }
                if message.role == .assistant, let suggestion = store.tarotClarificationOffer(for: message) {
                    tarotClarificationButton(suggestion, messageID: message.id)
                }
                if message.kind != .intake, let runID = message.runID, !message.content.isEmpty,
                   store.runs.contains(where: { $0.id == runID }) {
                    if message.kind == .reading,
                       let synthesis = store.runs.first(where: { $0.id == runID })?.synthesis,
                       let details = synthesis.archivedConflictDetails?.trimmingCharacters(in: .whitespacesAndNewlines),
                       !details.isEmpty, !message.content.contains(details) {
                        Text(.init(details))
                            .font(.system(size: 16, design: .serif))
                            .lineSpacing(6)
                            .foregroundStyle(InkTheme.ink)
                            .textSelection(.enabled)
                            .tint(InkTheme.cinnabar)
                            .accessibilityIdentifier("archivedConflictDetails-\(message.id.uuidString)")
                    }
                    HStack(spacing: 18) {
                        Button { selectedReading = ReadingReference(id: runID) } label: { Label(L10n.text("翻看数据", "View reading"), systemImage: "books.vertical") }
                            .accessibilityIdentifier("readingData-\(message.id.uuidString)")
                        if !store.isBusy {
                            if let run = store.runs.first(where: { $0.id == runID }), run.synthesis == nil {
                                if !store.canRetryAnalysis(for: message.id) {
                                    Button { store.retrySynthesis(run) } label: { Label(L10n.text("重试解读", "Retry interpretation"), systemImage: "arrow.clockwise") }
                                        .accessibilityIdentifier("retryReading-\(runID.uuidString)")
                                }
                            } else {
                                Button { draft = L10n.text("请结合刚才的结果再详细解释一下，给我更具体的建议。", "Please explain the same reading in more detail and give me some practical advice."); submit() } label: { Label(L10n.text("再细说些", "Explain further"), systemImage: "text.bubble") }
                            }
                        }
                    }.font(.system(size: 11)).foregroundStyle(InkTheme.secondary).padding(.top, 6)
                }
              }
              .padding(.horizontal, 17).padding(.vertical, 13)
              .background(.white.opacity(0.65), in: UnevenRoundedRectangle(topLeadingRadius: 18, bottomLeadingRadius: 5, bottomTrailingRadius: 18, topTrailingRadius: 18))
              .overlay(UnevenRoundedRectangle(topLeadingRadius: 18, bottomLeadingRadius: 5, bottomTrailingRadius: 18, topTrailingRadius: 18).stroke(InkTheme.line.opacity(0.6), lineWidth: 0.6))
              .accessibilityElement(children: .contain)
              .accessibilityIdentifier("assistantBubble-\(message.id.uuidString)")
              Spacer(minLength: 35)
            }
        }
    }

    private func tarotClarificationButton(_ suggestion: TarotClarificationSuggestion, messageID: UUID) -> some View {
        Button {
            composing = false
            store.acceptTarotClarification(messageID: messageID)
        } label: {
            Label(L10n.text("补抽 1 张 · \(suggestion.focus)", "Draw 1 clarifier · \(suggestion.focus)"), systemImage: "rectangle.on.rectangle.angled")
                .font(.system(size: 13, weight: .medium, design: .serif))
                .multilineTextAlignment(.leading)
                .foregroundStyle(InkTheme.cinnabar)
                .padding(.horizontal, 12).padding(.vertical, 8)
                .frame(minHeight: 44, alignment: .leading)
                .background(InkTheme.cinnabar.opacity(0.07), in: RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(L10n.text("补抽一张塔罗牌，澄清\(suggestion.focus)", "Draw a tarot card to clarify \(suggestion.focus)"))
        .accessibilityHint(L10n.text("打开补牌界面，选牌并翻开后确认。", "Opens the card picker. Choose a card, reveal it, and confirm."))
        .accessibilityIdentifier("offerTarotClarification")
    }

    private var intakeCard: some View {
        Button { composing = false; store.confirmPendingIntake() } label: {
            HStack(spacing: 15) {
                Image(systemName: "doc.text").font(.system(size: 25, weight: .ultraLight)).foregroundStyle(InkTheme.cinnabar)
                VStack(alignment: .leading, spacing: 5) {
                    Text(L10n.text("填写问事资料", "Add reading details")).font(.system(size: 17, design: .serif)).foregroundStyle(InkTheme.ink)
                    Text(L10n.text("一次填写并核对，确认后直接开始。", "Review the details, then confirm to begin.")).font(.system(size: 11)).foregroundStyle(InkTheme.secondary)
                }
                Spacer(minLength: 0)
                Image(systemName: "arrow.right").font(.system(size: 13)).foregroundStyle(InkTheme.cinnabar)
            }.padding(19).background(.white.opacity(0.4), in: RoundedRectangle(cornerRadius: 14))
                .overlay(RoundedRectangle(cornerRadius: 14).stroke(InkTheme.line, lineWidth: 0.7))
        }.buttonStyle(.plain).accessibilityIdentifier("openIntake")
    }

    private func interactionCard(_ request: OracleInteractionRequest) -> some View {
        Button { composing = false; store.showInteraction = true } label: {
            HStack(spacing: 15) {
                Image(systemName: request.kind == .tarot ? "rectangle.on.rectangle.angled" : request.kind == .coins ? "circle.grid.2x2" : "number")
                    .font(.system(size: 25, weight: .ultraLight)).foregroundStyle(InkTheme.cinnabar)
                VStack(alignment: .leading, spacing: 5) {
                    if let clarification = request.tarotClarification {
                        Text(L10n.text("继续补牌", "Continue drawing a clarifier"))
                            .font(.system(size: 19, design: .serif)).tracking(2).foregroundStyle(InkTheme.ink)
                        Text(clarification.focus)
                            .font(.system(size: 11)).foregroundStyle(InkTheme.secondary)
                    } else {
                        Text(request.kind == .coins && store.pendingInteraction?.input.castingStyle == "yarrow" ? L10n.text("蓍草成卦", "Cast with yarrow stalks") : request.title)
                            .font(.system(size: 19, design: .serif)).tracking(2).foregroundStyle(InkTheme.ink)
                        Text(L10n.text("慢慢来，已有的进度替你留着。", "Take your time. Your progress is saved.")).font(.system(size: 11)).foregroundStyle(InkTheme.secondary)
                    }
                }
                Spacer(minLength: 0)
                Image(systemName: "arrow.right").font(.system(size: 13)).foregroundStyle(InkTheme.cinnabar)
            }.padding(19).background(.white.opacity(0.55), in: RoundedRectangle(cornerRadius: 14))
                .overlay(RoundedRectangle(cornerRadius: 14).stroke(InkTheme.line, lineWidth: 0.7))
        }.buttonStyle(.plain).accessibilityIdentifier("interactionCard")
    }

    private var composer: some View {
        let hasDraft = !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let stopWithoutSending = store.isBusy && !hasDraft
        let actionEnabled = hasDraft || stopWithoutSending
        let sendLabel = store.isBusy ? L10n.text("停止并发送追问", "Stop and send follow-up") : L10n.text("发送问题", "Send question")
        let stopLabel = L10n.text("停止回答", "Stop reply")
        return VStack(spacing: 8) {
            if store.canRetryAnalysis {
                Button {
                    composing = false
                    store.retryAnalysis()
                } label: {
                    Label(L10n.text("重试", "Retry"), systemImage: "arrow.clockwise")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(InkTheme.cinnabar)
                        .padding(.horizontal, 14)
                        .frame(minHeight: 38)
                        .background(InkTheme.cinnabar.opacity(0.08), in: Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("retryAnalysis")
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack(alignment: .bottom, spacing: 10) {
                TextField(store.isBusy ? L10n.text("想补充什么？", "Add a follow-up…") : L10n.text("说说你想问的事…", "What’s on your mind?"), text: $draft, axis: .vertical).lineLimit(1...5)
                    .font(.system(size: 16, design: .serif)).foregroundStyle(InkTheme.ink).focused($composing)
                    .submitLabel(.send).onSubmit { submit() }.accessibilityIdentifier("questionInput")
                    .padding(.leading, 4).padding(.vertical, 10)
                if store.isBusy && hasDraft {
                    Button { store.stop() } label: {
                        Image(systemName: "stop.fill").font(.system(size: 15, weight: .medium))
                            .foregroundStyle(InkTheme.ink).frame(width: 38, height: 38)
                            .background(InkTheme.wash, in: Circle())
                    }
                    .accessibilityLabel(stopLabel)
                    .accessibilityIdentifier("stopAnswer")
                }
                Button {
                    if stopWithoutSending { store.stop() } else { submit() }
                } label: {
                    Image(systemName: stopWithoutSending ? "stop.fill" : "arrow.up").font(.system(size: 15, weight: .medium))
                        .foregroundStyle(InkTheme.paper).frame(width: 38, height: 38)
                        .background(actionEnabled ? InkTheme.ink : InkTheme.secondary.opacity(0.3), in: Circle())
                }.disabled(!actionEnabled)
                    .accessibilityLabel(stopWithoutSending ? stopLabel : sendLabel)
                    .accessibilityIdentifier("sendQuestion")
            }.padding(.horizontal, 13).padding(.vertical, 8)
                .background(Color(red: 0.982, green: 0.975, blue: 0.959), in: RoundedRectangle(cornerRadius: 22))
                .overlay(RoundedRectangle(cornerRadius: 22).stroke(InkTheme.line, lineWidth: 0.8))
        }.frame(maxWidth: 720).padding(.horizontal, 20).padding(.top, 10).padding(.bottom, 8).frame(maxWidth: .infinity)
            .background {
                InkTheme.paper.ignoresSafeArea(.container, edges: .bottom)
                    .contentShape(Rectangle()).onTapGesture { composing = false }
            }
            .overlay(alignment: .top) { Rectangle().fill(InkTheme.line).frame(height: 0.6) }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("chatComposerPanel")
    }
    private func submit() {
        guard !checkingAIConsent else { return }
        let question = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty else { return }
        checkingAIConsent = true
        Task { @MainActor in
            let authorized = await AIDataSharingConsentStore.shared.isAuthorized()
            checkingAIConsent = false
            if authorized { performSubmit() }
            else {
                pendingConsentSubmission = true
                composing = false
                aiConsentPresented = true
            }
        }
    }

    private func consentDismissed() {
        let shouldSend = resumeSubmissionAfterConsent
        pendingConsentSubmission = false
        resumeSubmissionAfterConsent = false
        guard shouldSend else { return }
        Task { @MainActor in
            guard await AIDataSharingConsentStore.shared.isAuthorized() else { return }
            performSubmit()
        }
    }

    private func performSubmit() {
        let question = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty else { return }
        draft = ""
        composing = false
        followsLatest = true
        store.send(question)
    }
}

private struct ReadingReference: Identifiable { let id: UUID }

private struct TranscriptEdgeEffect: ViewModifier {
    @ViewBuilder func body(content: Content) -> some View {
        if #available(iOS 26.0, *) { content.scrollEdgeEffectHidden(true, for: .bottom) }
        else { content }
    }
}

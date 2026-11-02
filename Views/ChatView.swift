import SwiftUI

struct ChatView: View {
    @EnvironmentObject private var store: OracleStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var draft = ""
    @State private var confirmNew = false
    @State private var showHistory = false
    @State private var selectedReading: ReadingReference?
    @State private var inspectingActivities = false
    @FocusState private var composing: Bool
    private let suggestions = ["最近的工作，该进还是该守？", "这段关系，我该如何往前走？", "心里有件事，想听一句建议。"]

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
                                    Text("一事一问，慢慢说。 ").font(.system(size: 12, design: .serif)).foregroundStyle(InkTheme.secondary)
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
                                        let sessionID = store.activitySessionID
                                        Task { @MainActor in
                                            await Task.yield()
                                            guard store.activitySessionID == sessionID, inspectingActivities == expanded else { return }
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
                                    Spacer(minLength: 0)
                                    Button { store.notice = nil } label: { Image(systemName: "xmark") }.accessibilityLabel("收起提示")
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
                    .accessibilityIdentifier("chatTranscript")
                    .onAppear {
                        Task { @MainActor in
                            await Task.yield()
                            proxy.scrollTo("bottom", anchor: .bottom)
                        }
                    }
                    .onChange(of: store.messages.last?.content) { _, _ in
                        guard !inspectingActivities else { return }
                        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) { proxy.scrollTo("bottom", anchor: .bottom) }
                    }
                    .onChange(of: store.messages.count) { _, _ in
                        guard !inspectingActivities else { return }
                        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.25)) { proxy.scrollTo("bottom", anchor: .bottom) }
                    }
                    .onChange(of: store.activities.last?.id) { _, _ in
                        guard !inspectingActivities else { return }
                        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) { proxy.scrollTo("bottom", anchor: .bottom) }
                    }
                    .onChange(of: store.activitySessionID) { _, _ in inspectingActivities = false }
                    .onChange(of: store.activeConversationID) { _, _ in
                        draft = ""; selectedReading = nil; inspectingActivities = false
                        Task { @MainActor in
                            await Task.yield()
                            proxy.scrollTo("bottom", anchor: .bottom)
                        }
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
                    .accessibilityLabel("历史")
                    .accessibilityIdentifier("historyButton")
                    .accessibilityHidden(showHistory)
                }
                ToolbarItem(placement: .principal) {
                    HStack(spacing: 10) {
                        Text("盲眼先知").font(.system(size: 20, weight: .medium, design: .serif)).tracking(3)
                        Text("问").font(.system(size: 10, weight: .medium, design: .serif)).foregroundStyle(InkTheme.cinnabar)
                            .padding(5).overlay(RoundedRectangle(cornerRadius: 2).stroke(InkTheme.cinnabar.opacity(0.55), lineWidth: 0.8))
                    }.foregroundStyle(InkTheme.ink)
                        .contentShape(Rectangle())
                        .onTapGesture { composing = false }
                        .accessibilityIdentifier("chatTitle")
                        .accessibilityHidden(showHistory)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { composing = false; confirmNew = true } label: { Image(systemName: "square.and.pencil").font(.system(size: 17)).foregroundStyle(InkTheme.secondary) }
                        .disabled(store.isBusy || store.messages.isEmpty).accessibilityLabel("开启新对话")
                        .accessibilityIdentifier("newConversationButton")
                        .accessibilityHidden(showHistory)
                }
            }
            .toolbarBackground(InkTheme.paper, for: .navigationBar).toolbarBackground(.visible, for: .navigationBar)
            .navigationBarTitleDisplayMode(.inline)
            .sheet(isPresented: Binding(get: {
                store.showIntake && !showHistory && selectedReading == nil
            }, set: { store.showIntake = $0 }), onDismiss: {
                if store.pendingInteraction != nil { store.showInteraction = true }
            }) {
                if let plan = store.pendingPlan {
                    IntakeView(plan: plan, profile: plan.subject == "他人" ? OracleProfile() : store.profile) { profile, numbers, save in
                        store.confirmIntake(profile: profile, numbers: numbers, save: save)
                    }
                }
            }
            .sheet(isPresented: Binding(get: {
                store.showInteraction && !store.showIntake && !showHistory && selectedReading == nil
            }, set: { store.showInteraction = $0 })) {
                if let session = store.pendingInteraction {
                    OracleInteractionView(session: session, onProgress: { response in
                        store.saveInteractionProgress(response, sessionID: session.id)
                    }, onComplete: { response in
                        store.completeInteraction(response, sessionID: session.id)
                    })
                    .id(session.currentRequest?.id)
                    .interactiveDismissDisabled(false)
                }
            }
            .sheet(item: $selectedReading) { reference in
                ReadingResultsSheet(runID: reference.id)
            }
            .confirmationDialog("另开一卷对话？", isPresented: $confirmNew, titleVisibility: .visible) {
                Button("开启新对话") { store.newConversation() }.accessibilityIdentifier("confirmNewConversation")
                Button("取消", role: .cancel) { }
            } message: { Text("当前对话归档，基础资料、推演和偏好仍保留。") }
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
        return index
    }

    private var welcome: some View {
        VStack(spacing: 0) {
            Text("B L I N D  O R A C L E").font(.system(size: 10, weight: .medium)).tracking(2).foregroundStyle(InkTheme.secondary.opacity(0.8)).padding(.top, 35)
            Image("OraclePortrait").resizable().scaledToFit().frame(width: 220, height: 220)
                .blendMode(.multiply)
                .mask { RadialGradient(stops: [.init(color: .black, location: 0), .init(color: .black, location: 0.68), .init(color: .clear, location: 1)], center: .center, startRadius: 0, endRadius: 120) }
                .padding(.top, 18).accessibilityLabel("水墨绘制的盲眼先知")
            Text("问一事，听一言。").font(.system(size: 27, weight: .regular, design: .serif)).tracking(3).foregroundStyle(InkTheme.ink).padding(.top, 10)
            Text("坐吧。把心里那件事，说给我听。").font(.system(size: 14, design: .serif)).foregroundStyle(InkTheme.secondary).padding(.top, 14)
            HStack(spacing: 12) {
                Rectangle().fill(InkTheme.line).frame(width: 30, height: 0.6)
                Text("此刻 · 此地 · 此问").font(.system(size: 10)).tracking(3).foregroundStyle(InkTheme.secondary)
                Rectangle().fill(InkTheme.line).frame(width: 30, height: 0.6)
            }.padding(.top, 30).padding(.bottom, 24)
            VStack(spacing: 0) {
                ForEach(Array(suggestions.enumerated()), id: \.offset) { index, item in
                    Button { draft = item; submit() } label: {
                        HStack(spacing: 14) {
                            Text(["壹", "贰", "叁"][index]).font(.system(size: 11, design: .serif)).foregroundStyle(InkTheme.cinnabar.opacity(0.7))
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
                    Text("稍坐片刻…").font(.system(size: 16, design: .serif)).foregroundStyle(InkTheme.secondary)
                } else {
                    Text(.init(message.content)).font(.system(size: 16, design: .serif)).lineSpacing(6).foregroundStyle(InkTheme.ink).textSelection(.enabled).tint(InkTheme.cinnabar)
                }
                if message.kind == .intake {
                    if message.id == store.pendingIntakeMessageID {
                        intakeCard
                    } else if message.runID != nil {
                        Label("问事笺已确认", systemImage: "checkmark.seal").font(.system(size: 12)).foregroundStyle(InkTheme.sage)
                    }
                }
                if message.kind != .intake, let runID = message.runID, !message.content.isEmpty {
                    if let run = store.runs.first(where: { $0.id == runID }), let synthesis = run.synthesis, message.kind == .reading, synthesis.hasSignificantConflict {
                        alternatives(synthesis.alternatives, run: run)
                    }
                    HStack(spacing: 18) {
                        Button { selectedReading = ReadingReference(id: runID) } label: { Label("翻看数据", systemImage: "books.vertical") }
                            .accessibilityIdentifier("readingData-\(message.id.uuidString)")
                            .disabled(store.phase == .planning)
                        if !store.isBusy {
                            if let run = store.runs.first(where: { $0.id == runID }), run.synthesis == nil {
                                Button { store.retrySynthesis(run) } label: { Label("重试解读", systemImage: "arrow.clockwise") }
                                    .accessibilityIdentifier("retryReading-\(runID.uuidString)")
                            } else {
                                Button { draft = "请结合刚才的结果再详细解释一下，给我更具体的建议。"; submit() } label: { Label("再细说些", systemImage: "text.bubble") }
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

    private var intakeCard: some View {
        Button { composing = false; store.showIntake = true } label: {
            HStack(spacing: 15) {
                Image(systemName: "doc.text").font(.system(size: 25, weight: .ultraLight)).foregroundStyle(InkTheme.cinnabar)
                VStack(alignment: .leading, spacing: 5) {
                    Text("问事笺").font(.system(size: 19, design: .serif)).tracking(2).foregroundStyle(InkTheme.ink)
                    Text("已有的资料替你留好，余下的慢慢补。").font(.system(size: 11)).foregroundStyle(InkTheme.secondary)
                }
                Spacer(minLength: 0)
                Image(systemName: "arrow.right").font(.system(size: 13)).foregroundStyle(InkTheme.cinnabar)
            }.padding(19).background(.white.opacity(0.4), in: RoundedRectangle(cornerRadius: 14))
                .overlay(RoundedRectangle(cornerRadius: 14).stroke(InkTheme.line, lineWidth: 0.7))
        }.buttonStyle(.plain).accessibilityIdentifier("intakeCard")
    }

    private func interactionCard(_ request: OracleInteractionRequest) -> some View {
        Button { composing = false; store.showInteraction = true } label: {
            HStack(spacing: 15) {
                Image(systemName: request.kind == .tarot ? "rectangle.on.rectangle.angled" : request.kind == .coins ? "circle.grid.2x2" : "number")
                    .font(.system(size: 25, weight: .ultraLight)).foregroundStyle(InkTheme.cinnabar)
                VStack(alignment: .leading, spacing: 5) {
                    Text(request.kind == .coins && store.pendingInteraction?.input.castingStyle == "yarrow" ? "蓍草成卦" : request.title)
                        .font(.system(size: 19, design: .serif)).tracking(2).foregroundStyle(InkTheme.ink)
                    Text("慢慢来，已有的进度替你留着。").font(.system(size: 11)).foregroundStyle(InkTheme.secondary)
                }
                Spacer(minLength: 0)
                Image(systemName: "arrow.right").font(.system(size: 13)).foregroundStyle(InkTheme.cinnabar)
            }.padding(19).background(.white.opacity(0.55), in: RoundedRectangle(cornerRadius: 14))
                .overlay(RoundedRectangle(cornerRadius: 14).stroke(InkTheme.line, lineWidth: 0.7))
        }.buttonStyle(.plain).accessibilityIdentifier("interactionCard")
    }

    private func alternatives(_ choices: [ReadingAlternative], run: OracleRun) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("两种处境，哪一种更贴近你？").font(.system(size: 13, design: .serif)).foregroundStyle(InkTheme.secondary)
            ForEach(Array(choices.enumerated()), id: \.element.id) { index, choice in
                Button { store.select(choice, for: run.id) } label: {
                    HStack(alignment: .top, spacing: 12) {
                        Text(index == 0 ? "甲" : "乙").font(.system(size: 16, design: .serif)).foregroundStyle(InkTheme.cinnabar)
                            .frame(width: 30, height: 30).background(InkTheme.cinnabar.opacity(0.07), in: Circle())
                        VStack(alignment: .leading, spacing: 6) {
                            Text(choice.title).font(.system(size: 15, weight: .medium, design: .serif))
                            Text(choice.body).font(.system(size: 12)).lineSpacing(4).foregroundStyle(InkTheme.secondary)
                        }
                        Spacer(minLength: 0)
                        if run.selectedAlternative == choice.id { Image(systemName: "checkmark.circle.fill").foregroundStyle(InkTheme.sage) }
                    }.padding(15).frame(maxWidth: .infinity, alignment: .leading)
                        .background(.white.opacity(run.selectedAlternative == choice.id ? 0.7 : 0.3), in: RoundedRectangle(cornerRadius: 12))
                        .overlay(RoundedRectangle(cornerRadius: 12).stroke(run.selectedAlternative == choice.id ? InkTheme.sage : InkTheme.line, lineWidth: 0.7))
                }.buttonStyle(.plain).disabled(run.selectedAlternative != nil)
            }
            Text(run.selectedAlternative == nil ? "只作细微调整，慢慢认识你的处境。" : "已记下这次选择。")
                .font(.system(size: 10)).foregroundStyle(InkTheme.secondary)
        }.padding(.top, 12)
    }

    private var composer: some View {
        VStack(spacing: 8) {
            HStack(alignment: .bottom, spacing: 10) {
                TextField("说说你想问的事…", text: $draft, axis: .vertical).lineLimit(1...5)
                    .font(.system(size: 16, design: .serif)).foregroundStyle(InkTheme.ink).focused($composing)
                    .submitLabel(.send).onSubmit { submit() }.accessibilityIdentifier("questionInput")
                    .padding(.leading, 4).padding(.vertical, 10)
                Button {
                    if store.isBusy { store.stop() } else { submit() }
                } label: {
                    Image(systemName: store.isBusy ? "stop.fill" : "arrow.up").font(.system(size: 15, weight: .medium))
                        .foregroundStyle(InkTheme.paper).frame(width: 38, height: 38)
                        .background((draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !store.isBusy) ? InkTheme.secondary.opacity(0.3) : InkTheme.ink, in: Circle())
                }.disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !store.isBusy)
                    .accessibilityLabel(store.isBusy ? "停止回答" : "发送问题").accessibilityIdentifier("sendQuestion")
            }.padding(.horizontal, 13).padding(.vertical, 8)
                .background(Color(red: 0.982, green: 0.975, blue: 0.959), in: RoundedRectangle(cornerRadius: 22))
                .overlay(RoundedRectangle(cornerRadius: 22).stroke(InkTheme.line, lineWidth: 0.8))
            if store.messages.isEmpty { Text("本地推演 · AI 协助解读").font(.system(size: 9)).tracking(1).foregroundStyle(InkTheme.secondary.opacity(0.75)) }
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
        guard !store.isBusy else { return }
        guard store.pendingInteraction == nil else { composing = false; store.showInteraction = true; return }
        let text = draft; draft = ""; composing = false; store.send(text)
    }
}

private struct ReadingReference: Identifiable { let id: UUID }

private struct TranscriptEdgeEffect: ViewModifier {
    @ViewBuilder func body(content: Content) -> some View {
        if #available(iOS 26.0, *) { content.scrollEdgeEffectHidden(true, for: .bottom) }
        else { content }
    }
}

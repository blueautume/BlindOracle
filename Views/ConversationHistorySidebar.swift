import SwiftUI

/// Two unequal horizontal strokes, matching the compact history affordance.
struct HistoryMenuIcon: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Capsule().frame(width: 21, height: 2)
            Capsule().frame(width: 14, height: 2)
        }.frame(width: 24, height: 24)
    }
}

struct ConversationHistorySidebar: View {
    @Binding var isPresented: Bool
    @EnvironmentObject private var store: OracleStore
    @State private var deletionCandidate: OracleConversation?
    @State private var showClearHistory = false

    private var history: [OracleConversation] {
        store.conversations.filter { !$0.isEmpty }.sorted {
            $0.updatedAt == $1.updatedAt ? $0.id.uuidString < $1.id.uuidString : $0.updatedAt > $1.updatedAt
        }
    }
    private var groups: [(String, [OracleConversation])] {
        let calendar = Calendar.current
        let today = history.filter { calendar.isDateInToday($0.updatedAt) }
        let yesterday = history.filter { calendar.isDateInYesterday($0.updatedAt) }
        let earlier = history.filter { !calendar.isDateInToday($0.updatedAt) && !calendar.isDateInYesterday($0.updatedAt) }
        return [(L10n.text("今天", "Today"), today), (L10n.text("昨天", "Yesterday"), yesterday), (L10n.text("更早", "Earlier"), earlier)].filter { !$0.1.isEmpty }
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .topLeading) {
                Button(action: close) { Color.black.opacity(0.22).ignoresSafeArea() }
                    .buttonStyle(.plain).accessibilityLabel(L10n.text("关闭历史侧栏", "Close history sidebar"))
                VStack(alignment: .leading, spacing: 0) {
                    HStack {
                        Text(L10n.text("历史对话", "Conversation history")).font(.system(size: 23, weight: .medium, design: .serif)).tracking(2)
                        Spacer()
                        Button(action: close) { Image(systemName: "xmark").font(.system(size: 14)).frame(width: 38, height: 38) }
                            .accessibilityLabel(L10n.text("关闭历史", "Close history")).accessibilityIdentifier("closeHistory")
                    }
                    .foregroundStyle(InkTheme.ink)
                    .padding(.horizontal, 22).padding(.top, 14).padding(.bottom, 22)
                    Divider().overlay(InkTheme.line.opacity(0.6)).padding(.horizontal, 22)

                    if history.isEmpty {
                        VStack(alignment: .leading, spacing: 12) {
                            Text(L10n.text("往日问事，都会留在这里。", "Your past conversations will appear here.")).font(.system(size: 16, design: .serif))
                            Text(L10n.text("开始一段对话后，就可以随时回来。", "Once you start a conversation, you can return to it at any time."))
                                .font(.system(size: 12)).foregroundStyle(InkTheme.secondary)
                        }.padding(24)
                        Spacer()
                    } else {
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 26) {
                                ForEach(groups, id: \.0) { section, conversations in
                                    VStack(alignment: .leading, spacing: 8) {
                                        Text(section).font(.system(size: 11, weight: .medium)).tracking(2)
                                            .foregroundStyle(InkTheme.secondary).padding(.horizontal, 14).padding(.bottom, 3)
                                        ForEach(conversations) { conversation in
                                            historyRow(conversation)
                                        }
                                    }
                                }
                            }.padding(.horizontal, 10).padding(.top, 24).padding(.bottom, 28)
                        }
                    }
                    Button(role: .destructive) { showClearHistory = true } label: {
                        Label(L10n.text("清除全部历史", "Clear all history"), systemImage: "trash")
                            .font(.system(size: 14, design: .serif))
                            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(InkTheme.cinnabar)
                    .disabled(history.isEmpty)
                    .padding(.horizontal, 24).padding(.top, 8)
                    .accessibilityIdentifier("clearConversationHistory")
                    Text(L10n.text("长按一段对话，可将它删除。", "Touch and hold a conversation to delete it."))
                        .font(.system(size: 11)).foregroundStyle(InkTheme.secondary)
                        .padding(.horizontal, 24).padding(.top, 14)
                        .padding(.bottom, max(geometry.safeAreaInsets.bottom, 18))
                }
                .frame(width: min(geometry.size.width * 0.84, 360), height: geometry.size.height, alignment: .top)
                .background { InkTheme.paper.ignoresSafeArea() }
                .shadow(color: .black.opacity(0.12), radius: 20, x: 6)
                .transition(.move(edge: .leading))
                .simultaneousGesture(DragGesture().onEnded { value in
                    if value.translation.width < -60 && abs(value.translation.width) > abs(value.translation.height) * 1.3 { close() }
                })
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("conversationHistorySidebar")
        .accessibilityAction(.escape) { close() }
        .confirmationDialog(L10n.text("删除这段对话？", "Delete this conversation?"), isPresented: Binding(get: { deletionCandidate != nil }, set: { if !$0 { deletionCandidate = nil } }), titleVisibility: .visible) {
            Button(L10n.text("删除对话", "Delete conversation"), role: .destructive) {
                if let candidate = deletionCandidate { store.deleteConversation(candidate.id) }
                deletionCandidate = nil
            }.accessibilityIdentifier("confirmDeleteConversation")
            Button(L10n.text("取消", "Cancel"), role: .cancel) { deletionCandidate = nil }
        } message: { Text(L10n.text("这段聊天会从历史中移除，基础资料与独立推演记录仍保留。", "This chat will be removed from history. Your profiles and saved readings will be kept.")) }
        .alert(L10n.text("清除全部历史？", "Clear all history?"), isPresented: $showClearHistory) {
            Button(L10n.text("清除全部历史", "Clear all history"), role: .destructive) {
                deletionCandidate = nil
                store.clearConversationHistory()
                close()
            }.accessibilityIdentifier("confirmClearConversationHistory")
            Button(L10n.text("取消", "Cancel"), role: .cancel) {}
                .accessibilityIdentifier("cancelClearConversationHistory")
        } message: {
            Text(L10n.text("所有历史对话及未完成的表单、抽牌或投掷进度将被清除，当前回答也会停止。人员资料与已保存的推演记录会保留。", "All conversations and unfinished forms, card draws, or coin casts will be cleared, and the current reply will stop. Your profiles and saved readings will be kept."))
        }
    }

    private func historyRow(_ conversation: OracleConversation) -> some View {
        let active = conversation.id == store.activeConversationID
        return Button {
            store.openConversation(conversation.id)
            close()
        } label: {
            HStack(alignment: .center, spacing: 10) {
                VStack(alignment: .leading, spacing: 7) {
                    Text(conversation.title).font(.system(size: 15, design: .serif)).lineLimit(1)
                        .foregroundStyle(InkTheme.ink)
                    Text(conversation.updatedAt.formatted(.dateTime.month().day().hour().minute().locale(AppLanguage.current.locale)))
                        .font(.system(size: 10)).foregroundStyle(InkTheme.secondary)
                }
                Spacer(minLength: 4)
                if active { Circle().fill(InkTheme.cinnabar).frame(width: 5, height: 5) }
            }
            .padding(.horizontal, 14).padding(.vertical, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(active ? InkTheme.wash : .clear, in: RoundedRectangle(cornerRadius: 12))
            .contentShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(conversation.title)
        .accessibilityIdentifier("historyRow-\(conversation.id.uuidString)")
        .accessibilityValue(active ? L10n.text("当前对话", "Current conversation") : "")
        .contextMenu {
            Button(role: .destructive) { deletionCandidate = conversation } label: {
                Label(L10n.text("删除对话", "Delete conversation"), systemImage: "trash")
            }.accessibilityIdentifier("deleteConversation")
        }
    }

    private func close() { withAnimation(.spring(response: 0.32, dampingFraction: 0.9)) { isPresented = false } }
}

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
        return [("今天", today), ("昨天", yesterday), ("更早", earlier)].filter { !$0.1.isEmpty }
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .topLeading) {
                Button(action: close) { Color.black.opacity(0.22).ignoresSafeArea() }
                    .buttonStyle(.plain).accessibilityLabel("关闭历史侧栏")
                VStack(alignment: .leading, spacing: 0) {
                    HStack {
                        Text("历史对话").font(.system(size: 23, weight: .medium, design: .serif)).tracking(2)
                        Spacer()
                        Button(action: close) { Image(systemName: "xmark").font(.system(size: 14)).frame(width: 38, height: 38) }
                            .accessibilityLabel("关闭历史").accessibilityIdentifier("closeHistory")
                    }
                    .foregroundStyle(InkTheme.ink)
                    .padding(.horizontal, 22).padding(.top, 14).padding(.bottom, 22)
                    Divider().overlay(InkTheme.line.opacity(0.6)).padding(.horizontal, 22)

                    if history.isEmpty {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("往日问事，都会留在这里。").font(.system(size: 16, design: .serif))
                            Text("开始一段对话后，就可以随时回来。")
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
                    Text("长按一段对话，可将它删除。")
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
        .confirmationDialog("删除这段对话？", isPresented: Binding(get: { deletionCandidate != nil }, set: { if !$0 { deletionCandidate = nil } }), titleVisibility: .visible) {
            Button("删除对话", role: .destructive) {
                if let candidate = deletionCandidate { store.deleteConversation(candidate.id) }
                deletionCandidate = nil
            }.accessibilityIdentifier("confirmDeleteConversation")
            Button("取消", role: .cancel) { deletionCandidate = nil }
        } message: { Text("这段聊天会从历史中移除，基础资料与独立推演记录仍保留。") }
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
                    Text(conversation.updatedAt.formatted(.dateTime.month().day().hour().minute()))
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
        .accessibilityValue(active ? "当前对话" : "")
        .contextMenu {
            Button(role: .destructive) { deletionCandidate = conversation } label: {
                Label("删除对话", systemImage: "trash")
            }.accessibilityIdentifier("deleteConversation")
        }
    }

    private func close() { withAnimation(.spring(response: 0.32, dampingFraction: 0.9)) { isPresented = false } }
}

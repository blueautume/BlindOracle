import SwiftUI

struct DataLibraryView: View {
    @EnvironmentObject private var store: OracleStore
    @State private var settingsPresented = false
    @State private var editingProfile: OracleProfile?
    @State private var deletingProfile: OracleProfile?
    @State private var deletingReading: OracleRun?

    var body: some View {
        NavigationStack {
            ZStack {
                PaperBackground()
                ScrollView {
                    VStack(alignment: .leading, spacing: 28) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("数据").font(.system(size: 34, weight: .medium, design: .serif)).foregroundStyle(InkTheme.ink)
                            Text("每一条线索，皆有来处。")
                                .font(.system(size: 14, design: .serif)).foregroundStyle(InkTheme.secondary)
                        }.padding(.top, 12)

                        if store.runs.isEmpty { emptyReadings }
                        else {
                            VStack(alignment: .leading, spacing: 12) {
                                SectionEyebrow(text: "推演记录")
                                ForEach(Array(store.runs.reversed().prefix(8))) { run in
                                    ReadingRecordRow(run: run) { deletingReading = run }
                                }
                                if store.runs.count > 8 {
                                    NavigationLink("查看全部 \(store.runs.count) 份记录") { AllReadingsView() }
                                        .font(.system(size: 14, design: .serif)).tint(InkTheme.cinnabar)
                                        .accessibilityIdentifier("allReadings")
                                }
                            }
                        }

                        VStack(alignment: .leading, spacing: 12) {
                            HStack {
                                SectionEyebrow(text: "留存资料")
                                Spacer()
                                Button { editingProfile = OracleProfile() } label: { Image(systemName: "plus").font(.system(size: 14)) }
                                    .tint(InkTheme.cinnabar).accessibilityLabel("新增人员资料").accessibilityIdentifier("addProfile")
                            }
                            PaperCard {
                                VStack(spacing: 0) {
                                    if store.profiles.isEmpty {
                                        Text("还没有留存的人员资料。点右上方的加号，先记下一个姓名。")
                                            .font(.system(size: 13, design: .serif)).lineSpacing(5).foregroundStyle(InkTheme.secondary)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                    }
                                    ForEach(Array(store.profiles.enumerated()), id: \.element.id) { index, profile in
                                        if index > 0 { Divider().overlay(InkTheme.line).padding(.vertical, 13) }
                                        HStack(spacing: 12) {
                                          Button { editingProfile = profile } label: {
                                            HStack(spacing: 12) {
                                                Image(systemName: "person.text.rectangle").font(.system(size: 21, weight: .light)).frame(width: 30).foregroundStyle(InkTheme.cinnabar)
                                                VStack(alignment: .leading, spacing: 5) {
                                                    Text(profileTitle(profile)).font(.system(size: 16, design: .serif)).foregroundStyle(InkTheme.ink)
                                                    Text(profileSummary(profile)).font(.system(size: 12)).foregroundStyle(InkTheme.secondary).lineLimit(2)
                                                }
                                                Spacer()
                                                Image(systemName: "chevron.right").font(.system(size: 11)).foregroundStyle(InkTheme.secondary)
                                            }.contentShape(Rectangle())
                                          }.buttonStyle(.plain).accessibilityIdentifier("profileRow-\(profile.id.uuidString)")
                                          Button { deletingProfile = profile } label: {
                                              Image(systemName: "trash").font(.system(size: 14, weight: .light))
                                                  .foregroundStyle(InkTheme.secondary).frame(width: 36, height: 40)
                                          }.buttonStyle(.plain).accessibilityLabel("删除\(profileTitle(profile))的资料")
                                              .accessibilityIdentifier("deleteProfile-\(profile.id.uuidString)")
                                        }
                                    }
                                }
                            }
                            Text("按姓名分别留存，问事时可选取一人或多人。出生资料不确定，也可以先留白。")
                                .font(.system(size: 12)).foregroundStyle(InkTheme.secondary)
                        }

                        VStack(alignment: .leading, spacing: 12) {
                            SectionEyebrow(text: "本地推演方法")
                            NavigationLink { PluginDirectoryView() } label: {
                                PaperCard {
                                    HStack {
                                        VStack(alignment: .leading, spacing: 7) {
                                            Text("\(store.registry.descriptors.count) 种方法，各自成卷").font(.system(size: 17, design: .serif)).foregroundStyle(InkTheme.ink)
                                            Text("查看所需资料、计算范围与原始结果说明")
                                                .font(.system(size: 12)).foregroundStyle(InkTheme.secondary)
                                        }
                                        Spacer()
                                        Text(String(store.registry.descriptors.count)).font(.system(size: 29, weight: .light, design: .serif)).foregroundStyle(InkTheme.cinnabar)
                                        Image(systemName: "chevron.right").font(.system(size: 11)).foregroundStyle(InkTheme.secondary)
                                    }
                                }
                            }.buttonStyle(.plain)
                        }

                        PreferenceWeightsCard()
                        Text("原始结果按方法单独留存，此处不做合并。")
                            .font(.system(size: 12, design: .serif)).foregroundStyle(InkTheme.secondary).frame(maxWidth: .infinity)
                    }.padding(.horizontal, 22).padding(.bottom, 90)
                        .frame(maxWidth: 760).frame(maxWidth: .infinity)
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { settingsPresented = true } label: { Image(systemName: "gearshape").font(.system(size: 18, weight: .light)) }
                        .tint(InkTheme.ink).accessibilityLabel("设置")
                }
            }
            .toolbarBackground(InkTheme.paper, for: .navigationBar)
            .sheet(isPresented: $settingsPresented) { OracleSettingsView() }
            .sheet(isPresented: Binding(get: { editingProfile != nil }, set: { if !$0 { editingProfile = nil } })) {
                if let profile = editingProfile {
                    ProfileEditor(profile: profile) { updated in store.saveProfile(updated); editingProfile = nil }
                }
            }
            .confirmationDialog("删除这份人员资料？", isPresented: Binding(get: { deletingProfile != nil }, set: { if !$0 { deletingProfile = nil } }), titleVisibility: .visible) {
                Button("删除资料", role: .destructive) {
                    if let profile = deletingProfile { store.deleteProfile(id: profile.id) }
                    deletingProfile = nil
                }.accessibilityIdentifier("confirmDeleteProfile")
                Button("取消", role: .cancel) { deletingProfile = nil }
            } message: {
                Text("\(deletingProfile.map(profileTitle) ?? "这份资料")将从留存名单移除，过去的推演快照仍保留。")
            }
            .modifier(ReadingDeletionConfirmation(reading: $deletingReading))
        }.tint(InkTheme.cinnabar)
    }

    private var emptyReadings: some View {
        PaperCard {
            VStack(spacing: 16) {
                OracleMark(size: 58).padding(.top, 8)
                Text("数据簿，尚待落笔").font(.system(size: 21, design: .serif)).foregroundStyle(InkTheme.ink)
                Text("在对话里写下所问的事。\n推演完成后，每一份结果都会留在这里。")
                    .font(.system(size: 14, design: .serif)).foregroundStyle(InkTheme.secondary).multilineTextAlignment(.center).lineSpacing(6)
                Button { store.selectedTab = 0 } label: {
                    Text("去问一件事").font(.system(size: 14, weight: .medium, design: .serif)).padding(.horizontal, 23).padding(.vertical, 11)
                        .foregroundStyle(InkTheme.cinnabar).background(InkTheme.cinnabar.opacity(0.06), in: Capsule())
                }.padding(.bottom, 4)
            }.frame(maxWidth: .infinity)
        }
    }
}

private struct ReadingRecordRow: View {
    let run: OracleRun
    let onDelete: () -> Void
    var body: some View {
        PaperCard {
            HStack(spacing: 12) {
                NavigationLink { ReadingRecordView(runID: run.id) } label: {
                    ReadingRecordSummary(run: run).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("readingRecord-\(run.id.uuidString)")
                Button(action: onDelete) {
                    Image(systemName: "trash").font(.system(size: 14, weight: .light))
                        .foregroundStyle(InkTheme.secondary).frame(width: 36, height: 40)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("删除推演记录：\(String(run.input.question.prefix(60)))")
                .accessibilityIdentifier("deleteReading-\(run.id.uuidString)")
            }
        }.accessibilityElement(children: .contain)
    }
}

private struct ReadingRecordSummary: View {
    let run: OracleRun
    var body: some View {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text(run.input.castingDate.formatted(.dateTime.year().month().day())).font(.system(size: 11)).foregroundStyle(InkTheme.secondary)
                    Spacer()
                    Text(run.completedAt == nil ? "推演记录" : "已留存").font(.system(size: 10, design: .serif)).foregroundStyle(InkTheme.sage)
                }
                Text(run.input.question).font(.system(size: 17, design: .serif)).foregroundStyle(InkTheme.ink).lineLimit(2).multilineTextAlignment(.leading)
                HStack(spacing: 6) {
                    Text("\(run.results.count) 份独立结果").font(.system(size: 12)).foregroundStyle(InkTheme.secondary)
                    if run.results.contains(where: { $0.status == .partial || $0.status == .unavailable }) {
                        Text("· 含未确定项").font(.system(size: 11)).foregroundStyle(InkTheme.cinnabar.opacity(0.8))
                    }
                    Spacer()
                    Image(systemName: "arrow.up.right").font(.system(size: 12, weight: .light)).foregroundStyle(InkTheme.cinnabar)
                }
            }
    }
}

private struct ReadingDeletionConfirmation: ViewModifier {
    @EnvironmentObject private var store: OracleStore
    @Binding var reading: OracleRun?

    func body(content: Content) -> some View {
        content.alert("删除这份推演记录？", isPresented: Binding(get: { reading != nil }, set: { if !$0 { reading = nil } })) {
            Button("删除推演记录", role: .destructive) {
                if let reading { store.deleteReading(id: reading.id) }
                reading = nil
            }.accessibilityIdentifier("confirmDeleteReading")
            Button("取消", role: .cancel) { reading = nil }
                .accessibilityIdentifier("cancelDeleteReading")
        } message: {
            Text("将删除这份推演记录及其原始结果。对话文字和留存人员资料仍保留。")
        }
    }
}

private struct AllReadingsView: View {
    @EnvironmentObject private var store: OracleStore
    @State private var deletingReading: OracleRun?
    var body: some View {
        ZStack {
            PaperBackground()
            ScrollView { LazyVStack(spacing: 12) {
                if store.runs.isEmpty {
                    PaperCard {
                        Text("推演记录已清空，往后的结果会留在这里。")
                            .font(.system(size: 14, design: .serif)).foregroundStyle(InkTheme.secondary)
                    }
                }
                ForEach(store.runs.reversed()) { run in
                    ReadingRecordRow(run: run) { deletingReading = run }
                }
            }.padding(20).frame(maxWidth: 760).frame(maxWidth: .infinity) }
        }.navigationTitle("推演记录").navigationBarTitleDisplayMode(.inline)
            .modifier(ReadingDeletionConfirmation(reading: $deletingReading))
    }
}

struct ReadingRecordView: View {
    @EnvironmentObject private var store: OracleStore
    let runID: UUID
    private var run: OracleRun? { store.runs.first { $0.id == runID } }
    var body: some View {
        ZStack {
            PaperBackground()
            if let run {
                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        VStack(alignment: .leading, spacing: 10) {
                            SectionEyebrow(text: "此次所问")
                            Text(run.input.question).font(.system(size: 23, design: .serif)).foregroundStyle(InkTheme.ink).lineSpacing(5)
                            Text(run.input.castingDate.formatted(.dateTime.year().month().day().hour().minute()))
                                .font(.system(size: 12)).foregroundStyle(InkTheme.secondary)
                        }
                        if run.results.isEmpty {
                            PaperCard { Text("推演尚未完成，已有资料会保留在本机。")
                                .font(.system(size: 14, design: .serif)).foregroundStyle(InkTheme.secondary) }
                        }
                        ForEach(run.results) { result in
                            NavigationLink { OracleResultDetailView(result: result) } label: {
                                PaperCard {
                                    VStack(alignment: .leading, spacing: 12) {
                                        HStack {
                                            Image(systemName: result.method.symbol).font(.system(size: 17, weight: .light)).foregroundStyle(InkTheme.cinnabar)
                                            Text(result.displayTitle).font(.system(size: 17, design: .serif)).foregroundStyle(InkTheme.ink)
                                            Spacer()
                                            ResultStatusBadge(status: result.status)
                                        }
                                        Text(result.headline).font(.system(size: 13)).foregroundStyle(InkTheme.secondary).multilineTextAlignment(.leading).lineLimit(3)
                                        HStack {
                                            Text("\(result.rows.count) 项原始数据 · \(result.evidence.count) 条规则线索").font(.system(size: 11)).foregroundStyle(InkTheme.secondary)
                                            Spacer()
                                            Image(systemName: "chevron.right").font(.system(size: 10)).foregroundStyle(InkTheme.cinnabar)
                                        }
                                    }
                                }
                            }.buttonStyle(.plain)
                        }
                        if run.results.contains(where: { $0.status == .complete || $0.status == .partial }) {
                            Button { store.retrySynthesis(run) } label: {
                                Label("请先知再解读一次", systemImage: "arrow.clockwise").font(.system(size: 14, design: .serif))
                            }.tint(InkTheme.cinnabar).frame(maxWidth: .infinity).padding(.top, 4)
                                .disabled(store.isBusy || store.pendingInteraction != nil)
                        }
                        Text("此处逐项展示本地结果，资料不确定的部分会明确留白。")
                            .font(.system(size: 12)).foregroundStyle(InkTheme.secondary).lineSpacing(5)
                    }.padding(22).padding(.bottom, 65).frame(maxWidth: 760).frame(maxWidth: .infinity)
                }
            } else { Text("这份记录暂时无法读取。") }
        }.navigationTitle("原始推演").navigationBarTitleDisplayMode(.inline)
    }
}

struct OracleResultDetailView: View {
    let result: OracleResult
    var body: some View {
        ZStack {
            PaperBackground()
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    VStack(alignment: .leading, spacing: 11) {
                        ResultStatusBadge(status: result.status)
                        Text(result.headline).font(.system(size: 23, design: .serif)).foregroundStyle(InkTheme.ink).lineSpacing(5)
                        Text("版本 \(result.version) · 本地耗时 \(String(format: "%.0f", result.durationMilliseconds)) ms")
                            .font(.system(size: 11)).foregroundStyle(InkTheme.secondary)
                    }
                    if let draws = result.tarotDraws, !draws.isEmpty { TarotSpreadView(draws: draws) }
                    if !result.rows.isEmpty {
                        VStack(alignment: .leading, spacing: 12) {
                            SectionEyebrow(text: "原始盘面")
                            PaperCard {
                                VStack(spacing: 0) {
                                    ForEach(Array(result.rows.enumerated()), id: \.offset) { index, row in
                                        if index > 0 { Divider().overlay(InkTheme.line).padding(.vertical, 12) }
                                        VStack(alignment: .leading, spacing: 6) {
                                            Text(row.label).font(.system(size: 11, weight: .medium)).foregroundStyle(InkTheme.secondary)
                                            Text(row.value).font(.system(size: 15, design: .serif)).foregroundStyle(InkTheme.ink).lineSpacing(4).textSelection(.enabled)
                                        }.frame(maxWidth: .infinity, alignment: .leading)
                                    }
                                }
                            }
                        }
                    }
                    if !result.evidence.isEmpty {
                        VStack(alignment: .leading, spacing: 12) {
                            SectionEyebrow(text: "规则线索")
                            PaperCard {
                                VStack(alignment: .leading, spacing: 15) {
                                    ForEach(Array(result.evidence.enumerated()), id: \.offset) { _, evidence in
                                        HStack(alignment: .top, spacing: 10) {
                                            Circle().fill(InkTheme.cinnabar.opacity(0.6)).frame(width: 4, height: 4).padding(.top, 8)
                                            Text(evidence.statement).font(.system(size: 14, design: .serif)).foregroundStyle(InkTheme.ink).lineSpacing(5)
                                        }
                                    }
                                }
                            }
                        }
                    }
                    if !result.limitations.isEmpty {
                        VStack(alignment: .leading, spacing: 12) {
                            SectionEyebrow(text: "留白与边界")
                            PaperCard {
                                VStack(alignment: .leading, spacing: 12) {
                                    ForEach(Array(result.limitations.enumerated()), id: \.offset) { _, text in
                                        Text(text).font(.system(size: 13)).foregroundStyle(InkTheme.secondary).lineSpacing(4)
                                    }
                                }
                            }
                        }
                    }
                    Text(result.provenance).font(.system(size: 11)).foregroundStyle(InkTheme.secondary).lineSpacing(4)
                }.padding(22).frame(maxWidth: 760).frame(maxWidth: .infinity)
            }
        }.navigationTitle(result.displayTitle).navigationBarTitleDisplayMode(.inline)
    }
}

private struct ResultStatusBadge: View {
    let status: OracleResultStatus
    private var title: String {
        switch status { case .complete: "已完成"; case .partial: "部分结果"; case .unavailable: "资料未定"; case .failed: "未完成" }
    }
    private var color: Color { status == .complete ? InkTheme.sage : InkTheme.cinnabar }
    var body: some View {
        Text(title).font(.system(size: 10, design: .serif)).foregroundStyle(color)
            .padding(.horizontal, 8).padding(.vertical, 4).background(color.opacity(0.07), in: Capsule())
    }
}

private struct PreferenceWeightsCard: View {
    @EnvironmentObject private var store: OracleStore
    @State private var expanded = false
    private var total: Double { max(0.0001, store.weights.values.reduce(0, +)) }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionEyebrow(text: "解读偏好")
            PaperCard {
                DisclosureGroup(isExpanded: $expanded) {
                    VStack(spacing: 13) {
                        ForEach(OracleMethod.allCases) { method in
                            let fraction = max(0, store.weights[method.rawValue] ?? 1) / total
                            HStack(spacing: 10) {
                                Text(method.title).font(.system(size: 12, design: .serif)).foregroundStyle(InkTheme.ink).frame(width: 106, alignment: .leading)
                                GeometryReader { geometry in
                                    ZStack(alignment: .leading) {
                                        Capsule().fill(InkTheme.line.opacity(0.5))
                                        Capsule().fill(InkTheme.cinnabar.opacity(0.6)).frame(width: max(2, geometry.size.width * min(1, fraction)))
                                    }
                                }.frame(height: 4)
                                Text(fraction, format: .percent.precision(.fractionLength(1))).monospacedDigit().font(.system(size: 10)).foregroundStyle(InkTheme.secondary).frame(width: 43, alignment: .trailing)
                            }
                        }
                    }.padding(.top, 18)
                } label: {
                    VStack(alignment: .leading, spacing: 7) {
                        Text("慢慢认识你的处境").font(.system(size: 16, design: .serif)).foregroundStyle(InkTheme.ink)
                        Text("初始一视同仁，随你的选择轻微调整。")
                            .font(.system(size: 12)).foregroundStyle(InkTheme.secondary)
                    }
                }.tint(InkTheme.cinnabar)
                Text("偏好占比用于整理不同线索，不代表方法准确率。")
                    .font(.system(size: 11)).foregroundStyle(InkTheme.secondary).padding(.top, expanded ? 13 : 8)
            }
        }
    }
}

private struct PluginDirectoryView: View {
    @EnvironmentObject private var store: OracleStore
    var body: some View {
        ZStack {
            PaperBackground()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text("每种方法有独立的资料要求与计算边界。")
                        .font(.system(size: 14, design: .serif)).foregroundStyle(InkTheme.secondary).padding(.bottom, 5)
                    ForEach(store.registry.descriptors) { descriptor in
                        NavigationLink { PluginDocumentView(descriptor: descriptor) } label: {
                            PaperCard {
                                HStack(spacing: 13) {
                                    Image(systemName: descriptor.method.symbol).font(.system(size: 20, weight: .light)).foregroundStyle(InkTheme.cinnabar).frame(width: 28)
                                    VStack(alignment: .leading, spacing: 6) {
                                        Text(descriptor.method.title).font(.system(size: 16, design: .serif)).foregroundStyle(InkTheme.ink)
                                        Text(descriptor.summary).font(.system(size: 12)).foregroundStyle(InkTheme.secondary).lineLimit(2).multilineTextAlignment(.leading)
                                    }
                                    Spacer(minLength: 0)
                                    Image(systemName: "chevron.right").font(.system(size: 10)).foregroundStyle(InkTheme.secondary)
                                }
                            }
                        }.buttonStyle(.plain)
                    }
                }.padding(22).frame(maxWidth: 760).frame(maxWidth: .infinity)
            }
        }.navigationTitle("本地推演方法").navigationBarTitleDisplayMode(.inline)
    }
}

private struct PluginDocumentView: View {
    let descriptor: OraclePluginDescriptor
    var body: some View {
        ZStack {
            PaperBackground()
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    Text(descriptor.summary).font(.system(size: 20, design: .serif)).foregroundStyle(InkTheme.ink).lineSpacing(7)
                    documentSection("所需资料", descriptor.requiredFields.map(\.title).joined(separator: "、"))
                    if !descriptor.optionalFields.isEmpty { documentSection("可补充资料", descriptor.optionalFields.map(\.title).joined(separator: "、")) }
                    documentSection("适用主题", descriptor.supportedQuestions.joined(separator: "\n"))
                    documentSection("可查看的结果", descriptor.outputDescription)
                    documentSection("计算边界", descriptor.limitations.joined(separator: "\n\n"))
                    Text("版本 \(descriptor.version)\n\(descriptor.license)").font(.system(size: 11)).foregroundStyle(InkTheme.secondary).lineSpacing(5)
                    if let url = URL(string: descriptor.source), ["https", "http"].contains(url.scheme ?? "") {
                        Link("来源与参考", destination: url).font(.system(size: 12)).tint(InkTheme.cinnabar)
                    }
                }.padding(22).frame(maxWidth: 760).frame(maxWidth: .infinity)
            }
        }.navigationTitle(descriptor.method.title).navigationBarTitleDisplayMode(.inline)
    }
    private func documentSection(_ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionEyebrow(text: title)
            PaperCard { Text(text.isEmpty ? "无额外要求" : text).font(.system(size: 14, design: .serif)).foregroundStyle(InkTheme.ink).lineSpacing(6).frame(maxWidth: .infinity, alignment: .leading) }
        }
    }
}

private struct OracleSettingsView: View {
    @EnvironmentObject private var store: OracleStore
    @Environment(\.dismiss) private var dismiss
    @AppStorage("deepseek.model") private var model = DeepSeekConfiguration.defaultModel
    @AppStorage("oracle.localOnly") private var localOnly = false
    @State private var draftKey = ""
    @State private var feedback = ""
    @State private var showReset = false
    @State private var showRemoveKey = false
    @State private var exportURL: URL?

    var body: some View {
        NavigationStack {
            ZStack {
                PaperBackground()
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        VStack(alignment: .leading, spacing: 12) {
                            SectionEyebrow(text: "解读连接")
                            PaperCard {
                                VStack(alignment: .leading, spacing: 15) {
                                    HStack {
                                        Text("DeepSeek").font(.system(size: 17, design: .serif)).foregroundStyle(InkTheme.ink)
                                        Spacer()
                                        Label(store.hasCredential ? "已保存密钥" : "未设置", systemImage: store.hasCredential ? "checkmark.circle.fill" : "circle")
                                            .font(.system(size: 11)).foregroundStyle(store.hasCredential ? InkTheme.sage : InkTheme.secondary)
                                    }
                                    SecureField(store.hasCredential ? "输入新密钥以替换" : "输入 API 密钥", text: $draftKey)
                                        .font(.system(size: 14)).textInputAutocapitalization(.never).autocorrectionDisabled()
                                        .padding(12).background(InkTheme.paper, in: RoundedRectangle(cornerRadius: 9))
                                        .accessibilityLabel("DeepSeek API 密钥")
                                    HStack {
                                        Button("保存到钥匙串") { saveKey() }.disabled(draftKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                                            .font(.system(size: 13, design: .serif)).tint(InkTheme.cinnabar)
                                        Spacer()
                                        if store.hasCredential { Button("移除") { showRemoveKey = true }.font(.system(size: 12)).foregroundStyle(InkTheme.secondary) }
                                    }
                                    if !feedback.isEmpty { Text(feedback).font(.system(size: 12)).foregroundStyle(InkTheme.sage) }
                                    Divider().overlay(InkTheme.line)
                                    Toggle("仅本地试算", isOn: $localOnly).font(.system(size: 15, design: .serif)).tint(InkTheme.sage)
                                    Text("本地推演无需联网。启用 AI 解读时，问事、所需资料与推演结果会发送至 DeepSeek。密钥只存本机钥匙串。")
                                        .font(.system(size: 12)).foregroundStyle(InkTheme.secondary).lineSpacing(5)
                                    DisclosureGroup("模型设置") {
                                        TextField("模型 ID", text: $model).textInputAutocapitalization(.never).autocorrectionDisabled()
                                            .font(.system(size: 13)).padding(.top, 10)
                                    }.font(.system(size: 12)).tint(InkTheme.secondary)
                                }
                            }
                        }
                        VStack(alignment: .leading, spacing: 12) {
                            SectionEyebrow(text: "本机资料")
                            PaperCard {
                                VStack(alignment: .leading, spacing: 17) {
                                    Button {
                                        exportURL = store.export()
                                        if exportURL == nil { feedback = "导出暂未完成，请重试。" }
                                    } label: { Label("整理一份数据备份", systemImage: "square.and.arrow.up").font(.system(size: 15, design: .serif)) }.tint(InkTheme.ink)
                                    if let exportURL { ShareLink(item: exportURL) { Label("分享或存储备份", systemImage: "doc.zipper").font(.system(size: 13)) }.tint(InkTheme.cinnabar) }
                                    Text("备份包含基础资料、独立推演结果与解读偏好。")
                                        .font(.system(size: 12)).foregroundStyle(InkTheme.secondary).lineSpacing(4)
                                    NavigationLink { LocalNoticeView() } label: {
                                        Label("第三方资料与许可", systemImage: "doc.plaintext").font(.system(size: 13, design: .serif))
                                    }.tint(InkTheme.secondary)
                                    Divider().overlay(InkTheme.line)
                                    Button { showReset = true } label: { Label("重置解读偏好", systemImage: "arrow.counterclockwise").font(.system(size: 15, design: .serif)) }.tint(InkTheme.ink)
                                    Text("将各方法恢复为相同初始占比，保留资料和推演记录。")
                                        .font(.system(size: 12)).foregroundStyle(InkTheme.secondary).lineSpacing(4)
                                }.frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                        VStack(spacing: 9) {
                            OracleMark(size: 38)
                            Text("瞎子").font(.system(size: 15, design: .serif)).foregroundStyle(InkTheme.ink)
                            Text("版本 \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—")（\(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—")）")
                                .font(.system(size: 11)).foregroundStyle(InkTheme.secondary)
                            Text("慢听一问，静观其变。")
                                .font(.system(size: 12, design: .serif)).foregroundStyle(InkTheme.secondary)
                            Text("传统文化与自我梳理，解读不作事实保证。")
                                .font(.system(size: 11)).foregroundStyle(InkTheme.secondary.opacity(0.8)).padding(.top, 4)
                        }.frame(maxWidth: .infinity).padding(.vertical, 12)
                    }.padding(22).frame(maxWidth: 760).frame(maxWidth: .infinity)
                }
            }
            .navigationTitle("设置").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("完成") { dismiss() }.tint(InkTheme.cinnabar) } }
            .confirmationDialog("将解读偏好恢复为均等？", isPresented: $showReset, titleVisibility: .visible) {
                Button("恢复均等偏好") { store.resetPreferences() }
                Button("取消", role: .cancel) {}
            }
            .confirmationDialog("移除本机保存的解读密钥？", isPresented: $showRemoveKey, titleVisibility: .visible) {
                Button("移除密钥", role: .destructive) {
                    do { try KeychainStore.shared.delete(); store.refreshCredential(); feedback = "密钥已移除。" }
                    catch { feedback = error.localizedDescription }
                }
                Button("取消", role: .cancel) {}
            }
        }.tint(InkTheme.cinnabar)
    }
    private func saveKey() {
        do { try KeychainStore.shared.save(draftKey); draftKey = ""; store.refreshCredential(); feedback = "已安全保存。" }
        catch { feedback = error.localizedDescription }
    }
}

private struct LocalNoticeView: View {
    private var notices: String {
        guard let url = Bundle.main.url(forResource: "ThirdPartyNotices", withExtension: "txt"),
              let value = try? String(contentsOf: url, encoding: .utf8) else { return "许可证与来源说明随工程及本地插件资源保存。" }
        return value
    }
    var body: some View {
        ZStack {
            PaperBackground()
            ScrollView { Text(notices).font(.system(size: 11, design: .monospaced)).foregroundStyle(InkTheme.ink).textSelection(.enabled).padding(22).frame(maxWidth: 760).frame(maxWidth: .infinity) }
        }.navigationTitle("资料与许可").navigationBarTitleDisplayMode(.inline)
    }
}

private func profileTitle(_ profile: OracleProfile) -> String {
    profile.resolvedName.isEmpty ? "未填写姓名" : profile.resolvedName
}
private func profileSummary(_ profile: OracleProfile) -> String {
    guard let date = profile.birthDate, !profile.unknownFields.contains(.birthDate) else { return "出生资料待补充 · 可随时修改" }
    let formatter = DateFormatter()
    formatter.timeZone = TimeZone(identifier: profile.birthTimeZoneID)
    formatter.dateFormat = "yyyy 年 M 月 d 日"
    let place = profile.birthPlace.isEmpty ? "出生地待补充" : profile.birthPlace
    let unknown = !profile.birthTimeKnown ? " · 时辰未定" : ""
    return "\(formatter.string(from: date)) · \(place)\(unknown)"
}

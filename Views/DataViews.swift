import SwiftUI

struct DataLibraryView: View {
    @EnvironmentObject private var store: OracleStore
    @State private var settingsPresented = false
    @State private var editingProfile: OracleProfile?
    @State private var deletingProfile: OracleProfile?

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
                            Text("可用姓名、代称或代号选取档案。资料可以留空。")
                                .font(.system(size: 12)).foregroundStyle(InkTheme.secondary)
                        }

                        NavigationLink { PluginDirectoryView() } label: {
                            HStack {
                                Text("本地推演方法").font(.subheadline)
                                Spacer()
                                Image(systemName: "chevron.right").font(.caption)
                            }
                            .foregroundStyle(InkTheme.secondary)
                            .frame(minHeight: 44)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("localMethodsDirectory")
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
        }.tint(InkTheme.cinnabar)
    }
}

private struct PluginDirectoryView: View {
    @EnvironmentObject private var store: OracleStore
    var body: some View {
        ZStack {
            PaperBackground()
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(store.registry.descriptors.enumerated()), id: \.element.id) { index, descriptor in
                        if index > 0 { Divider() }
                        NavigationLink { PluginDocumentView(descriptor: descriptor) } label: {
                            HStack(spacing: 12) {
                                Image(systemName: descriptor.method.symbol)
                                    .font(.footnote).foregroundStyle(InkTheme.secondary).frame(width: 20)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(descriptor.method.title).font(.subheadline).foregroundStyle(InkTheme.ink)
                                    Text(descriptor.summary).font(.footnote).foregroundStyle(InkTheme.secondary).lineLimit(2)
                                }
                                Spacer(minLength: 0)
                                Image(systemName: "chevron.right").font(.caption2).foregroundStyle(InkTheme.secondary)
                            }
                            .multilineTextAlignment(.leading)
                            .padding(.vertical, 8)
                            .frame(minHeight: 44)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("localMethod-\(descriptor.method.rawValue)")
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
                VStack(alignment: .leading, spacing: 16) {
                    Text(descriptor.summary).font(.subheadline).foregroundStyle(InkTheme.ink)
                    documentSection("所需资料", descriptor.requiredFields.map(\.title).joined(separator: "、"))
                    if !descriptor.optionalFields.isEmpty { documentSection("可补充资料", descriptor.optionalFields.map(\.title).joined(separator: "、")) }
                    documentSection("适用主题", descriptor.supportedQuestions.joined(separator: "\n"))
                    documentSection("可查看的结果", descriptor.outputDescription)
                    documentSection("计算边界", descriptor.limitations.joined(separator: "\n\n"))
                    Text("版本 \(descriptor.version)\n\(descriptor.license)").font(.caption).foregroundStyle(InkTheme.secondary)
                    if let url = URL(string: descriptor.source), ["https", "http"].contains(url.scheme ?? "") {
                        Link("来源与参考", destination: url).font(.footnote).tint(InkTheme.secondary)
                    }
                }.padding(22).frame(maxWidth: 760).frame(maxWidth: .infinity)
            }
        }.navigationTitle(descriptor.method.title).navigationBarTitleDisplayMode(.inline)
    }
    private func documentSection(_ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.footnote.weight(.medium)).foregroundStyle(InkTheme.secondary)
                .accessibilityAddTraits(.isHeader)
            Text(text.isEmpty ? "无额外要求" : text).font(.footnote).foregroundStyle(InkTheme.ink).lineSpacing(3)
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
                                    Picker("解读模型", selection: Binding(get: { store.aiProvider }, set: { store.selectAIProvider($0) })) {
                                        ForEach(AIProvider.allCases, id: \.self) { provider in
                                            Text(provider.displayName).tag(provider)
                                        }
                                    }
                                    .pickerStyle(.segmented)
                                    .disabled(store.isBusy || store.isCheckingConnection)
                                    .accessibilityIdentifier("aiProviderPicker")
                                    HStack {
                                        Text("\(store.aiProvider.displayName) API 密钥")
                                            .font(.system(size: 17, design: .serif)).foregroundStyle(InkTheme.ink)
                                        Spacer()
                                        Label(store.hasCredential ? "已保存密钥" : "未设置", systemImage: store.hasCredential ? "checkmark.circle.fill" : "circle")
                                            .font(.system(size: 11)).foregroundStyle(store.hasCredential ? InkTheme.sage : InkTheme.secondary)
                                    }
                                    SecureField(store.hasCredential ? "输入新密钥以替换" : "输入 API 密钥", text: $draftKey)
                                        .font(.system(size: 14)).textInputAutocapitalization(.never).autocorrectionDisabled()
                                        .padding(12).background(InkTheme.paper, in: RoundedRectangle(cornerRadius: 9))
                                        .accessibilityLabel("\(store.aiProvider.displayName) API 密钥")
                                    HStack {
                                        Button("保存到钥匙串") { saveKey() }.disabled(draftKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                                            .disabled(store.isBusy || store.isCheckingConnection)
                                            .font(.system(size: 13, design: .serif)).tint(InkTheme.cinnabar)
                                        Spacer()
                                        if store.hasCredential {
                                            Button("移除") { showRemoveKey = true }
                                                .font(.system(size: 12)).foregroundStyle(InkTheme.secondary)
                                                .disabled(store.isBusy || store.isCheckingConnection)
                                        }
                                    }
                                    if !feedback.isEmpty { Text(feedback).font(.system(size: 12)).foregroundStyle(InkTheme.sage) }
                                    Divider().overlay(InkTheme.line)
                                    Text(store.connectionStatus).font(.system(size: 13, design: .serif))
                                        .foregroundStyle(localOnly || !store.hasCredential ? InkTheme.cinnabar : InkTheme.sage)
                                        .accessibilityIdentifier("settingsAIConnectionStatus")
                                    Toggle("仅本地试算", isOn: $localOnly).font(.system(size: 15, design: .serif)).tint(InkTheme.sage)
                                        .disabled(store.isBusy || store.isCheckingConnection)
                                        .onChange(of: localOnly) { _, _ in store.invalidateConnectionReport() }
                                    Text("本地试算只显示规则摘要，不调用 AI。启用 AI 解读时，问事、所需资料与推演结果会发送至所选服务。安装包可携带内置密钥，运行时保存于本机钥匙串。")
                                        .font(.system(size: 12)).foregroundStyle(InkTheme.secondary).lineSpacing(5)
                                    if store.aiProvider == .deepSeek {
                                        Button("恢复 Pro 联网解读") { store.restoreRecommendedConnection() }
                                            .font(.system(size: 13, design: .serif)).tint(InkTheme.cinnabar)
                                            .disabled(store.isBusy || store.isCheckingConnection)
                                            .accessibilityIdentifier("restoreProConnection")
                                    }
                                    Button {
                                        Task { await store.checkAIConnection() }
                                    } label: {
                                        HStack(spacing: 8) {
                                            if store.isCheckingConnection { ProgressView().controlSize(.small) }
                                            Text(store.isCheckingConnection ? "正在检查真实模型响应…" : "检查 AI 连接")
                                        }
                                    }.font(.system(size: 13, design: .serif)).tint(InkTheme.cinnabar)
                                        .disabled(store.isCheckingConnection || !store.hasCredential)
                                        .accessibilityIdentifier("checkAIConnection")
                                    Text("连接检查只发送固定测试消息，不发送个人资料。")
                                        .font(.system(size: 11)).foregroundStyle(InkTheme.secondary)
                                    if let message = store.connectionFeedback {
                                        Text(message).font(.system(size: 12)).foregroundStyle(InkTheme.secondary)
                                            .accessibilityIdentifier("connectionCheckFeedback")
                                    }
                                    if let report = store.connectionReport {
                                        VStack(alignment: .leading, spacing: 6) {
                                            Text("请求模型：\(report.requestedModel)")
                                            Text("实际模型：\(report.actualModel ?? "服务端未提供")")
                                            Text("深度思考：开启 · \(store.aiProvider.reasoningEffort) · 输出预算 \(store.aiProvider.outputTokenBudget, format: .number) tokens")
                                            Text("服务：\(report.host) · 耗时 \(String(format: "%.1f", report.elapsed)) 秒")
                                            if let count = report.reasoningTokens { Text("思考 token 数：\(count)") }
                                            Text("检查时间：\(report.checkedAt.formatted(date: .numeric, time: .standard))")
                                        }.font(.system(size: 11)).foregroundStyle(InkTheme.secondary)
                                            .textSelection(.enabled).accessibilityIdentifier("connectionCheckReport")
                                    }
                                    if store.aiProvider == .deepSeek {
                                        DisclosureGroup("模型设置") {
                                            TextField("模型 ID", text: $model).textInputAutocapitalization(.never).autocorrectionDisabled()
                                                .font(.system(size: 13)).padding(.top, 10)
                                                .disabled(store.isBusy || store.isCheckingConnection)
                                                .onChange(of: model) { _, value in
                                                    DeepSeekConfiguration.recordUserModelSelection(value)
                                                    store.invalidateConnectionReport()
                                                }
                                        }.font(.system(size: 12)).tint(InkTheme.secondary)
                                    }
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
            .onAppear { store.refreshCredential() }
            .onDisappear { store.refreshCredential(importBundledKey: false) }
            .onChange(of: store.aiProvider) { _, _ in
                draftKey = ""
                feedback = ""
            }
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("完成") { dismiss() }.tint(InkTheme.cinnabar) } }
            .confirmationDialog("将解读偏好恢复为均等？", isPresented: $showReset, titleVisibility: .visible) {
                Button("恢复均等偏好") { store.resetPreferences() }
                Button("取消", role: .cancel) {}
            }
            .confirmationDialog("移除本机保存的解读密钥？", isPresented: $showRemoveKey, titleVisibility: .visible) {
                Button("移除密钥", role: .destructive) {
                    do {
                        store.invalidateConnectionReport()
                        try store.credentialStore.delete(); store.refreshCredential()
                        feedback = store.hasCredential ? "已恢复安装包内置密钥。停用 AI 可开启仅本地试算。" : "密钥已移除。"
                    }
                    catch { feedback = error.localizedDescription }
                }
                Button("取消", role: .cancel) {}
            }
        }.tint(InkTheme.cinnabar)
    }
    private func saveKey() {
        do {
            store.invalidateConnectionReport()
            try store.credentialStore.save(draftKey); draftKey = ""; store.refreshCredential(); feedback = "已安全保存。"
        }
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
    profile.participantLabel
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

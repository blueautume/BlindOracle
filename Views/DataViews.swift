import SwiftUI

struct DataLibraryView: View {
    @EnvironmentObject private var store: OracleStore
    @Binding var settingsPresented: Bool
    @State private var editingProfile: OracleProfile?
    @State private var deletingProfile: OracleProfile?

    var body: some View {
        NavigationStack {
            ZStack {
                PaperBackground()
                ScrollView {
                    VStack(alignment: .leading, spacing: 28) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(L10n.text("数据", "Data")).font(.system(size: 34, weight: .medium, design: .serif)).foregroundStyle(InkTheme.ink)
                            Text(L10n.text("每一条线索，皆有来处。", "Every reading has a source."))
                                .font(.system(size: 14, design: .serif)).foregroundStyle(InkTheme.secondary)
                        }.padding(.top, 12)

                        VStack(alignment: .leading, spacing: 12) {
                            HStack {
                                SectionEyebrow(text: L10n.text("留存资料", "Saved profiles"))
                                Spacer()
                                Button { editingProfile = OracleProfile() } label: { Image(systemName: "plus").font(.system(size: 14)) }
                                    .tint(InkTheme.cinnabar).accessibilityLabel(L10n.text("新增人员资料", "Add profile")).accessibilityIdentifier("addProfile")
                            }
                            PaperCard {
                                VStack(spacing: 0) {
                                    if store.profiles.isEmpty {
                                        Text(L10n.text("还没有留存的人员资料。点右上方的加号，先记下一个姓名。", "No profiles yet. Tap + above to add a name."))
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
                                          }.buttonStyle(.plain).accessibilityLabel(L10n.text("删除\(profileTitle(profile))的资料", "Delete the profile for \(profileTitle(profile))"))
                                              .accessibilityIdentifier("deleteProfile-\(profile.id.uuidString)")
                                        }
                                    }
                                }
                            }
                            Text(L10n.text("可用姓名、代称或代号选取档案。资料可以留空。", "Find profiles by name, nickname, or code. Details can be left blank."))
                                .font(.system(size: 12)).foregroundStyle(InkTheme.secondary)
                        }

                        NavigationLink { PluginDirectoryView() } label: {
                            HStack {
                                Text(L10n.text("本地推演方法", "Reading methods")).font(.subheadline)
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
                        .tint(InkTheme.ink).accessibilityLabel(L10n.text("设置", "Settings"))
                }
            }
            .toolbarBackground(InkTheme.paper, for: .navigationBar)
            .sheet(isPresented: Binding(get: { editingProfile != nil }, set: { if !$0 { editingProfile = nil } })) {
                if let profile = editingProfile {
                    ProfileEditor(profile: profile) { updated in store.saveProfile(updated); editingProfile = nil }
                }
            }
            .confirmationDialog(L10n.text("删除这份人员资料？", "Delete this profile?"), isPresented: Binding(get: { deletingProfile != nil }, set: { if !$0 { deletingProfile = nil } }), titleVisibility: .visible) {
                Button(L10n.text("删除资料", "Delete profile"), role: .destructive) {
                    if let profile = deletingProfile { store.deleteProfile(id: profile.id) }
                    deletingProfile = nil
                }.accessibilityIdentifier("confirmDeleteProfile")
                Button(L10n.text("取消", "Cancel"), role: .cancel) { deletingProfile = nil }
            } message: {
                Text(L10n.text("\(deletingProfile.map(profileTitle) ?? "这份资料")将从留存名单移除，过去的推演快照仍保留。", "\(deletingProfile.map(profileTitle) ?? "This profile") will be removed. Past reading snapshots will be kept."))
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
        }.navigationTitle(L10n.text("本地推演方法", "Reading methods")).navigationBarTitleDisplayMode(.inline)
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
                    documentSection(L10n.text("所需资料", "Required details"), descriptor.requiredFields.map(\.title).joined(separator: L10n.text("、", ", ")))
                    if !descriptor.optionalFields.isEmpty { documentSection(L10n.text("可补充资料", "Optional details"), descriptor.optionalFields.map(\.title).joined(separator: L10n.text("、", ", "))) }
                    documentSection(L10n.text("适用主题", "Suggested topics"), descriptor.supportedQuestions.joined(separator: "\n"))
                    documentSection(L10n.text("可查看的结果", "What you’ll see"), descriptor.outputDescription)
                    documentSection(L10n.text("计算边界", "Limitations"), descriptor.limitations.joined(separator: "\n\n"))
                    Text(L10n.text("版本 \(descriptor.version)\n\(descriptor.license)", "Version \(descriptor.version)\n\(descriptor.license)")).font(.caption).foregroundStyle(InkTheme.secondary)
                    if let url = URL(string: descriptor.source), ["https", "http"].contains(url.scheme ?? "") {
                        Link(L10n.text("来源与参考", "Source and references"), destination: url).font(.footnote).tint(InkTheme.secondary)
                    }
                }.padding(22).frame(maxWidth: 760).frame(maxWidth: .infinity)
            }
        }.navigationTitle(descriptor.method.title).navigationBarTitleDisplayMode(.inline)
    }
    private func documentSection(_ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.footnote.weight(.medium)).foregroundStyle(InkTheme.secondary)
                .accessibilityAddTraits(.isHeader)
            Text(text.isEmpty ? L10n.text("无额外要求", "No additional requirements") : text).font(.footnote).foregroundStyle(InkTheme.ink).lineSpacing(3)
        }
    }
}

struct OracleSettingsView: View {
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
                        PaperCard {
                            VStack(alignment: .leading, spacing: 12) {
                                AppLanguageSettingsRow()
                                Divider().overlay(InkTheme.line)
                                OracleVoiceSettingsRow()
                            }
                        }
                        VStack(alignment: .leading, spacing: 12) {
                            SectionEyebrow(text: L10n.text("解读连接", "AI connection"))
                            PaperCard {
                                VStack(alignment: .leading, spacing: 15) {
                                    Picker(L10n.text("解读模型", "AI provider"), selection: Binding(get: { store.aiProvider }, set: { store.selectAIProvider($0) })) {
                                        ForEach(AIProvider.allCases, id: \.self) { provider in
                                            Text(provider.displayName).tag(provider)
                                        }
                                    }
                                    .pickerStyle(.segmented)
                                    .disabled(store.isBusy || store.isCheckingConnection)
                                    .accessibilityIdentifier("aiProviderPicker")
                                    HStack {
                                        Text(L10n.text("\(store.aiProvider.displayName) API 密钥", "\(store.aiProvider.displayName) API key"))
                                            .font(.system(size: 17, design: .serif)).foregroundStyle(InkTheme.ink)
                                        Spacer()
                                        Label(store.hasCredential ? L10n.text("已保存密钥", "Key saved") : L10n.text("未设置", "No key"), systemImage: store.hasCredential ? "checkmark.circle.fill" : "circle")
                                            .font(.system(size: 11)).foregroundStyle(store.hasCredential ? InkTheme.sage : InkTheme.secondary)
                                    }
                                    SecureField(store.hasCredential ? L10n.text("输入新密钥以替换", "Enter a replacement key") : L10n.text("输入 API 密钥", "Enter API key"), text: $draftKey)
                                        .font(.system(size: 14)).textInputAutocapitalization(.never).autocorrectionDisabled()
                                        .padding(12).background(InkTheme.paper, in: RoundedRectangle(cornerRadius: 9))
                                        .accessibilityLabel(L10n.text("\(store.aiProvider.displayName) API 密钥", "\(store.aiProvider.displayName) API key"))
                                    HStack {
                                        Button(L10n.text("保存到钥匙串", "Save to Keychain")) { saveKey() }.disabled(draftKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                                            .disabled(store.isBusy || store.isCheckingConnection)
                                            .font(.system(size: 13, design: .serif)).tint(InkTheme.cinnabar)
                                        Spacer()
                                        if store.hasCredential {
                                            Button(L10n.text("移除", "Remove")) { showRemoveKey = true }
                                                .font(.system(size: 12)).foregroundStyle(InkTheme.secondary)
                                                .disabled(store.isBusy || store.isCheckingConnection)
                                        }
                                    }
                                    if !feedback.isEmpty { Text(feedback).font(.system(size: 12)).foregroundStyle(InkTheme.sage) }
                                    Divider().overlay(InkTheme.line)
                                    Text(store.connectionStatus).font(.system(size: 13, design: .serif))
                                        .foregroundStyle(localOnly || !store.hasCredential ? InkTheme.cinnabar : InkTheme.sage)
                                        .accessibilityIdentifier("settingsAIConnectionStatus")
                                    Toggle(L10n.text("仅本地试算", "Local calculations only"), isOn: $localOnly).font(.system(size: 15, design: .serif)).tint(InkTheme.sage)
                                        .disabled(store.isBusy || store.isCheckingConnection)
                                        .onChange(of: localOnly) { _, _ in store.invalidateConnectionReport() }
                                    Text(L10n.text("本地试算只显示规则摘要，不调用 AI。启用 AI 解读时，问事、所需资料与推演结果会发送至所选服务。安装包可携带内置密钥，运行时保存于本机钥匙串。", "Local calculations show rule summaries and don’t use AI. When AI interpretation is enabled, your question, required details, and results are sent to the selected provider. A key included with the app is stored in the device’s Keychain."))
                                        .font(.system(size: 12)).foregroundStyle(InkTheme.secondary).lineSpacing(5)
                                    if store.aiProvider == .deepSeek {
                                        Button(L10n.text("恢复 Pro 联网解读", "Restore online Pro interpretation")) { store.restoreRecommendedConnection() }
                                            .font(.system(size: 13, design: .serif)).tint(InkTheme.cinnabar)
                                            .disabled(store.isBusy || store.isCheckingConnection)
                                            .accessibilityIdentifier("restoreProConnection")
                                    }
                                    Button {
                                        Task { await store.checkAIConnection() }
                                    } label: {
                                        HStack(spacing: 8) {
                                            if store.isCheckingConnection { ProgressView().controlSize(.small) }
                                            Text(store.isCheckingConnection ? L10n.text("正在检查真实模型响应…", "Checking the model response…") : L10n.text("检查 AI 连接", "Check AI connection"))
                                        }
                                    }.font(.system(size: 13, design: .serif)).tint(InkTheme.cinnabar)
                                        .disabled(store.isCheckingConnection || !store.hasCredential)
                                        .accessibilityIdentifier("checkAIConnection")
                                    Text(L10n.text("连接检查只发送固定测试消息，不发送个人资料。", "This check sends a fixed test message. It does not include personal information."))
                                        .font(.system(size: 11)).foregroundStyle(InkTheme.secondary)
                                    if let message = store.connectionFeedback {
                                        Text(message).font(.system(size: 12)).foregroundStyle(InkTheme.secondary)
                                            .accessibilityIdentifier("connectionCheckFeedback")
                                    }
                                    if let report = store.connectionReport {
                                        VStack(alignment: .leading, spacing: 6) {
                                            Text(L10n.text("请求模型：\(report.requestedModel)", "Requested model: \(report.requestedModel)"))
                                            Text(L10n.text("实际模型：\(report.actualModel ?? "服务端未提供")", "Reported model: \(report.actualModel ?? "Not reported")"))
                                            let budget = store.aiProvider.outputTokenBudget.formatted(.number.locale(AppLanguage.current.locale))
                                            Text(L10n.text(
                                                "深度思考：开启 · \(store.aiProvider.reasoningEffort) · 输出预算 \(budget) tokens",
                                                "Reasoning enabled · \(store.aiProvider.reasoningEffort) · Output budget: \(budget) tokens"
                                            ))
                                            Text(L10n.text("服务：\(report.host) · 耗时 \(String(format: "%.1f", report.elapsed)) 秒", "Service: \(report.host) · \(String(format: "%.1f", report.elapsed)) sec"))
                                            if let count = report.reasoningTokens { Text(L10n.text("思考 token 数：\(count)", "Reasoning tokens: \(count)")) }
                                            Text(L10n.text("检查时间：\(report.checkedAt.formatted(date: .numeric, time: .standard))", "Checked: \(report.checkedAt.formatted(.dateTime.year().month().day().hour().minute().second().locale(AppLanguage.current.locale)))"))
                                        }.font(.system(size: 11)).foregroundStyle(InkTheme.secondary)
                                            .textSelection(.enabled).accessibilityIdentifier("connectionCheckReport")
                                    }
                                    if store.aiProvider == .deepSeek {
                                        DisclosureGroup(L10n.text("模型设置", "Model settings")) {
                                            TextField(L10n.text("模型 ID", "Model ID"), text: $model).textInputAutocapitalization(.never).autocorrectionDisabled()
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
                            SectionEyebrow(text: L10n.text("本机资料", "On-device data"))
                            PaperCard {
                                VStack(alignment: .leading, spacing: 17) {
                                    Button {
                                        exportURL = store.export()
                                        if exportURL == nil { feedback = L10n.text("导出暂未完成，请重试。", "Couldn’t export the backup. Try again.") }
                                    } label: { Label(L10n.text("整理一份数据备份", "Create a backup"), systemImage: "square.and.arrow.up").font(.system(size: 15, design: .serif)) }.tint(InkTheme.ink)
                                    if let exportURL { ShareLink(item: exportURL) { Label(L10n.text("分享或存储备份", "Share or save backup"), systemImage: "doc.zipper").font(.system(size: 13)) }.tint(InkTheme.cinnabar) }
                                    Text(L10n.text("备份包含基础资料、独立推演结果与解读偏好。", "Backups include profiles, saved readings, and interpretation preferences."))
                                        .font(.system(size: 12)).foregroundStyle(InkTheme.secondary).lineSpacing(4)
                                    NavigationLink { LocalNoticeView() } label: {
                                        Label(L10n.text("第三方资料与许可", "Third-party sources and licenses"), systemImage: "doc.plaintext").font(.system(size: 13, design: .serif))
                                    }.tint(InkTheme.secondary)
                                    Divider().overlay(InkTheme.line)
                                    Button { showReset = true } label: { Label(L10n.text("重置解读偏好", "Reset interpretation preferences"), systemImage: "arrow.counterclockwise").font(.system(size: 15, design: .serif)) }.tint(InkTheme.ink)
                                    Text(L10n.text("将各方法恢复为相同初始占比，保留资料和推演记录。", "Give each method equal weight again. Your profiles and readings will be kept."))
                                        .font(.system(size: 12)).foregroundStyle(InkTheme.secondary).lineSpacing(4)
                                }.frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                        VStack(spacing: 9) {
                            OracleMark(size: 38)
                            Text(L10n.text("瞎子", "BlindOracle")).font(.system(size: 15, design: .serif)).foregroundStyle(InkTheme.ink)
                            Text(L10n.text("版本 \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—")（\(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—")）", "Version \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—") (\(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—"))"))
                                .font(.system(size: 11)).foregroundStyle(InkTheme.secondary)
                            Text(L10n.text("慢听一问，静观其变。", "Take your time and see what changes."))
                                .font(.system(size: 12, design: .serif)).foregroundStyle(InkTheme.secondary)
                            Text(L10n.text("传统文化与自我梳理，解读不作事实保证。", "For exploring traditions and reflecting on your own life. Readings don’t establish facts."))
                                .font(.system(size: 11)).foregroundStyle(InkTheme.secondary.opacity(0.8)).padding(.top, 4)
                        }.frame(maxWidth: .infinity).padding(.vertical, 12)
                    }.padding(22).frame(maxWidth: 760).frame(maxWidth: .infinity)
                }
            }
            .navigationTitle(L10n.text("设置", "Settings")).navigationBarTitleDisplayMode(.inline)
            .onAppear { store.refreshCredential() }
            .onDisappear { store.refreshCredential(importBundledKey: false) }
            .onChange(of: store.aiProvider) { _, _ in
                draftKey = ""
                feedback = ""
            }
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button(L10n.text("完成", "Done")) { dismiss() }.tint(InkTheme.cinnabar) } }
            .confirmationDialog(L10n.text("将解读偏好恢复为均等？", "Give each method equal weight again?"), isPresented: $showReset, titleVisibility: .visible) {
                Button(L10n.text("恢复均等偏好", "Reset preferences")) { store.resetPreferences() }
                Button(L10n.text("取消", "Cancel"), role: .cancel) {}
            }
            .confirmationDialog(L10n.text("移除本机保存的解读密钥？", "Remove the saved AI key?"), isPresented: $showRemoveKey, titleVisibility: .visible) {
                Button(L10n.text("移除密钥", "Remove key"), role: .destructive) {
                    do {
                        store.invalidateConnectionReport()
                        try store.credentialStore.delete(); store.refreshCredential()
                        feedback = store.hasCredential ? L10n.text("已恢复安装包内置密钥。停用 AI 可开启仅本地试算。", "Restored the key included with the app. Turn on local calculations to stop using AI.") : L10n.text("密钥已移除。", "Key removed.")
                    }
                    catch { feedback = error.localizedDescription }
                }
                Button(L10n.text("取消", "Cancel"), role: .cancel) {}
            }
        }.tint(InkTheme.cinnabar)
    }
    private func saveKey() {
        do {
            store.invalidateConnectionReport()
            try store.credentialStore.save(draftKey); draftKey = ""; store.refreshCredential(); feedback = L10n.text("已安全保存。", "Saved to Keychain.")
        }
        catch { feedback = error.localizedDescription }
    }
}

private struct OracleVoiceSettingsRow: View {
    @AppStorage(OracleVoiceStyle.preferenceKey) private var style: OracleVoiceStyle = .defaultStyle

    var body: some View {
        let label = L10n.text("解读口吻", "Reading style")
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label).font(.system(size: 15, design: .serif))
                    .accessibilityHidden(true)
                Spacer()
                Picker(label, selection: $style) {
                    ForEach(OracleVoiceStyle.allCases) { option in
                        Text(option.title).tag(option)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .tint(InkTheme.cinnabar)
                .accessibilityLabel(label)
                .accessibilityIdentifier("oracleVoiceStylePicker")
            }
            Text(style.detail)
                .font(.footnote)
                .foregroundStyle(InkTheme.secondary)
                .accessibilityIdentifier("oracleVoiceStyleDetail")
        }
    }
}

private struct LocalNoticeView: View {
    private var notices: String {
        guard let url = Bundle.main.url(forResource: "ThirdPartyNotices", withExtension: "txt"),
              let value = try? String(contentsOf: url, encoding: .utf8) else { return L10n.text("许可证与来源说明随工程及本地插件资源保存。", "License and source notices are included with the project and local plugin resources.") }
        return value
    }
    var body: some View {
        ZStack {
            PaperBackground()
            ScrollView { Text(notices).font(.system(size: 11, design: .monospaced)).foregroundStyle(InkTheme.ink).textSelection(.enabled).padding(22).frame(maxWidth: 760).frame(maxWidth: .infinity) }
        }.navigationTitle(L10n.text("资料与许可", "Sources and licenses")).navigationBarTitleDisplayMode(.inline)
    }
}

private func profileTitle(_ profile: OracleProfile) -> String {
    profile.participantLabel
}
private func profileSummary(_ profile: OracleProfile) -> String {
    guard let date = profile.birthDate, !profile.unknownFields.contains(.birthDate) else { return L10n.text("出生资料待补充 · 可随时修改", "Birth details missing · Edit anytime") }
    let formatter = DateFormatter()
    formatter.locale = AppLanguage.current.locale
    formatter.timeZone = TimeZone(identifier: profile.birthTimeZoneID)
    if AppLanguage.current.isEnglish { formatter.dateStyle = .medium }
    else { formatter.dateFormat = "yyyy 年 M 月 d 日" }
    let place = profile.birthPlace.isEmpty
        ? L10n.text("出生地待补充", "Birthplace missing")
        : ChinaDistrictCatalog.shared.displayName(for: profile.birthDistrictCode, canonical: profile.birthPlace)
    let unknown = !profile.birthTimeKnown ? L10n.text(" · 时辰未定", " · Birth time unknown") : ""
    return "\(formatter.string(from: date)) · \(place)\(unknown)"
}

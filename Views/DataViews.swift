import SwiftUI

struct DataLibraryView: View {
    @EnvironmentObject private var store: OracleStore
    @Binding var settingsPresented: Bool
    @State private var editingProfile: OracleProfile?

    var body: some View {
        NavigationStack {
            ZStack {
                PaperBackground()
                List {
                    Section {
                        Text(L10n.text("数据", "Data"))
                            .font(.system(size: 34, weight: .medium, design: .serif))
                            .foregroundStyle(InkTheme.ink)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 12)
                            .listRowInsets(EdgeInsets(top: 0, leading: 18, bottom: 0, trailing: 18))
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                    }

                    Section {
                        if store.profiles.isEmpty {
                            Text(L10n.text("还没有留存的人员资料。点右上方的加号，先记下一个姓名。", "No profiles yet. Tap + above to add a name."))
                                .font(.system(size: 13, design: .serif)).lineSpacing(5).foregroundStyle(InkTheme.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .listRowInsets(EdgeInsets(top: 18, leading: 18, bottom: 18, trailing: 18))
                                .listRowBackground(Color.white.opacity(0.35))
                                .listRowSeparator(.hidden)
                        }
                        ForEach(store.profiles) { profile in
                            Button { editingProfile = profile } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: "person.text.rectangle").font(.system(size: 21, weight: .light)).frame(width: 30).foregroundStyle(InkTheme.cinnabar)
                                    VStack(alignment: .leading, spacing: 5) {
                                        Text(profileTitle(profile)).font(.system(size: 16, design: .serif)).foregroundStyle(InkTheme.ink)
                                        Text(profileSummary(profile)).font(.system(size: 12)).foregroundStyle(InkTheme.secondary).lineLimit(2)
                                    }
                                    Spacer(minLength: 0)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("profileRow-\(profile.id.uuidString)")
                            .listRowInsets(EdgeInsets(top: 16, leading: 18, bottom: 16, trailing: 18))
                            .listRowBackground(Color.white.opacity(0.35))
                            .listRowSeparatorTint(InkTheme.line.opacity(0.65))
                            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                Button(role: .destructive) { store.deleteProfile(id: profile.id) } label: {
                                    Text(L10n.text("删除", "Delete"))
                                }
                                .tint(InkTheme.cinnabar)
                                .accessibilityIdentifier("deleteProfile-\(profile.id.uuidString)")
                            }
                        }
                    } header: {
                        HStack {
                            SectionEyebrow(text: L10n.text("留存资料", "Saved profiles"))
                            Spacer()
                            Button { editingProfile = OracleProfile() } label: { Image(systemName: "plus").font(.system(size: 14)) }
                                .tint(InkTheme.cinnabar).accessibilityLabel(L10n.text("新增人员资料", "Add profile")).accessibilityIdentifier("addProfile")
                        }
                        .textCase(nil)
                        .padding(.bottom, 4)
                    } footer: {
                        Text(L10n.text("可用姓名、代称或代号选取档案。资料可以留空。", "Find profiles by name, nickname, or code. Details can be left blank."))
                            .font(.system(size: 12)).foregroundStyle(InkTheme.secondary)
                            .textCase(nil)
                            .padding(.top, 4)
                    }

                    Section {
                        NavigationLink { PluginDirectoryView() } label: {
                            HStack(spacing: 12) {
                                Image(systemName: "books.vertical")
                                    .font(.system(size: 21, weight: .light))
                                    .frame(width: 30)
                                    .foregroundStyle(InkTheme.cinnabar)
                                Text(L10n.text("查看方法说明", "Explore methods"))
                                    .font(.system(size: 16, design: .serif))
                                    .foregroundStyle(InkTheme.ink)
                                Spacer(minLength: 0)
                            }
                            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("localMethodsDirectory")
                        .listRowInsets(EdgeInsets(top: 16, leading: 18, bottom: 16, trailing: 18))
                        .listRowBackground(Color.white.opacity(0.35))
                        .listRowSeparator(.hidden)
                    } header: {
                        HStack {
                            SectionEyebrow(text: L10n.text("推演方法", "Reading methods"))
                            Spacer()
                        }
                        .textCase(nil)
                        .padding(.bottom, 4)
                    }
                }
                .listStyle(.insetGrouped)
                .listSectionSpacing(28)
                .scrollContentBackground(.hidden)
                .contentMargins(.top, 0, for: .scrollContent)
                .contentMargins(.bottom, 90, for: .scrollContent)
                .frame(maxWidth: 760).frame(maxWidth: .infinity)
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { settingsPresented = true } label: { Image(systemName: "gearshape").font(.system(size: 18, weight: .light)) }
                        .tint(InkTheme.ink).accessibilityLabel(L10n.text("设置", "Settings")).accessibilityIdentifier("settingsButton")
                }
            }
            .toolbarBackground(InkTheme.paper, for: .navigationBar)
            .sheet(isPresented: Binding(get: { editingProfile != nil }, set: { if !$0 { editingProfile = nil } })) {
                if let profile = editingProfile {
                    ProfileEditor(profile: profile) { updated in store.saveProfile(updated); editingProfile = nil }
                }
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
        }.navigationTitle(L10n.text("推演方法", "Reading methods")).navigationBarTitleDisplayMode(.inline)
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
    @State private var feedback = ""
    @State private var showReset = false
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
                            SectionEyebrow(text: L10n.text("本机资料", "On-device data"))
                            PaperCard {
                                VStack(alignment: .leading, spacing: 17) {
                                    Button {
                                        exportURL = store.export()
                                        feedback = exportURL == nil ? L10n.text("导出暂未完成，请重试。", "Couldn’t export the backup. Try again.") : ""
                                    } label: { Label(L10n.text("整理一份数据备份", "Create a backup"), systemImage: "square.and.arrow.up").font(.system(size: 15, design: .serif)) }.tint(InkTheme.ink)
                                    if !feedback.isEmpty {
                                        Text(feedback).font(.system(size: 12)).foregroundStyle(InkTheme.cinnabar)
                                            .accessibilityIdentifier("backupExportFeedback")
                                    }
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
                        HStack(spacing: 16) {
                            NavigationLink {
                                LegalDocumentView(document: .userAgreement)
                            } label: {
                                Text(L10n.text("用户协议", "User Agreement"))
                                    .padding(.vertical, 12)
                            }
                            .accessibilityIdentifier("userAgreementLink")
                            Text("·").accessibilityHidden(true)
                            NavigationLink {
                                LegalDocumentView(document: .privacyPolicy)
                            } label: {
                                Text(L10n.text("隐私政策", "Privacy Policy"))
                                    .padding(.vertical, 12)
                            }
                            .accessibilityIdentifier("privacyPolicyLink")
                        }
                        .font(.system(.footnote, design: .serif))
                        .foregroundStyle(InkTheme.secondary)
                        .tint(InkTheme.secondary)
                        .frame(maxWidth: .infinity)
                    }.padding(22).frame(maxWidth: 760).frame(maxWidth: .infinity)
                }
                .accessibilityIdentifier("settingsScroll")
            }
            .navigationTitle(L10n.text("设置", "Settings")).navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button(L10n.text("完成", "Done")) { dismiss() }.tint(InkTheme.cinnabar) } }
            .confirmationDialog(L10n.text("将解读偏好恢复为均等？", "Give each method equal weight again?"), isPresented: $showReset, titleVisibility: .visible) {
                Button(L10n.text("恢复均等偏好", "Reset preferences")) { store.resetPreferences() }
                Button(L10n.text("取消", "Cancel"), role: .cancel) {}
            }
        }.tint(InkTheme.cinnabar)
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

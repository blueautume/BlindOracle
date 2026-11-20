import SwiftUI

struct DataLibraryView: View {
    private struct EditingProfile: Identifiable {
        let profile: OracleProfile
        let creating: Bool
        var id: UUID { profile.id }
    }

    @EnvironmentObject private var store: OracleStore
    @EnvironmentObject private var account: AccountStore
    @Binding var settingsPresented: Bool
    @State private var editingProfile: EditingProfile?
    @State private var accountDetailsPresented = false

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
                        Button { accountDetailsPresented = true } label: { AccountSummaryContent() }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("accountEntry")
                        .listRowInsets(EdgeInsets(top: 20, leading: 18, bottom: 20, trailing: 18))
                        .listRowBackground(Color.white.opacity(0.35))
                        .listRowSeparator(.hidden)
                    }

                    Section {
                        NavigationLink { AccountUsageView() } label: {
                            HStack(spacing: 12) {
                                Image(systemName: "chart.bar")
                                    .font(.system(size: 21, weight: .light))
                                    .frame(width: 30)
                                    .foregroundStyle(InkTheme.secondary)
                                Text(L10n.text("使用情况", "Usage"))
                                    .font(.system(size: 16, design: .serif))
                                    .foregroundStyle(InkTheme.ink)
                                Spacer(minLength: 0)
                            }
                            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("usageEntry")
                        .listRowInsets(EdgeInsets(top: 12, leading: 18, bottom: 12, trailing: 18))
                        .listRowBackground(Color.white.opacity(0.35))
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
                            let sameName = store.profiles.contains { $0.id != profile.id && $0.participantLabel == profile.participantLabel }
                            Button { editingProfile = EditingProfile(profile: profile, creating: false) } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: "person.text.rectangle").font(.system(size: 21, weight: .light)).frame(width: 30).foregroundStyle(InkTheme.cinnabar)
                                    VStack(alignment: .leading, spacing: 5) {
                                        HStack(spacing: 8) {
                                            Text(profile.participantLabel).font(.system(size: 16, design: .serif)).foregroundStyle(InkTheme.ink)
                                            if store.selfProfileID == profile.id {
                                                Text(L10n.text("本人", "You")).font(.system(size: 11)).foregroundStyle(InkTheme.sage)
                                            }
                                        }
                                        Text(savedProfileSummary(profile, showCode: sameName)).font(.system(size: 12)).foregroundStyle(InkTheme.secondary).lineLimit(2)
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
                            Button { editingProfile = EditingProfile(profile: OracleProfile(), creating: true) } label: { Image(systemName: "plus").font(.system(size: 14)) }
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
            .navigationDestination(isPresented: $accountDetailsPresented) { AccountView() }
            .task {
                await account.refreshOverview()
            }
            .refreshable { await account.refreshOverview() }
            .sheet(item: $editingProfile) { editor in
                ProfileEditor(profile: editor.profile, creating: editor.creating) { updated in
                    store.saveProfile(updated, creating: editor.creating)
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
    @AppStorage(CastingMethodPreferences.meihuaKey) private var meihuaModeRaw = MeihuaCastingMode.time.rawValue
    @AppStorage(CastingMethodPreferences.liuyaoKey) private var liuyaoModeRaw = LiuyaoCastingMode.coins.rawValue

    private var selectedMeihuaMode: MeihuaCastingMode { MeihuaCastingMode(rawValue: meihuaModeRaw) ?? .time }
    private var selectedLiuyaoMode: LiuyaoCastingMode { LiuyaoCastingMode(rawValue: liuyaoModeRaw) ?? .coins }

    var body: some View {
        ZStack {
            PaperBackground()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text(descriptor.summary).font(.subheadline).foregroundStyle(InkTheme.ink)
                    castingModeCard
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

    @ViewBuilder
    private var castingModeCard: some View {
        if descriptor.method == .meihua || descriptor.method == .liuyao {
            PaperCard(bottomPadding: 6) {
                VStack(alignment: .leading, spacing: 0) {
                    Text(L10n.text("起卦方式", "Casting method"))
                        .font(.system(size: 16, weight: .medium, design: .serif))
                        .foregroundStyle(InkTheme.ink)
                        .accessibilityAddTraits(.isHeader)
                    Text(L10n.text("保存在本机，用于之后的新问事。", "Saved on this device for future readings."))
                        .font(.footnote)
                        .foregroundStyle(InkTheme.secondary)
                        .padding(.top, 6)
                        .padding(.bottom, 8)
                    if descriptor.method == .meihua {
                        ForEach(Array(MeihuaCastingMode.allCases.enumerated()), id: \.offset) { index, mode in
                            if index > 0 { Divider().overlay(InkTheme.line.opacity(0.6)) }
                            castingModeRow(title: mode.title, summary: mode.summary,
                                           selected: selectedMeihuaMode == mode,
                                           identifier: "meihuaMode-" + mode.rawValue) {
                                meihuaModeRaw = mode.rawValue
                            }
                        }
                    } else {
                        ForEach(Array(LiuyaoCastingMode.allCases.enumerated()), id: \.offset) { index, mode in
                            if index > 0 { Divider().overlay(InkTheme.line.opacity(0.6)) }
                            castingModeRow(title: mode.title, summary: mode.summary,
                                           selected: selectedLiuyaoMode == mode,
                                           identifier: "liuyaoMode-" + mode.rawValue) {
                                liuyaoModeRaw = mode.rawValue
                            }
                        }
                    }
                }
            }
        }
    }

    private func castingModeRow(title: String, summary: String, selected: Bool, identifier: String,
                                action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(alignment: .center, spacing: 14) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(title).font(.system(size: 15, design: .serif)).foregroundStyle(InkTheme.ink)
                    Text(summary).font(.system(size: 12)).foregroundStyle(InkTheme.secondary).lineSpacing(4)
                }
                Spacer(minLength: 0)
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 20, weight: .light))
                    .foregroundStyle(selected ? InkTheme.sage : InkTheme.line)
                    .accessibilityHidden(true)
            }
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(identifier)
        .accessibilityAddTraits(selected ? .isSelected : [])
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
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var account: AccountStore

    var body: some View {
        NavigationStack {
            ZStack {
                PaperBackground()
                GeometryReader { geometry in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 24) {
                            PaperCard {
                                NavigationLink { AccountView() } label: {
                                    HStack {
                                        Label(L10n.text("账号设置", "Account settings"), systemImage: "person.crop.circle")
                                        Spacer()
                                        if let user = account.user {
                                            Text(user.presentationName).font(.footnote).foregroundStyle(InkTheme.secondary).lineLimit(1)
                                        }
                                        Image(systemName: "chevron.right").font(.caption)
                                    }
                                    .font(.system(size: 16, design: .serif))
                                    .foregroundStyle(InkTheme.ink)
                                }
                                .accessibilityIdentifier("settingsAccountEntry")
                            }
                            PaperCard {
                                VStack(alignment: .leading, spacing: 12) {
                                    AppLanguageSettingsRow()
                                    Divider().overlay(InkTheme.line)
                                    OracleVoiceSettingsRow()
                                }
                            }
                            Spacer(minLength: 12)
                            aboutFooter
                        }
                        .padding(22)
                        .frame(maxWidth: 760, minHeight: geometry.size.height, alignment: .top)
                        .frame(maxWidth: .infinity)
                    }
                    .accessibilityIdentifier("settingsScroll")
                }
            }
            .navigationTitle(L10n.text("设置", "Settings")).navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button(L10n.text("完成", "Done")) { dismiss() }.tint(InkTheme.cinnabar) } }
        }.tint(InkTheme.cinnabar)
    }

    private var aboutFooter: some View {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—"

        return VStack(spacing: 0) {
            OracleMark(size: 38)
            Text(L10n.text("瞎子", "BlindOracle"))
                .font(.system(.headline, design: .serif))
                .foregroundStyle(InkTheme.ink)
                .padding(.top, 8)
            Text(L10n.text("版本 \(version)（\(build)）", "Version \(version) (\(build))"))
                .font(.caption2)
                .monospacedDigit()
                .padding(.top, 3)
            Text(L10n.text("解读不做事实保证", "Readings don’t establish facts"))
                .font(.caption)
                .padding(.top, 12)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 18) { legalLinks }
                    .fixedSize(horizontal: true, vertical: false)
                VStack(spacing: 0) { legalLinks }
            }
            .font(.system(.footnote, design: .serif))
            .buttonStyle(.plain)
            .padding(.top, 4)
        }
        .foregroundStyle(InkTheme.secondary)
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("settingsAboutFooter")
    }

    @ViewBuilder private var legalLinks: some View {
        NavigationLink { LegalDocumentView(document: .userAgreement) } label: {
            Text(L10n.text("用户协议", "User Agreement"))
                .frame(minHeight: 44)
                .contentShape(Rectangle())
        }
        .accessibilityIdentifier("userAgreementLink")
        NavigationLink { LegalDocumentView(document: .privacyPolicy) } label: {
            Text(L10n.text("隐私政策", "Privacy Policy"))
                .frame(minHeight: 44)
                .contentShape(Rectangle())
        }
        .accessibilityIdentifier("privacyPolicyLink")
        NavigationLink { LocalNoticeView() } label: {
            Text(L10n.text("资料与许可", "Sources & Licenses"))
                .frame(minHeight: 44)
                .contentShape(Rectangle())
        }
        .accessibilityIdentifier("thirdPartyLicensesLink")
    }
}

private struct OracleVoiceSettingsRow: View {
    @AppStorage(OracleVoiceStyle.preferenceKey) private var style: OracleVoiceStyle = .defaultStyle

    var body: some View {
        let label = L10n.text("解读口吻", "Reading style")
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
            .accessibilityLabel(label)
            .accessibilityValue(style.title)
            .accessibilityIdentifier("oracleVoiceStylePicker")
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
                .accessibilityIdentifier("thirdPartyNoticesScroll")
        }.navigationTitle(L10n.text("资料与许可", "Sources and licenses")).navigationBarTitleDisplayMode(.inline)
    }
}

func savedProfileSummary(_ profile: OracleProfile, showCode: Bool) -> String {
    let code = showCode ? L10n.text(" · 档案 \(profile.anonymousCode)", " · Profile \(profile.anonymousCode)") : ""
    guard let date = profile.birthDate, !profile.unknownFields.contains(.birthDate) else {
        return L10n.text("出生资料待补充", "Birth details missing") + code
    }
    let formatter = DateFormatter()
    formatter.locale = AppLanguage.current.locale
    formatter.timeZone = TimeZone(identifier: profile.birthTimeZoneID)
    if AppLanguage.current.isEnglish { formatter.dateStyle = .medium }
    else { formatter.dateFormat = "yyyy 年 M 月 d 日" }
    let place = profile.birthPlace.isEmpty
        ? L10n.text("出生地待补充", "Birthplace missing")
        : ChinaDistrictCatalog.shared.displayName(for: profile.birthDistrictCode, canonical: profile.birthPlace)
    let unknown = !profile.birthTimeKnown ? L10n.text(" · 时辰未定", " · Birth time unknown") : ""
    return "\(formatter.string(from: date)) · \(place)\(unknown)\(code)"
}

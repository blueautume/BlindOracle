import SwiftUI

/// Each selected person is a value snapshot keyed by UUID. Editing one person
/// opens an independent editor and never reuses another person's form state.
struct GroupIntakeView: View {
    let plan: OraclePlan
    let onConfirm: ([OracleProfile], [Int], Bool) -> Void
    @EnvironmentObject private var store: OracleStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var drafts: [UUID: OracleProfile]
    @State private var selectedIDs: [UUID]
    @State private var editingProfile: OracleProfile?
    @State private var keepProfiles = true
    @State private var error: String?
    @State private var showSavedProfiles = true

    init(plan: OraclePlan, profiles: [OracleProfile], onConfirm: @escaping ([OracleProfile], [Int], Bool) -> Void) {
        self.plan = plan; self.onConfirm = onConfirm
        var values: [UUID: OracleProfile] = [:]
        var ids: [UUID] = []
        for profile in profiles where values[profile.id] == nil {
            values[profile.id] = profile; ids.append(profile.id)
        }
        _drafts = State(initialValue: values)
        _selectedIDs = State(initialValue: ids)
    }

    private var selectedProfiles: [OracleProfile] { selectedIDs.compactMap { drafts[$0] } }
    private var minimumCount: Int {
        if plan.subject == "多人" { return 2 }
        return plan.methods.contains { [.bazi, .ziwei, .chenggu, .xingming, .astrology].contains($0) } ? 1 : 0
    }

    var body: some View {
        NavigationStack {
            ZStack {
                PaperBackground()
                ScrollView {
                    VStack(alignment: .leading, spacing: 23) {
                        HStack(spacing: 15) {
                            OracleMark(size: 48)
                            VStack(alignment: .leading, spacing: 7) {
                                Text("一人一份，慢慢写。").font(.system(size: 22, design: .serif)).foregroundStyle(InkTheme.ink)
                                Text("选好这次涉及的人，已知的写下，未知的留白。")
                                    .font(.system(size: 12, design: .serif)).foregroundStyle(InkTheme.secondary).lineSpacing(4)
                            }
                        }
                        PaperCard {
                            VStack(alignment: .leading, spacing: 13) {
                                SectionEyebrow(text: "此次所问")
                                Text(plan.question).font(.system(size: 18, design: .serif)).lineSpacing(7).foregroundStyle(InkTheme.ink)
                                Text(minimumCount > 1 ? "此次一起看至少两人的资料。" : minimumCount == 1 ? "请选择这次要看的人员资料。" : "只问一件事时，也可以不附人员资料。")
                                    .font(.system(size: 11)).foregroundStyle(InkTheme.secondary)
                            }
                        }
                        selectedPeople
                        if !store.profiles.isEmpty { savedPeople }
                        Button { editingProfile = OracleProfile() } label: {
                            HStack(spacing: 10) {
                                Image(systemName: "person.badge.plus")
                                Text("新增一位人员")
                                Spacer()
                                Image(systemName: "plus").font(.system(size: 11))
                            }.font(.system(size: 14, design: .serif)).foregroundStyle(InkTheme.cinnabar)
                                .padding(17).background(.white.opacity(0.45), in: RoundedRectangle(cornerRadius: 13))
                                .overlay(RoundedRectangle(cornerRadius: 13).stroke(InkTheme.line, lineWidth: 0.7))
                        }.buttonStyle(.plain).accessibilityIdentifier("addParticipant")

                        if !selectedIDs.isEmpty {
                            Toggle(isOn: $keepProfiles) {
                                VStack(alignment: .leading, spacing: 5) {
                                    Text("把这些人员资料留在本机").font(.system(size: 13, design: .serif))
                                    Text("按姓名分别保存，下次问事可以直接选取。")
                                        .font(.system(size: 10)).foregroundStyle(InkTheme.secondary)
                                }
                            }.tint(InkTheme.sage).accessibilityIdentifier("saveParticipantProfiles")
                        }
                        if let error { Text(error).font(.system(size: 12)).foregroundStyle(InkTheme.cinnabar) }
                        Button(action: confirm) {
                            HStack {
                                Text("落笔，交给先知")
                                Image(systemName: "arrow.right")
                            }
                        }.buttonStyle(InkPrimaryButton()).accessibilityIdentifier("confirmIntake")
                        Text("每人的资料分别保存、分别推演。问题与本次选中的资料会用于 AI 解读。")
                            .font(.system(size: 10)).lineSpacing(4).foregroundStyle(InkTheme.secondary)
                            .frame(maxWidth: .infinity, alignment: .center)
                    }.padding(24).frame(maxWidth: 700).frame(maxWidth: .infinity)
                }.scrollDismissesKeyboard(.interactively)
            }
            .navigationTitle("问事笺").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("稍后填写") { dismiss() }.font(.system(size: 13)).foregroundStyle(InkTheme.secondary)
                }
            }
            .toolbarBackground(InkTheme.paper, for: .navigationBar).toolbarBackground(.visible, for: .navigationBar)
            .sheet(item: $editingProfile) { profile in
                ProfileEditor(profile: profile) { updated in
                    drafts[updated.id] = updated
                    if !selectedIDs.contains(updated.id) { selectedIDs.append(updated.id) }
                    editingProfile = nil
                }.id(profile.id)
            }
        }.presentationDragIndicator(.visible)
    }

    private var selectedPeople: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack {
                SectionEyebrow(text: "本次人员")
                Spacer()
                Text("已选 \(selectedIDs.count) 人").font(.system(size: 11)).foregroundStyle(InkTheme.secondary)
            }
            if selectedIDs.isEmpty {
                PaperCard {
                    Text(minimumCount == 0 ? "暂不附人员资料。也可以从留存名单选人，或新增一位。" : "从留存名单选人，或新增姓名。生辰不确定也可以先留白。")
                        .font(.system(size: 13, design: .serif)).lineSpacing(5).foregroundStyle(InkTheme.secondary)
                }
            } else {
                ForEach(selectedProfiles) { profile in
                    PaperCard {
                        VStack(alignment: .leading, spacing: 12) {
                            HStack(spacing: 10) {
                                Image(systemName: "person.crop.circle").font(.system(size: 22, weight: .light)).foregroundStyle(InkTheme.cinnabar)
                                Text(title(profile)).font(.system(size: 18, design: .serif)).foregroundStyle(InkTheme.ink)
                                Spacer()
                                Button { selectedIDs.removeAll { $0 == profile.id } } label: {
                                    Image(systemName: "xmark").font(.system(size: 11)).foregroundStyle(InkTheme.secondary).frame(width: 32, height: 32)
                                }.buttonStyle(.plain).accessibilityLabel("移除\(title(profile))")
                                    .accessibilityIdentifier("removeParticipant-\(profile.id.uuidString)")
                            }
                            Text(summary(profile)).font(.system(size: 12)).lineSpacing(4).foregroundStyle(InkTheme.secondary)
                            Button { editingProfile = profile } label: {
                                Label("查看或补充资料", systemImage: "square.and.pencil").font(.system(size: 12)).foregroundStyle(InkTheme.cinnabar)
                            }.buttonStyle(.plain).accessibilityLabel("编辑\(title(profile))的资料")
                                .accessibilityIdentifier("editParticipant-\(profile.id.uuidString)")
                        }
                    }
                }
            }
        }.accessibilityElement(children: .contain).accessibilityIdentifier("selectedParticipants")
    }

    private var savedPeople: some View {
        PaperCard {
            DisclosureGroup(isExpanded: $showSavedProfiles) {
                VStack(spacing: 0) {
                    ForEach(Array(store.profiles.enumerated()), id: \.element.id) { index, stored in
                        let profile = drafts[stored.id] ?? stored
                        let selected = selectedIDs.contains(profile.id)
                        if index > 0 { Divider().overlay(InkTheme.line).padding(.vertical, 12) }
                        Button { toggle(profile) } label: {
                            HStack(spacing: 12) {
                                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                                    .font(.system(size: 19)).foregroundStyle(selected ? InkTheme.sage : InkTheme.line)
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(title(profile)).font(.system(size: 15, design: .serif)).foregroundStyle(InkTheme.ink)
                                    Text(summary(profile)).font(.system(size: 10)).foregroundStyle(InkTheme.secondary).multilineTextAlignment(.leading)
                                }
                                Spacer(minLength: 0)
                            }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                        }.buttonStyle(.plain).accessibilityLabel("\(title(profile))，\(selected ? "已选" : "未选")")
                            .accessibilityIdentifier("selectProfile-\(profile.id.uuidString)")
                    }
                }.padding(.top, 15)
            } label: {
                Text("从留存资料中选取").font(.system(size: 14, design: .serif)).foregroundStyle(InkTheme.ink)
            }.tint(InkTheme.secondary)
        }
    }

    private func toggle(_ profile: OracleProfile) {
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.18)) {
            if selectedIDs.contains(profile.id) { selectedIDs.removeAll { $0 == profile.id } }
            else { drafts[profile.id] = profile; selectedIDs.append(profile.id) }
        }
    }

    private func title(_ profile: OracleProfile) -> String { profile.resolvedName.isEmpty ? "未填写姓名" : profile.resolvedName }

    private func summary(_ profile: OracleProfile) -> String {
        guard let date = profile.birthDate, !profile.unknownFields.contains(.birthDate) else { return "出生资料待补充 · 可以先留白" }
        let formatter = DateFormatter(); formatter.dateFormat = "yyyy年M月d日"
        formatter.timeZone = TimeZone(identifier: profile.birthTimeZoneID)
        let place = profile.birthPlace.isEmpty ? "出生地未定" : profile.birthPlace
        return "\(formatter.string(from: date)) · \(profile.birthTimeKnown ? "时刻已留存" : "时辰未定") · \(place)"
    }

    private func confirm() {
        guard selectedProfiles.count >= minimumCount else {
            error = minimumCount > 1 ? "请选好至少两位人员，再继续这次联合问事。" : "请先选择或新增这次要看的人员。"
            return
        }
        if let unnamed = selectedProfiles.first(where: { $0.resolvedName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
            error = "请先补上姓名，方便区分每一份资料。"; editingProfile = unnamed; return
        }
        error = nil
        onConfirm(selectedProfiles, [], keepProfiles)
    }
}

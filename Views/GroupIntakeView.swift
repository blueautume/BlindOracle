import SwiftUI
import UIKit

/// Every participant keeps a separate draft; one confirmation freezes them all.
struct GroupIntakeView: View {
    private struct DraftSnapshot: Equatable {
        let profiles: [OracleProfile]
        let numbers: [Int]
    }

    let plan: OraclePlan
    let onDraftChange: (([OracleProfile], [Int]) -> Void)?
    let onConfirm: ([OracleProfile], [Int], Bool, Bool) -> Bool
    @EnvironmentObject private var store: OracleStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var drafts: [UUID: ProfileFormDraft]
    @State private var selectedIDs: [UUID]
    @State private var numberTexts: [String]
    @State private var keepProfiles = true
    @State private var error: String?
    @State private var submitted = false
    @State private var savedDraft: DraftSnapshot?

    init(plan: OraclePlan, profiles: [OracleProfile], numbers: [Int] = [],
         onDraftChange: (([OracleProfile], [Int]) -> Void)? = nil,
         onConfirm: @escaping ([OracleProfile], [Int], Bool, Bool) -> Bool) {
        self.plan = plan; self.onDraftChange = onDraftChange; self.onConfirm = onConfirm
        var values: [UUID: ProfileFormDraft] = [:]
        var ids: [UUID] = []
        for profile in profiles where values[profile.id] == nil {
            values[profile.id] = ProfileFormDraft(profile: profile); ids.append(profile.id)
        }
        _drafts = State(initialValue: values)
        _selectedIDs = State(initialValue: ids)
        _numberTexts = State(initialValue: (0..<3).map { numbers.indices.contains($0) && numbers[$0] != 0 ? String(numbers[$0]) : "" })
    }

    private var minimumCount: Int {
        if plan.subject == "多人" { return 2 }
        return plan.methods.contains(where: \.usesPersonalProfile) ? 1 : 0
    }
    private var selectedProfiles: [OracleProfile] {
        selectedIDs.compactMap { id in
            guard let draft = drafts[id] else { return nil }
            return draft.draftProfile
        }
    }
    private var report: ReadingPreparationReport {
        let participants = selectedProfiles.map(ProfileDirectory.assigningDefaultBirthTimeZone(to:))
        return ReadingPreparationPolicy.evaluate(plan: plan, participants: participants, descriptors: store.registry.descriptors)
    }
    private var offersLocalFallback: Bool {
        report.blockedMandatoryMethods.contains(where: \.usesPersonalProfile) && store.registry.plugin(.xiaoliuren) != nil
    }
    private var requestsNumbers: Bool {
        plan.methods.contains(.meihua) && (plan.requiredFields.contains(.numbers) || (plan.interactions ?? []).contains { $0.kind == .numbers })
    }
    private var draftNumbers: [Int] {
        guard numberTexts.contains(where: { !$0.isEmpty }) else { return [] }
        return numberTexts.map { Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0 }
    }
    private var draftSnapshot: DraftSnapshot {
        DraftSnapshot(profiles: selectedProfiles, numbers: draftNumbers)
    }

    var body: some View {
        NavigationStack {
            ZStack {
                PaperBackground()
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        questionCard
                        if !store.profiles.isEmpty { savedPeople }
                        selectedPeople
                        Button(action: addPerson) {
                            Label("新增一位人员", systemImage: "person.badge.plus")
                                .font(.system(size: 14, design: .serif)).frame(maxWidth: .infinity, alignment: .leading)
                                .padding(17).foregroundStyle(InkTheme.cinnabar)
                                .background(.white.opacity(0.45), in: RoundedRectangle(cornerRadius: 13))
                                .overlay(RoundedRectangle(cornerRadius: 13).stroke(InkTheme.line, lineWidth: 0.7))
                        }.buttonStyle(.plain).accessibilityIdentifier("addParticipant")
                        if requestsNumbers { numbersCard }
                        preparationCard
                        if !selectedIDs.isEmpty {
                            Toggle("把这些人员资料留在本机", isOn: $keepProfiles)
                                .font(.system(size: 13, design: .serif)).tint(InkTheme.sage)
                                .accessibilityIdentifier("saveParticipantProfiles")
                        }
                        if let displayedError = error ?? store.intakeError {
                            Text(displayedError).font(.system(size: 12)).foregroundStyle(InkTheme.cinnabar)
                                .accessibilityIdentifier("intakeValidationError")
                        }
                        Button { confirm() } label: {
                            HStack { Text("确认资料并开始"); Image(systemName: "arrow.right") }
                        }.buttonStyle(InkPrimaryButton()).accessibilityIdentifier("confirmIntake")
                            .disabled(store.isBusy)
                        if offersLocalFallback {
                            Button("改用小六壬") { confirm(useLocalFallback: true) }
                                .font(.system(size: 14, design: .serif)).tint(InkTheme.cinnabar)
                                .frame(maxWidth: .infinity, minHeight: 44)
                                .disabled(store.isBusy)
                                .accessibilityIdentifier("confirmIntakeWithLocalFallback")
                        }
                        Text("每人的资料分别保存、分别推演。确认后，抽牌或投掷会接着进行。")
                            .font(.system(size: 10)).lineSpacing(4).foregroundStyle(InkTheme.secondary)
                    }.padding(24).frame(maxWidth: 760).frame(maxWidth: .infinity)
                }.scrollDismissesKeyboard(.interactively).accessibilityIdentifier("intakeFormScroll")
            }
            .navigationTitle("问事资料").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("稍后填写") { saveUnsubmittedDraft(); dismiss() }.font(.system(size: 13)).foregroundStyle(InkTheme.secondary)
                        .accessibilityIdentifier("cancelIntake")
                }
            }
            .toolbarBackground(InkTheme.paper, for: .navigationBar).toolbarBackground(.visible, for: .navigationBar)
            .onAppear {
                if selectedIDs.isEmpty && store.profiles.isEmpty {
                    for _ in 0..<minimumCount { addPerson() }
                }
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .background { saveUnsubmittedDraft() }
            }
            .onReceive(NotificationCenter.default.publisher(for: UIScene.willDeactivateNotification)) { _ in
                saveUnsubmittedDraft()
            }
            .task(id: draftSnapshot) {
                // Coalesce typing while keeping a recent on-disk draft before suspension.
                do { try await Task.sleep(for: .milliseconds(350)) }
                catch { return }
                saveUnsubmittedDraft()
            }
            .onDisappear(perform: saveUnsubmittedDraft)
        }.presentationDragIndicator(.visible)
    }

    private func saveUnsubmittedDraft() {
        guard !submitted, let onDraftChange else { return }
        let snapshot = draftSnapshot
        guard savedDraft != snapshot else { return }
        savedDraft = snapshot
        onDraftChange(snapshot.profiles, snapshot.numbers)
    }

    private var questionCard: some View {
        PaperCard {
            VStack(alignment: .leading, spacing: 13) {
                SectionEyebrow(text: "此次所问")
                Text(plan.question).font(.system(size: 19, design: .serif)).lineSpacing(7).foregroundStyle(InkTheme.ink)
                Text("填写已知的资料，其余可以留空。")
                    .font(.system(size: 12, design: .serif)).foregroundStyle(InkTheme.secondary).lineSpacing(4)
                Text("本次方法：" + OracleMethod.allCases.filter { plan.methods.contains($0) }.map(\.progressName).joined(separator: "、"))
                    .font(.system(size: 11)).foregroundStyle(InkTheme.secondary)
            }
        }
    }

    private var savedPeople: some View {
        PaperCard {
            VStack(alignment: .leading, spacing: 15) {
                SectionEyebrow(text: "选取留存人员 · 可多选")
                ForEach(store.profiles) { stored in
                    let profile = drafts[stored.id]?.profile ?? stored
                    let selected = selectedIDs.contains(stored.id)
                    Button { toggle(stored) } label: {
                        HStack(spacing: 12) {
                            Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                                .font(.system(size: 19)).foregroundStyle(selected ? InkTheme.sage : InkTheme.line)
                            Text(title(profile)).font(.system(size: 15, design: .serif)).foregroundStyle(InkTheme.ink)
                            Spacer()
                            Text(selected ? "已选" : "选取").font(.system(size: 11)).foregroundStyle(InkTheme.secondary)
                        }.contentShape(Rectangle())
                    }.buttonStyle(.plain).accessibilityLabel("\(title(profile))，\(selected ? "已选" : "未选")")
                        .accessibilityIdentifier("selectProfile-\(stored.id.uuidString)")
                }
            }
        }
    }

    private var selectedPeople: some View {
        VStack(alignment: .leading, spacing: 24) {
            HStack {
                SectionEyebrow(text: "本次人员")
                Spacer()
                Text("已选 \(selectedIDs.count) 人").font(.system(size: 11)).foregroundStyle(InkTheme.secondary)
            }
            if selectedIDs.isEmpty {
                Text(minimumCount == 0 ? "此次可以只看事情本身，也可选取人员资料。" : "请从上方选取人员，或新增后直接填写。")
                    .font(.system(size: 13, design: .serif)).lineSpacing(5).foregroundStyle(InkTheme.secondary)
            }
            ForEach(selectedIDs, id: \.self) { id in
                VStack(alignment: .leading, spacing: 16) {
                    HStack {
                        Text(title(drafts[id]?.profile)).font(.system(size: 19, design: .serif)).foregroundStyle(InkTheme.ink)
                        Spacer()
                        Button { selectedIDs.removeAll { $0 == id } } label: {
                            Label("移除", systemImage: "xmark.circle").font(.system(size: 12))
                        }.buttonStyle(.plain).foregroundStyle(InkTheme.secondary)
                            .accessibilityLabel("移除\(title(drafts[id]?.profile))")
                            .accessibilityIdentifier("removeParticipant-\(id.uuidString)")
                    }
                    ProfileFieldsView(draft: binding(for: id))
                }.accessibilityElement(children: .contain).accessibilityIdentifier("participantForm-\(id.uuidString)")
            }
        }.accessibilityElement(children: .contain).accessibilityIdentifier("selectedParticipants")
    }

    private var numbersCard: some View {
        PaperCard {
            VStack(alignment: .leading, spacing: 13) {
                SectionEyebrow(text: "随心留数")
                Text("凭心意填写三个1到999的整数。")
                    .font(.system(size: 12, design: .serif)).foregroundStyle(InkTheme.secondary)
                HStack(spacing: 16) {
                    ForEach(0..<3, id: \.self) { index in
                        TextField("第\(index + 1)个数", text: $numberTexts[index]).keyboardType(.numberPad)
                            .textFieldStyle(.roundedBorder).accessibilityIdentifier("intakeNumber-\(index)")
                    }
                }
            }
        }
    }

    private var preparationCard: some View {
        let review = report
        let blocked = review.assessments.filter { (plan.mandatoryMethods ?? []).contains($0.method) && !$0.canExecute }
        let limitations = review.assessments.flatMap { assessment in
            assessment.limitations.map { "\(assessment.participantName.map { $0 + " · " } ?? "")\(assessment.method.progressName)：\($0)" }
        }
        return PaperCard {
            VStack(alignment: .leading, spacing: 13) {
                SectionEyebrow(text: "确认前核对")
                if selectedIDs.count < minimumCount {
                    Text(minimumCount > 1 ? "此次需要至少两位人员。" : "请选择或新增一位人员。")
                        .foregroundStyle(InkTheme.cinnabar)
                }
                if review.runnableMethods.contains(.xiaoliuren), !plan.methods.contains(.xiaoliuren) {
                    Text("当前资料不足以完成所选方法，将用小六壬提供问事参考。")
                        .foregroundStyle(InkTheme.secondary)
                        .accessibilityIdentifier("intakeFallbackNotice")
                }
                ForEach(Array(blocked.enumerated()), id: \.offset) { _, assessment in
                    VStack(alignment: .leading, spacing: 6) {
                        Text("\(assessment.participantName.map { $0 + " · " } ?? "")\(assessment.method.progressName)还需要补充")
                            .fontWeight(.medium)
                        ForEach(Array(assessment.blocking.enumerated()), id: \.offset) { _, gap in Text("• " + gap.reason) }
                        if let reason = assessment.unavailableReason { Text(reason) }
                    }.foregroundStyle(InkTheme.cinnabar)
                }
                ForEach(Array(review.omissions.enumerated()), id: \.offset) { _, omission in
                    Text("本次将跳过\(omission.participantName.map { $0 + "的" } ?? "")\(omission.method.progressName)：\(omission.reason)")
                        .foregroundStyle(InkTheme.secondary)
                }
                ForEach(Array(limitations.enumerated()), id: \.offset) { _, limitation in
                    Text(limitation).foregroundStyle(InkTheme.secondary)
                }
                if !review.strictBlocked && review.omissions.isEmpty && limitations.isEmpty && selectedIDs.count >= minimumCount {
                    Text("资料已备齐，可确认后继续。").foregroundStyle(InkTheme.sage)
                }
            }.font(.system(size: 12, design: .serif)).lineSpacing(4)
        }.accessibilityElement(children: .contain).accessibilityIdentifier("intakePreparationReview")
    }

    private func title(_ profile: OracleProfile?) -> String {
        profile?.participantLabel ?? "人员资料"
    }

    private func binding(for id: UUID) -> Binding<ProfileFormDraft> {
        Binding(get: { drafts[id] ?? ProfileFormDraft(profile: OracleProfile(id: id)) }, set: { drafts[id] = $0 })
    }

    private func addPerson() {
        let person = OracleProfile()
        drafts[person.id] = ProfileFormDraft(profile: person)
        selectedIDs.append(person.id)
    }

    private func toggle(_ profile: OracleProfile) {
        if selectedIDs.contains(profile.id) { selectedIDs.removeAll { $0 == profile.id } }
        else {
            if drafts[profile.id] == nil { drafts[profile.id] = ProfileFormDraft(profile: profile) }
            selectedIDs.append(profile.id)
        }
    }

    private func confirm(useLocalFallback: Bool = false) {
        var people: [OracleProfile] = []
        var errors: [String] = []
        let requiredCount = useLocalFallback && plan.subject != "多人" ? 0 : minimumCount
        if selectedIDs.count < requiredCount {
            errors.append(requiredCount > 1 ? "请选好至少两位人员。" : "请选择或新增这次要看的人员。")
        }
        for id in selectedIDs {
            guard let draft = drafts[id] else { continue }
            do {
                let profile = try draft.validatedProfile()
                people.append(ProfileDirectory.assigningDefaultBirthTimeZone(to: profile))
            }
            catch { errors.append("\(title(draft.profile))：\(error.localizedDescription)") }
        }
        let numbers = draftNumbers
        if !useLocalFallback, requestsNumbers && (numbers.count != 3 || !numbers.allSatisfy { (1...999).contains($0) }) {
            errors.append("请填写三个1到999的整数。")
        }
        let review = ReadingPreparationPolicy.evaluate(plan: plan, participants: people, descriptors: store.registry.descriptors)
        if !useLocalFallback, !review.canProceed {
            let blocked = review.assessments.filter { (plan.mandatoryMethods ?? []).contains($0.method) && !$0.canExecute }
            errors += blocked.map { assessment in
                let reasons = assessment.blocking.map(\.reason) + [assessment.unavailableReason].compactMap { $0 }
                return "\(assessment.participantName.map { $0 + " · " } ?? "")\(assessment.method.progressName)：\(reasons.joined(separator: "；"))"
            }
            if blocked.isEmpty { errors.append("当前资料还不能完成所选方法，请补充资料后再确认。") }
        }
        guard errors.isEmpty else { error = errors.joined(separator: "\n"); return }
        error = nil
        if onConfirm(people, requestsNumbers && !useLocalFallback ? numbers : [], keepProfiles, useLocalFallback) {
            submitted = true
        } else {
            error = store.intakeError ?? "资料尚未确认，请核对后再试。"
        }
    }
}

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
                            Label(L10n.text("新增一位人员", "Add a person"), systemImage: "person.badge.plus")
                                .font(.system(size: 14, design: .serif)).frame(maxWidth: .infinity, alignment: .leading)
                                .padding(17).foregroundStyle(InkTheme.cinnabar)
                                .background(.white.opacity(0.45), in: RoundedRectangle(cornerRadius: 13))
                                .overlay(RoundedRectangle(cornerRadius: 13).stroke(InkTheme.line, lineWidth: 0.7))
                        }.buttonStyle(.plain).accessibilityIdentifier("addParticipant")
                        if requestsNumbers { numbersCard }
                        preparationCard
                        if !selectedIDs.isEmpty {
                            Toggle(L10n.text("把这些人员资料留在本机", "Save these profiles on this device"), isOn: $keepProfiles)
                                .font(.system(size: 13, design: .serif)).tint(InkTheme.sage)
                                .accessibilityIdentifier("saveParticipantProfiles")
                        }
                        if let displayedError = error ?? store.intakeError {
                            Text(displayedError).font(.system(size: 12)).foregroundStyle(InkTheme.cinnabar)
                                .accessibilityIdentifier("intakeValidationError")
                        }
                        Button { confirm() } label: {
                            HStack { Text(L10n.text("确认资料并开始", "Confirm and begin")); Image(systemName: "arrow.right") }
                        }.buttonStyle(InkPrimaryButton()).accessibilityIdentifier("confirmIntake")
                            .disabled(store.isBusy)
                        if offersLocalFallback {
                            Button(L10n.text("改用小六壬", "Use Xiao Liu Ren instead")) { confirm(useLocalFallback: true) }
                                .font(.system(size: 14, design: .serif)).tint(InkTheme.cinnabar)
                                .frame(maxWidth: .infinity, minHeight: 44)
                                .disabled(store.isBusy)
                                .accessibilityIdentifier("confirmIntakeWithLocalFallback")
                        }
                        Text(L10n.text("每人的资料分别保存、分别推演。确认后，抽牌或投掷会接着进行。", "Each person’s details are saved and used separately. After you confirm, you can draw cards or cast if needed."))
                            .font(.system(size: 10)).lineSpacing(4).foregroundStyle(InkTheme.secondary)
                    }.padding(24).frame(maxWidth: 760).frame(maxWidth: .infinity)
                }.scrollDismissesKeyboard(.interactively).accessibilityIdentifier("intakeFormScroll")
            }
            .navigationTitle(L10n.text("问事资料", "Reading details")).navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(L10n.text("稍后填写", "Finish later")) { saveUnsubmittedDraft(); dismiss() }.font(.system(size: 13)).foregroundStyle(InkTheme.secondary)
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
                SectionEyebrow(text: L10n.text("此次所问", "Your question"))
                Text(plan.question).font(.system(size: 19, design: .serif)).lineSpacing(7).foregroundStyle(InkTheme.ink)
                Text(L10n.text("填写已知的资料，其余可以留空。", "Enter what you know. You can leave the rest blank."))
                    .font(.system(size: 12, design: .serif)).foregroundStyle(InkTheme.secondary).lineSpacing(4)
                let methods = OracleMethod.allCases.filter { plan.methods.contains($0) }.map(\.progressName)
                    .joined(separator: L10n.text("、", ", "))
                Text(L10n.text("本次方法：\(methods)", "Methods: \(methods)"))
                    .font(.system(size: 11)).foregroundStyle(InkTheme.secondary)
            }
        }
    }

    private var savedPeople: some View {
        PaperCard {
            VStack(alignment: .leading, spacing: 15) {
                SectionEyebrow(text: L10n.text("选取留存人员 · 可多选", "Choose saved profiles"))
                ForEach(store.profiles) { stored in
                    let profile = drafts[stored.id]?.profile ?? stored
                    let selected = selectedIDs.contains(stored.id)
                    Button { toggle(stored) } label: {
                        HStack(spacing: 12) {
                            Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                                .font(.system(size: 19)).foregroundStyle(selected ? InkTheme.sage : InkTheme.line)
                            Text(title(profile)).font(.system(size: 15, design: .serif)).foregroundStyle(InkTheme.ink)
                            Spacer()
                            Text(selected ? L10n.text("已选", "Selected") : L10n.text("选取", "Select")).font(.system(size: 11)).foregroundStyle(InkTheme.secondary)
                        }.contentShape(Rectangle())
                    }.buttonStyle(.plain)
                        .accessibilityLabel([title(profile), selected ? L10n.text("已选", "Selected") : L10n.text("未选", "Not selected")]
                            .joined(separator: L10n.text("，", ", ")))
                        .accessibilityIdentifier("selectProfile-\(stored.id.uuidString)")
                }
            }
        }
    }

    private var selectedPeople: some View {
        VStack(alignment: .leading, spacing: 24) {
            HStack {
                SectionEyebrow(text: L10n.text("本次人员", "People in this reading"))
                Spacer()
                Text(L10n.text("已选 \(selectedIDs.count) 人", "Selected: \(selectedIDs.count)")).font(.system(size: 11)).foregroundStyle(InkTheme.secondary)
            }
            if selectedIDs.isEmpty {
                Text(minimumCount == 0 ? L10n.text("此次可以只看事情本身，也可选取人员资料。", "You can read for the question alone or include someone’s profile.") : L10n.text("请从上方选取人员，或新增后直接填写。", "Choose a profile above or add a person."))
                    .font(.system(size: 13, design: .serif)).lineSpacing(5).foregroundStyle(InkTheme.secondary)
            }
            ForEach(selectedIDs, id: \.self) { id in
                VStack(alignment: .leading, spacing: 16) {
                    HStack {
                        Text(title(drafts[id]?.profile)).font(.system(size: 19, design: .serif)).foregroundStyle(InkTheme.ink)
                        Spacer()
                        Button { selectedIDs.removeAll { $0 == id } } label: {
                            Label(L10n.text("移除", "Remove"), systemImage: "xmark.circle").font(.system(size: 12))
                        }.buttonStyle(.plain).foregroundStyle(InkTheme.secondary)
                            .accessibilityLabel(L10n.text("移除\(title(drafts[id]?.profile))", "Remove \(title(drafts[id]?.profile))"))
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
                SectionEyebrow(text: L10n.text("随心留数", "Choose your numbers"))
                Text(L10n.text("凭心意填写三个1到999的整数。", "Enter any three whole numbers from 1 to 999."))
                    .font(.system(size: 12, design: .serif)).foregroundStyle(InkTheme.secondary)
                HStack(spacing: 16) {
                    ForEach(0..<3, id: \.self) { index in
                        TextField(L10n.text("第\(index + 1)个数", "Number \(index + 1)"), text: $numberTexts[index]).keyboardType(.numberPad)
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
            let method = (assessment.participantName.map { $0 + " · " } ?? "") + assessment.method.progressName
            return assessment.limitations.map { method + L10n.text("：", ": ") + $0 }
        }
        return PaperCard {
            VStack(alignment: .leading, spacing: 13) {
                SectionEyebrow(text: L10n.text("确认前核对", "Before you confirm"))
                if selectedIDs.count < minimumCount {
                    Text(minimumCount > 1 ? L10n.text("此次需要至少两位人员。", "This reading needs at least two people.") : L10n.text("请选择或新增一位人员。", "Choose or add a person."))
                        .foregroundStyle(InkTheme.cinnabar)
                }
                if review.runnableMethods.contains(.xiaoliuren), !plan.methods.contains(.xiaoliuren) {
                    Text(L10n.text("当前资料不足以完成所选方法，将用小六壬提供问事参考。", "The selected methods need more details. This reading will use Xiao Liu Ren instead."))
                        .foregroundStyle(InkTheme.secondary)
                        .accessibilityIdentifier("intakeFallbackNotice")
                }
                ForEach(Array(blocked.enumerated()), id: \.offset) { _, assessment in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(L10n.text("\(assessment.participantName.map { $0 + " · " } ?? "")\(assessment.method.progressName)还需要补充", "\(assessment.participantName.map { $0 + " · " } ?? "")\(assessment.method.progressName) needs more details"))
                            .fontWeight(.medium)
                        ForEach(Array(assessment.blocking.enumerated()), id: \.offset) { _, gap in Text("• " + gap.reason) }
                        if let reason = assessment.unavailableReason { Text(reason) }
                    }.foregroundStyle(InkTheme.cinnabar)
                }
                ForEach(Array(review.omissions.enumerated()), id: \.offset) { _, omission in
                    Text(L10n.text("本次将跳过\(omission.participantName.map { $0 + "的" } ?? "")\(omission.method.progressName)：\(omission.reason)", "Skipping \(omission.method.progressName)\(omission.participantName.map { " for " + $0 } ?? ""): \(omission.reason)"))
                        .foregroundStyle(InkTheme.secondary)
                }
                ForEach(Array(limitations.enumerated()), id: \.offset) { _, limitation in
                    Text(limitation).foregroundStyle(InkTheme.secondary)
                }
                if !review.strictBlocked && review.omissions.isEmpty && limitations.isEmpty && selectedIDs.count >= minimumCount {
                    Text(L10n.text("资料已备齐，可确认后继续。", "Everything is ready. Confirm to continue.")).foregroundStyle(InkTheme.sage)
                }
            }.font(.system(size: 12, design: .serif)).lineSpacing(4)
        }.accessibilityElement(children: .contain).accessibilityIdentifier("intakePreparationReview")
    }

    private func title(_ profile: OracleProfile?) -> String {
        profile?.participantLabel ?? L10n.text("人员资料", "Profile")
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
            errors.append(requiredCount > 1 ? L10n.text("请选好至少两位人员。", "Choose at least two people.") : L10n.text("请选择或新增这次要看的人员。", "Choose or add a person for this reading."))
        }
        for id in selectedIDs {
            guard let draft = drafts[id] else { continue }
            do {
                let profile = try draft.validatedProfile()
                people.append(ProfileDirectory.assigningDefaultBirthTimeZone(to: profile))
            }
            catch { errors.append(title(draft.profile) + L10n.text("：", ": ") + error.localizedDescription) }
        }
        let numbers = draftNumbers
        if !useLocalFallback, requestsNumbers && (numbers.count != 3 || !numbers.allSatisfy { (1...999).contains($0) }) {
            errors.append(L10n.text("请填写三个1到999的整数。", "Enter three whole numbers from 1 to 999."))
        }
        let review = ReadingPreparationPolicy.evaluate(plan: plan, participants: people, descriptors: store.registry.descriptors)
        if !useLocalFallback, !review.canProceed {
            let blocked = review.assessments.filter { (plan.mandatoryMethods ?? []).contains($0.method) && !$0.canExecute }
            errors += blocked.map { assessment in
                let reasons = assessment.blocking.map(\.reason) + [assessment.unavailableReason].compactMap { $0 }
                let method = (assessment.participantName.map { $0 + " · " } ?? "") + assessment.method.progressName
                return method + L10n.text("：", ": ") + reasons.joined(separator: L10n.text("；", ". "))
            }
            if blocked.isEmpty { errors.append(L10n.text("当前资料还不能完成所选方法，请补充资料后再确认。", "The selected methods need more details. Add them before confirming.")) }
        }
        guard errors.isEmpty else { error = errors.joined(separator: "\n"); return }
        error = nil
        if onConfirm(people, requestsNumbers && !useLocalFallback ? numbers : [], keepProfiles, useLocalFallback) {
            submitted = true
        } else {
            error = store.intakeError ?? L10n.text("资料尚未确认，请核对后再试。", "Couldn’t confirm the details. Review them and try again.")
        }
    }
}

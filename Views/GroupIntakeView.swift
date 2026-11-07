import SwiftUI
import UIKit

/// Every participant keeps a separate draft; one confirmation freezes them all.
struct GroupIntakeView: View {
    private struct DraftSnapshot: Equatable {
        let profiles: [OracleProfile]
        let numbers: [Int]
        let castingProfile: OracleProfile
    }

    let plan: OraclePlan
    let onDraftChange: (([OracleProfile], [Int], OracleProfile) -> Void)?
    let onConfirm: ([OracleProfile], [Int], OracleProfile, Bool) -> Bool
    private let draftNumbers: [Int]
    @EnvironmentObject private var store: OracleStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var drafts: [UUID: ProfileFormDraft]
    @State private var selectedIDs: [UUID]
    @State private var casting: CastingLocationDraft
    @StateObject private var castingLocation = LocationService()
    @State private var locationState = CastingLocationRequestState()
    @State private var locationError: String?
    @State private var choosingCastingLocation = false
    @State private var keepProfiles = true
    @State private var error: String?
    @State private var validationAttempt = 0
    @State private var submitted = false
    @State private var savedDraft: DraftSnapshot?

    init(plan: OraclePlan, profiles: [OracleProfile], numbers: [Int] = [],
         onDraftChange: (([OracleProfile], [Int]) -> Void)? = nil,
         onConfirm: @escaping ([OracleProfile], [Int], Bool) -> Bool) {
        self.init(plan: plan, profiles: profiles, numbers: numbers, castingProfile: plan.castingProfile,
                  onDraftChange: onDraftChange.map { callback in { people, values, _ in callback(people, values) } },
                  onConfirm: { people, values, _, save in onConfirm(people, values, save) })
    }

    init(plan: OraclePlan, profiles: [OracleProfile], numbers: [Int] = [], castingProfile: OracleProfile?,
         onDraftChange: (([OracleProfile], [Int], OracleProfile) -> Void)? = nil,
         onConfirm: @escaping ([OracleProfile], [Int], OracleProfile, Bool) -> Bool) {
        self.plan = plan; self.onDraftChange = onDraftChange; self.onConfirm = onConfirm
        self.draftNumbers = numbers
        var values: [UUID: ProfileFormDraft] = [:]
        var ids: [UUID] = []
        for profile in profiles where values[profile.id] == nil {
            values[profile.id] = ProfileFormDraft(profile: profile); ids.append(profile.id)
        }
        _drafts = State(initialValue: values)
        _selectedIDs = State(initialValue: ids)
        _casting = State(initialValue: CastingLocationDraft(profile: castingProfile ?? plan.castingProfile ?? OracleProfile()))
    }

    private var minimumCount: Int {
        guard plan.methods.contains(where: \.usesPersonalProfile) else { return 0 }
        return plan.subject == "多人" ? 2 : 1
    }
    private var selectedProfiles: [OracleProfile] {
        selectedIDs.compactMap { id in
            guard let draft = drafts[id] else { return nil }
            return draft.draftProfile
        }
    }
    private var report: ReadingPreparationReport {
        let participants = selectedProfiles.map(ProfileDirectory.assigningDefaultBirthTimeZone(to:))
        return ReadingPreparationPolicy.evaluate(plan: plan, participants: participants, descriptors: store.registry.descriptors,
                                                 castingProfile: casting.profile, numbers: draftNumbers)
    }
    private var needsCastingLocation: Bool {
        let methods = Set(plan.methods + (plan.mandatoryMethods ?? []) + report.assessments.map(\.method))
        return methods.contains { ReadingPreparationPolicy.requiresCastingLocation(plan: plan, method: $0, numbers: draftNumbers) }
    }
    private var draftSnapshot: DraftSnapshot {
        DraftSnapshot(profiles: selectedProfiles, numbers: draftNumbers, castingProfile: casting.profile)
    }

    var body: some View {
        NavigationStack {
            ZStack {
                PaperBackground()
                ScrollViewReader { scroll in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 24) {
                            if let displayedError = error ?? store.intakeError {
                                Text(displayedError).font(.system(size: 12)).foregroundStyle(InkTheme.cinnabar)
                                    .accessibilityIdentifier("intakeValidationError")
                                    .id("intakeValidationError")
                            }
                            questionCard
                            if needsCastingLocation { castingLocationCard }
                            if !store.profiles.isEmpty { savedPeople }
                            selectedPeople
                            Button(action: addPerson) {
                                Label(L10n.text("新增一位人员", "Add a person"), systemImage: "person.badge.plus")
                                    .font(.system(size: 14, design: .serif)).frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(17).foregroundStyle(InkTheme.cinnabar)
                                    .background(.white.opacity(0.45), in: RoundedRectangle(cornerRadius: 13))
                                    .overlay(RoundedRectangle(cornerRadius: 13).stroke(InkTheme.line, lineWidth: 0.7))
                            }.buttonStyle(.plain).accessibilityIdentifier("addParticipant")
                            preparationCard
                            if !selectedIDs.isEmpty {
                                Toggle(L10n.text("把这些人员资料留在本机", "Save these profiles on this device"), isOn: $keepProfiles)
                                    .font(.system(size: 13, design: .serif)).tint(InkTheme.sage)
                                    .accessibilityIdentifier("saveParticipantProfiles")
                            }
                            Text(L10n.text("每人的资料分别保存、分别推演。确认后，抽牌或投掷会接着进行。", "Each person’s details are saved and used separately. After you confirm, you can draw cards or cast if needed."))
                                .font(.system(size: 10)).lineSpacing(4).foregroundStyle(InkTheme.secondary)
                        }.padding(24).frame(maxWidth: 760).frame(maxWidth: .infinity)
                    }.scrollDismissesKeyboard(.interactively).accessibilityIdentifier("intakeFormScroll")
                    .onChange(of: validationAttempt) { _, _ in
                        if error != nil || store.intakeError != nil {
                            withAnimation { scroll.scrollTo("intakeValidationError", anchor: .top) }
                        }
                    }
                }
            }
            .navigationTitle(L10n.text("问事资料", "Reading details")).navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(L10n.text("取消本次问事", "Cancel reading"), role: .cancel) {
                        cancelCastingLocation()
                        submitted = true
                        store.cancelPendingReading()
                        dismiss()
                    }.font(.system(size: 13)).foregroundStyle(InkTheme.secondary)
                        .accessibilityIdentifier("cancelPendingIntake")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(L10n.text("确认并继续", "Confirm and continue"), action: confirm)
                        .font(.system(size: 14, weight: .semibold)).foregroundStyle(InkTheme.cinnabar)
                        .accessibilityIdentifier("confirmIntake")
                        .disabled(store.isBusy || locationState.isWaiting)
                }
            }
            .toolbarBackground(InkTheme.paper, for: .navigationBar).toolbarBackground(.visible, for: .navigationBar)
            .onAppear {
                if selectedIDs.isEmpty && store.profiles.isEmpty {
                    for _ in 0..<minimumCount { addPerson() }
                }
                requestAutomaticCastingLocation()
            }
            .onChange(of: needsCastingLocation) { _, required in
                if required { requestAutomaticCastingLocation() }
                else { cancelCastingLocation() }
            }
            .onReceive(castingLocation.$place, perform: receiveCastingLocation)
            .onReceive(castingLocation.$message, perform: receiveCastingLocationError)
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
            .onDisappear {
                cancelCastingLocation()
                saveUnsubmittedDraft()
            }
        }
        .sheet(isPresented: $choosingCastingLocation) {
            ChinaDistrictPicker(title: L10n.text("选择起卦地点", "Choose the casting location")) { district in
                cancelCastingLocation()
                casting.select(district)
                error = nil
                saveUnsubmittedDraft()
            }
        }
        .presentationDragIndicator(.visible)
    }

    private func saveUnsubmittedDraft() {
        guard !submitted, let onDraftChange else { return }
        let snapshot = draftSnapshot
        guard savedDraft != snapshot else { return }
        savedDraft = snapshot
        onDraftChange(snapshot.profiles, snapshot.numbers, snapshot.castingProfile)
    }

    private var hasCastingLocation: Bool {
        TrueSolarClock.castingCoordinates(profile: casting.profile) != nil
            && TimeZone(identifier: casting.profile.currentTimeZoneID) != nil
    }

    private func requestAutomaticCastingLocation() {
        guard !submitted, !choosingCastingLocation,
              locationState.beginAutomatic(needsLocation: needsCastingLocation,
                  isSupplement: plan.baseRunID != nil, hasLocation: hasCastingLocation,
                  explicitlyCleared: casting.profile.unknownFields.contains(.currentLocation)
                      || casting.profile.declaredUnknownFields?.contains(.currentLocation) == true) != nil else { return }
        locationError = nil
        // Establish the consumer latch before request(): disabled permissions
        // and services can publish an error synchronously.
        castingLocation.request()
    }

    private func requestCurrentCastingLocation() {
        cancelCastingLocation()
        guard !submitted, !choosingCastingLocation,
              locationState.beginManual(needsLocation: needsCastingLocation) != nil else { return }
        castingLocation.request()
    }

    private func cancelCastingLocation() {
        locationState.cancel()
        castingLocation.cancel()
        locationError = nil
    }

    private func receiveCastingLocation(_ place: LocalPlace?) {
        guard !submitted, needsCastingLocation, !choosingCastingLocation,
              let requestID = locationState.requestID, let place,
              locationState.finish(requestID: requestID) else { return }
        castingLocation.cancel()
        guard place.apply(to: &casting.profile, purpose: .current) else {
            locationError = LocationLookupError.unavailable.localizedDescription
            return
        }
        locationError = nil
        error = nil
        saveUnsubmittedDraft()
    }

    private func receiveCastingLocationError(_ message: String?) {
        guard !submitted, let requestID = locationState.requestID, let message,
              locationState.finish(requestID: requestID) else { return }
        castingLocation.cancel()
        locationError = message
    }

    private var questionCard: some View {
        PaperCard {
            VStack(alignment: .leading, spacing: 13) {
                SectionEyebrow(text: L10n.text("此次所问", "Your question"))
                Text(plan.question).font(.system(size: 19, design: .serif)).lineSpacing(7).foregroundStyle(InkTheme.ink)
                    .accessibilityIdentifier("intakeQuestion")
                Text(L10n.text("填写已知资料；所选方法缺少必要信息时，会在下方说明。", "Enter what you know. Missing details required by the selected methods are listed below."))
                    .font(.system(size: 12, design: .serif)).foregroundStyle(InkTheme.secondary).lineSpacing(4)
                let methods = OracleMethod.allCases.filter { plan.methods.contains($0) }.map(\.progressName)
                    .joined(separator: L10n.text("、", ", "))
                Text(L10n.text("本次方法：\(methods)", "Methods: \(methods)"))
                    .font(.system(size: 11)).foregroundStyle(InkTheme.secondary)
                let castingModes = [
                    plan.methods.contains(.meihua) ? plan.meihuaCastingMode.map { L10n.text("梅花 · ", "Meihua · ") + $0.title } : nil,
                    plan.methods.contains(.liuyao) ? plan.liuyaoCastingMode.map { L10n.text("六爻 · ", "Liuyao · ") + $0.title } : nil
                ].compactMap { $0 }
                if !castingModes.isEmpty {
                    Text(castingModes.joined(separator: L10n.text("；", "; ")))
                        .font(.system(size: 11)).foregroundStyle(InkTheme.secondary)
                        .accessibilityIdentifier("castingModeSummary")
                }
            }
        }
    }

    private var castingLocationCard: some View {
        let place = ChinaDistrictCatalog.shared.displayName(for: casting.profile.currentDistrictCode, canonical: casting.profile.currentPlace)
        let coordinates = TrueSolarClock.castingCoordinates(profile: casting.profile)
        return PaperCard {
            VStack(alignment: .leading, spacing: 13) {
                SectionEyebrow(text: L10n.text("起卦地点 · 本次问事共用", "Casting location · shared for this reading"))
                Text(plan.baseRunID == nil
                     ? L10n.text("自动使用当前位置换算真太阳时。无法定位时可手动选择，无需填写人员资料。", "Your current location is used for apparent solar time. If unavailable, choose a place manually. No person’s details are needed.")
                     : L10n.text("沿用原问事的地点。需要更改时，可重新定位或手动选择。", "The original reading’s location is kept. Locate again or choose manually if it needs to change."))
                    .font(.system(size: 12, design: .serif)).foregroundStyle(InkTheme.secondary).lineSpacing(4)
                    .accessibilityIdentifier("castingLocationExplanation")
                if locationState.isWaiting {
                    HStack(spacing: 9) {
                        ProgressView().tint(InkTheme.sage)
                        Text(L10n.text("正在获取当前位置…", "Finding your current location…"))
                            .font(.system(size: 12)).foregroundStyle(InkTheme.secondary)
                    }.accessibilityElement(children: .combine).accessibilityIdentifier("castingLocationProgress")
                }
                Button(action: requestCurrentCastingLocation) {
                    Label(hasCastingLocation ? L10n.text("重新定位", "Locate again") : L10n.text("使用当前位置", "Use current location"), systemImage: "location")
                        .font(.system(size: 13, design: .serif)).foregroundStyle(InkTheme.sage)
                }.buttonStyle(.plain).disabled(locationState.isWaiting)
                    .accessibilityIdentifier("useCurrentCastingLocation")
                if let locationError {
                    Text(locationError).font(.system(size: 12)).foregroundStyle(InkTheme.cinnabar)
                        .accessibilityIdentifier("castingLocationError")
                }
                Button {
                    cancelCastingLocation()
                    choosingCastingLocation = true
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "mappin.and.ellipse").foregroundStyle(InkTheme.sage)
                        Text(place.isEmpty ? L10n.text("选择起卦地点", "Choose the casting location") : place)
                            .foregroundStyle(InkTheme.ink)
                        Spacer()
                        Image(systemName: "chevron.right").font(.system(size: 11)).foregroundStyle(InkTheme.secondary)
                    }.font(.system(size: 15, design: .serif)).contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityIdentifier("castingLocationButton")
                if let coordinates, TimeZone(identifier: casting.profile.currentTimeZoneID) != nil {
                    Text(L10n.text("时区：\(casting.profile.currentTimeZoneID) · 经度 \(String(format: "%.4f", coordinates.longitude))°", "Time zone: \(casting.profile.currentTimeZoneID) · Longitude \(String(format: "%.4f", coordinates.longitude))°"))
                        .font(.system(size: 11)).foregroundStyle(InkTheme.secondary)
                        .accessibilityIdentifier("castingLocationSummary")
                    if casting.profile.currentDistrictCode != nil {
                        Text(TrueSolarClock.coordinateLimitation).font(.system(size: 11)).foregroundStyle(InkTheme.secondary)
                    }
                } else if !locationState.isWaiting {
                    Text(L10n.text("请使用当前位置或手动选择地点后继续。", "Use your current location or choose a place manually to continue."))
                        .font(.system(size: 12)).foregroundStyle(InkTheme.cinnabar)
                        .accessibilityIdentifier("castingLocationRequired")
                }
                Button(L10n.text("清空起卦地点", "Clear casting location")) {
                    cancelCastingLocation()
                    casting.clear()
                    error = nil
                    saveUnsubmittedDraft()
                }.font(.system(size: 12)).foregroundStyle(InkTheme.secondary)
                    .accessibilityIdentifier("clearCastingLocation")
            }
        }.accessibilityElement(children: .contain).accessibilityIdentifier("castingLocationCard")
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
                    ProfileFieldsView(draft: binding(for: id), genderRequired: plan.methods.contains(.ziwei))
                }.accessibilityElement(children: .contain).accessibilityIdentifier("participantForm-\(id.uuidString)")
            }
        }.accessibilityElement(children: .contain).accessibilityIdentifier("selectedParticipants")
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
                if OracleInteractionPolicy.requests(for: plan, numbers: draftNumbers).contains(where: { $0.kind == .numbers }) {
                    Text(L10n.text("确认后进入随心留数，可随机生成或自行输入三个数。", "After confirming, generate three numbers or enter your own in the next step."))
                        .foregroundStyle(InkTheme.secondary)
                        .accessibilityIdentifier("pendingNumbersNotice")
                }
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

    private func confirm() {
        validationAttempt += 1
        var people: [OracleProfile] = []
        var errors: [String] = []
        let requiredCount = minimumCount
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
        let review = ReadingPreparationPolicy.evaluate(plan: plan, participants: people, descriptors: store.registry.descriptors,
                                                       castingProfile: casting.profile, numbers: numbers)
        if !review.canProceed {
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
        if onConfirm(people, plan.methods.contains(.meihua) ? numbers : [], casting.profile, keepProfiles) {
            cancelCastingLocation()
            submitted = true
        } else {
            error = store.intakeError ?? L10n.text("资料尚未确认，请核对后再试。", "Couldn’t confirm the details. Review them and try again.")
        }
    }
}

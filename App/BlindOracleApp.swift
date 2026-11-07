import BackgroundTasks
import SwiftUI
import UIKit
import AuthenticationServices

@main struct BlindOracleApp: App {
    @StateObject private var bootstrap = AppServiceLaunchCoordinator()
    init() {
        #if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("--ui-testing-local"), arguments.contains("--ui-testing-reset-language") {
            UserDefaults.standard.removeObject(forKey: AppLanguage.preferenceKey)
        }
        // A unit-test host shares the simulator's app domain with UI tests.
        // Begin it with defaults rather than a preceding UI run's choices.
        if AppServiceBootstrapPolicy.isUnitTestHost
            || (arguments.contains("--ui-testing-local") && arguments.contains("--ui-testing-reset")) {
            UserDefaults.standard.removeObject(forKey: CastingMethodPreferences.meihuaKey)
            UserDefaults.standard.removeObject(forKey: CastingMethodPreferences.liuyaoKey)
        }
        #endif
        let appearance = UITabBarAppearance()
        appearance.configureWithOpaqueBackground()
        appearance.backgroundColor = UIColor(InkTheme.paper)
        appearance.shadowColor = UIColor(InkTheme.line.withOpacity(0.4))
        UITabBar.appearance().standardAppearance = appearance
        UITabBar.appearance().scrollEdgeAppearance = appearance
    }
    var body: some Scene {
        WindowGroup {
            Group {
                switch bootstrap.state {
                case .resolving:
                    AppServiceLaunchSurface(isRecovering: false) { }
                case .recoveryRequired:
                    AppServiceLaunchSurface(isRecovering: true, failure: bootstrap.failure) {
                        Task { await bootstrap.retryFromUser() }
                    }
                case .ready(let context):
                    #if DEBUG
                    if AppServiceBootstrapPolicy.isUnitTestHost { AccountRestoringView() }
                    else { ResolvedBlindOracleRoot(context: context) }
                    #else
                    ResolvedBlindOracleRoot(context: context)
                    #endif
                }
            }
            .preferredColorScheme(.light).tint(InkTheme.cinnabar)
            .task { await bootstrap.resolve() }
        }
    }
}

private struct AppServiceLaunchSurface: View {
    let isRecovering: Bool
    var failure: AppServiceLaunchFailure? = nil
    let retry: () -> Void
    private var recoveryMessage: String {
        switch failure?.kind {
        case .network:
            return L10n.text("暂时无法连接 App Store，请检查网络后重新验证。", "Couldn’t connect to the App Store. Check your connection and try verifying again.")
        case .cancelled:
            return L10n.text("验证已取消，重新验证后即可继续。", "Verification was cancelled. Verify again to continue.")
        case .unverified:
            return L10n.text("App Store 凭据暂未通过验证，请重新验证后继续。", "Your App Store credentials couldn’t be verified. Verify again to continue.")
        default:
            return L10n.text("暂时无法验证 App Store 凭据，请重新验证后继续。", "Couldn’t verify your App Store credentials. Verify again to continue.")
        }
    }
    var body: some View {
        ZStack {
            PaperBackground()
            VStack(spacing: 20) {
                OracleMark(size: 80)
                Text(L10n.text("瞎子", "BlindOracle"))
                    .font(.system(size: 28, weight: .medium, design: .serif)).foregroundStyle(InkTheme.ink)
                if isRecovering {
                    Text(recoveryMessage)
                        .font(.subheadline).foregroundStyle(InkTheme.secondary).multilineTextAlignment(.center)
                    Button(L10n.text("重新验证 App Store", "Verify with App Store"), action: retry)
                        .buttonStyle(InkPrimaryButton()).accessibilityIdentifier("retryServiceEnvironment")
                    Text(L10n.text("系统可能要求验证你的 App Store 账号。", "You may be asked to authenticate your App Store account."))
                        .font(.caption).foregroundStyle(InkTheme.secondary).multilineTextAlignment(.center)
                    if let failure {
                        Text(L10n.text("验证代码：", "Verification code: ") + failure.diagnosticCode)
                            .font(.caption2).foregroundStyle(InkTheme.secondary).textSelection(.enabled)
                            .accessibilityIdentifier("serviceEnvironmentFailureCode")
                    }
                } else {
                    ProgressView().controlSize(.small).tint(InkTheme.secondary)
                        .accessibilityLabel(L10n.text("正在准备应用", "Preparing the app"))
                }
            }.padding(28).frame(maxWidth: 460).padding(.bottom, 30)
        }.accessibilityIdentifier(isRecovering ? "serviceEnvironmentRecovery" : "serviceEnvironmentLaunch")
    }
}

/// No account/session/task service exists until the outer launcher freezes its route.
private struct ResolvedBlindOracleRoot: View {
    let context: AppServiceContext
    @StateObject private var store: OracleStore
    @StateObject private var account: AccountStore
    @StateObject private var purchases = AccountPurchaseStore()
    @State private var analysisBackgroundExecution = AnalysisBackgroundExecution()
    @State private var chatDraft = ""
    @State private var settingsPresented = false
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage(AppLanguage.preferenceKey) private var preference: AppLanguagePreference = .system
    init(context: AppServiceContext) {
        self.context = context
        let oracle = OracleStore()
        _store = StateObject(wrappedValue: oracle)
        _account = StateObject(wrappedValue: AccountStore.makeAppStore(localDataErasure: { [weak oracle] in
            guard let oracle else { throw AccountAPIError.storage }
            try await oracle.eraseLocalDataAfterAccountDeletion()
        }))
    }
    var body: some View {
        VStack(spacing: 0) {
            Group {
                switch account.accessState {
                case .authenticated:
                    TabView(selection: $store.selectedTab) {
                        ChatView(draft: $chatDraft).tabItem { Label(L10n.ui("tab.chat", language: preference.language), systemImage: "bubble.left.and.bubble.right") }.tag(0)
                        DataLibraryView(settingsPresented: $settingsPresented).tabItem { Label(L10n.ui("tab.data", language: preference.language), systemImage: "books.vertical").accessibilityIdentifier("dataTab") }.tag(1)
                    }
                    .sheet(isPresented: $settingsPresented) { OracleSettingsView().id(preference.language) }
                case .restoring: AccountRestoringView()
                case .recoveryRequired: AccountRecoveryView()
                case .signedOut: AccountGateView()
                }
            }
        }
        // Refresh values from view helpers and stores while retaining the app's store.
        .id(preference.language)
        .tint(InkTheme.cinnabar).preferredColorScheme(.light)
        .environment(\.locale, preference.language.locale)
        .environmentObject(store)
        .environmentObject(account)
        .environmentObject(purchases)
        .task {
            if context.source != .debugFixture { purchases.startObserving() }
            await account.restore(); store.refreshCredential()
            if account.canAccessMain { await resumeBillingAndTasks() }
        }
        .onChange(of: account.canAccessMain) { _, allowed in
            if !allowed { settingsPresented = false }
            else { Task { await resumeBillingAndTasks() } }
        }
        .onChange(of: store.historyResetID) { _, _ in chatDraft = ""; settingsPresented = false }
        .onChange(of: account.deletionResetID) { _, _ in
            chatDraft = ""; settingsPresented = false
            purchases.clearDeletedAccountData()
        }
        .onReceive(NotificationCenter.default.publisher(for: .accountBalanceChanged).receive(on: RunLoop.main)) { _ in
            if account.canAccessMain { Task { await account.refreshOverview() } }
        }
        .onReceive(NotificationCenter.default.publisher(for: .accountSessionChanged).receive(on: RunLoop.main)) { _ in
            store.refreshCredential()
            Task {
                await account.sessionChanged()
                if account.accessState == .restoring { await account.restore(force: true) }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: ASAuthorizationAppleIDProvider.credentialRevokedNotification).receive(on: RunLoop.main)) { _ in
            Task { await account.verifyAppleCredentialState() }
        }
        .onReceive(store.$phase.removeDuplicates()) { phase in
            analysisBackgroundExecution.update(phase, store: store)
        }
        .onReceive(store.$messages) { messages in
            analysisBackgroundExecution.recordOutput(in: messages)
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification)) { _ in
            store.checkpoint()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .background { analysisBackgroundExecution.protectCurrentWork() }
            if phase == .active {
                store.refreshCredential()
                Task {
                    if account.canAccessMain {
                        await account.verifyAppleCredentialState()
                        if account.canAccessMain {
                            if context.source != .debugFixture { await purchases.resumeUnfinished() }
                            await account.refreshOverview()
                        }
                    } else { await account.restore(force: true) }
                }
            }
        }
    }
    private func resumeBillingAndTasks() async {
        guard context.source != .debugFixture else { return }
        await purchases.resumeUnfinished()
        await store.flushQuotaEnds()
        await AIQuotaTaskService.shared.flushPendingEnds()
    }
}

@MainActor
private final class AnalysisBackgroundExecution {
    private final class Attempt {
        weak var store: OracleStore?
        var phase: OraclePhase
        var finishing = false
        var hasOutput = false
        var assertion: UIBackgroundTaskIdentifier = .invalid
        var requestID: String?
        var continuedTask: BGTask?

        init(phase: OraclePhase, store: OracleStore) {
            self.phase = phase
            self.store = store
        }
    }

    private var current: Attempt?

    func update(_ phase: OraclePhase, store: OracleStore) {
        if phase.isBusy {
            if let current, !current.finishing {
                guard current.phase != phase else { return }
                current.phase = phase
                updateProgress(for: current)
                return
            }
            let previous = current
            let attempt = Attempt(phase: phase, store: store)
            current = attempt
            protectCurrentWork()
            if let previous { finish(previous, success: false) }
            if #available(iOS 26.0, *), store.hasCredential,
               UIApplication.shared.applicationState == .active {
                requestContinuedProcessing(for: attempt)
            }
        } else if let attempt = current, !attempt.finishing {
            attempt.finishing = true
            // Let the store save the outcome before the last assertion is released.
            Task { @MainActor [weak self, weak store] in
                guard let self, current === attempt else { return }
                let status = store?.activities.last?.status
                finish(attempt, success: status == .completed || status == .waiting)
            }
        }
    }

    func recordOutput(in messages: [ChatMessage]) {
        guard let attempt = current, !attempt.finishing, attempt.phase == .synthesizing, !attempt.hasOutput,
              let message = messages.last, message.id == attempt.store?.activityMessageID,
              message.role == .assistant, !message.content.isEmpty else { return }
        attempt.hasOutput = true
        updateProgress(for: attempt)
    }

    func protectCurrentWork() {
        guard let attempt = current, !attempt.finishing,
              attempt.assertion == .invalid, attempt.continuedTask == nil else { return }
        attempt.assertion = UIApplication.shared.beginBackgroundTask(withName: "Finish analysis") { [weak self, weak attempt] in
            guard let self, let attempt else { return }
            if current === attempt, !attempt.finishing, attempt.continuedTask == nil,
               UIApplication.shared.applicationState == .background {
                attempt.store?.suspendAnalysisForBackgroundExpiration()
            }
            endAssertion(for: attempt)
        }
    }

    @available(iOS 26.0, *)
    private func requestContinuedProcessing(for attempt: Attempt) {
        guard let bundleID = Bundle.main.bundleIdentifier else { return }
        let id = bundleID + ".analysis." + UUID().uuidString
        let scheduler = BGTaskScheduler.shared
        let registered = scheduler.register(forTaskWithIdentifier: id, using: .main) { [weak self, weak attempt] task in
            MainActor.assumeIsolated {
                guard let self, let attempt, self.current === attempt, !attempt.finishing,
                      let task = task as? BGContinuedProcessingTask else {
                    task.setTaskCompleted(success: false)
                    return
                }
                attempt.continuedTask = task
                task.expirationHandler = { [weak self, weak attempt] in
                    Task { @MainActor in
                        guard let self, let attempt, self.current === attempt else { return }
                        if !attempt.finishing { attempt.store?.suspendAnalysisForBackgroundExpiration() }
                        self.finish(attempt, success: false)
                    }
                }
                task.progress.totalUnitCount = 4
                self.updateProgress(for: attempt)
                self.endAssertion(for: attempt)
            }
        }
        guard registered else { return }
        attempt.requestID = id
        let request = BGContinuedProcessingTaskRequest(identifier: id,
            title: L10n.text("正在解读", "Preparing your reading"), subtitle: presentation(for: attempt.phase).subtitle)
        // The analysis is already running. Keep the short assertion if iOS declines the longer task.
        request.strategy = .fail
        #if compiler(>=6.4)
        if #available(iOS 27.0, *) {
            Task.detached { try? await scheduler.submitTaskRequest(request) }
            return
        }
        #endif
        try? scheduler.submit(request)
    }

    private func updateProgress(for attempt: Attempt) {
        guard #available(iOS 26.0, *), let task = attempt.continuedTask as? BGContinuedProcessingTask else { return }
        let presentation = presentation(for: attempt.phase)
        let completedUnits = attempt.hasOutput ? 3 : presentation.completedUnits
        task.progress.completedUnitCount = max(task.progress.completedUnitCount, completedUnits)
        let subtitle = attempt.hasOutput ? L10n.text("正在输出回答", "Writing the answer") : presentation.subtitle
        task.updateTitle(task.title, subtitle: subtitle)
    }

    private func presentation(for phase: OraclePhase) -> (completedUnits: Int64, subtitle: String) {
        switch phase {
        case .planning: (0, L10n.text("正在理解问题", "Understanding the question"))
        case .calculating: (1, L10n.text("正在推演", "Calculating the reading"))
        default: (2, L10n.text("正在整理回答", "Preparing the answer"))
        }
    }

    private func finish(_ attempt: Attempt, success: Bool) {
        if current === attempt { current = nil }
        if let task = attempt.continuedTask {
            attempt.continuedTask = nil
            if success, #available(iOS 26.0, *), let task = task as? BGContinuedProcessingTask {
                task.progress.completedUnitCount = task.progress.totalUnitCount
            }
            task.setTaskCompleted(success: success)
        } else if let id = attempt.requestID {
            BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: id)
        }
        endAssertion(for: attempt)
    }

    private func endAssertion(for attempt: Attempt) {
        let assertion = attempt.assertion
        guard assertion != .invalid else { return }
        attempt.assertion = .invalid
        UIApplication.shared.endBackgroundTask(assertion)
    }
}

struct AppLanguageSettingsRow: View {
    @AppStorage(AppLanguage.preferenceKey) private var preference: AppLanguagePreference = .system

    var body: some View {
        let label = L10n.ui("settings.language")
        HStack {
            Text(label).font(.system(size: 15, design: .serif))
            Spacer()
            Picker(label, selection: $preference) {
                Text(L10n.ui("settings.language.system")).tag(AppLanguagePreference.system)
                Text(verbatim: "简体中文").tag(AppLanguagePreference.simplifiedChinese)
                Text(verbatim: "English").tag(AppLanguagePreference.english)
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .accessibilityLabel(label)
            .accessibilityIdentifier("appLanguagePicker")
        }
    }
}

private extension Color {
    func withOpacity(_ opacity: Double) -> Color { self.opacity(opacity) }
}

import BackgroundTasks
import SwiftUI
import UIKit

@main struct BlindOracleApp: App {
    @StateObject private var store = OracleStore()
    @State private var analysisBackgroundExecution = AnalysisBackgroundExecution()
    @State private var chatDraft = ""
    @State private var settingsPresented = false
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage(AppLanguage.preferenceKey) private var preference: AppLanguagePreference = .system
    init() {
        #if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("--ui-testing-local"), arguments.contains("--ui-testing-reset-language") {
            UserDefaults.standard.removeObject(forKey: AppLanguage.preferenceKey)
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
            TabView(selection: $store.selectedTab) {
                ChatView(draft: $chatDraft).tabItem { Label(L10n.ui("tab.chat", language: preference.language), systemImage: "bubble.left.and.bubble.right") }.tag(0)
                DataLibraryView(settingsPresented: $settingsPresented).tabItem { Label(L10n.ui("tab.data", language: preference.language), systemImage: "books.vertical").accessibilityIdentifier("dataTab") }.tag(1)
            }
            // Refresh values from view helpers and stores while retaining the app's store.
            .id(preference.language)
            .sheet(isPresented: $settingsPresented) { OracleSettingsView().id(preference.language) }
            .tint(InkTheme.cinnabar).preferredColorScheme(.light)
            .environment(\.locale, preference.language.locale)
            .environmentObject(store)
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
                if phase == .active { store.refreshCredential() }
            }
        }
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

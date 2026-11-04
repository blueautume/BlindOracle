import SwiftUI

@main struct BlindOracleApp: App {
    @StateObject private var store = OracleStore()
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
                DataLibraryView(settingsPresented: $settingsPresented).tabItem { Label(L10n.ui("tab.data", language: preference.language), systemImage: "books.vertical") }.tag(1)
            }
            // Refresh values from view helpers and stores while retaining the app's store.
            .id(preference.language)
            .sheet(isPresented: $settingsPresented) { OracleSettingsView().id(preference.language) }
            .tint(InkTheme.cinnabar).preferredColorScheme(.light)
            .environment(\.locale, preference.language.locale)
            .environmentObject(store)
            .onChange(of: scenePhase) { _, phase in
                if phase == .background { store.checkpoint() }
                if phase == .active { store.refreshCredential() }
            }
        }
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

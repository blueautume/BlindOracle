import SwiftUI

@main struct BlindOracleApp: App {
    @StateObject private var store = OracleStore()
    init() {
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
                ChatView().tabItem { Label("对话", systemImage: "bubble.left.and.bubble.right") }.tag(0)
                DataLibraryView().tabItem { Label("数据", systemImage: "books.vertical") }.tag(1)
            }
            .tint(InkTheme.cinnabar).preferredColorScheme(.light)
            .environment(\.locale, Locale(identifier: "zh_Hans_CN"))
            .environmentObject(store)
        }
    }
}

private extension Color {
    func withOpacity(_ opacity: Double) -> Color { self.opacity(opacity) }
}

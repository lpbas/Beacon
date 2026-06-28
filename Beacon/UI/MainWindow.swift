import SwiftUI

/// The configuration window: a sidebar that switches between the
/// Discovery, Whitelist, Settings and About screens.
struct MainWindow: View {
    @Environment(AppRouter.self) private var router

    var body: some View {
        @Bindable var router = router
        NavigationSplitView {
            List(MainTab.allCases, selection: $router.mainTab) { tab in
                Label(tab.title, systemImage: tab.systemImage).tag(tab)
            }
            .navigationSplitViewColumnWidth(min: 170, ideal: 190, max: 220)
        } detail: {
            switch router.mainTab ?? .discovery {
            case .discovery: DiscoveryView()
            case .whitelist: WhitelistView()
            case .settings: SettingsView()
            case .about: AboutView()
            }
        }
        .frame(minWidth: 780, minHeight: 500)
    }
}

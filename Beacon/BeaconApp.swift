import SwiftUI

/// Stable identifiers for the app's windows, used with `openWindow(id:)`.
enum WindowID {
    static let main = "main"
}

@main
struct BeaconApp: App {
    @State private var store: Store
    @State private var engine: BroadcastEngine
    @State private var router = AppRouter()

    /// Hidden easter-egg setting: when on (and the asset exists), the menu bar
    /// shows the crispy/bacon icon instead of the default SF Symbol.
    @AppStorage(CrispyDefaults.usesCrispy) private var usesCrispyIcon = false

    init() {
        let store = Store()
        _store = State(initialValue: store)
        _engine = State(initialValue: BroadcastEngine(store: store))
    }

    var body: some Scene {
        // The menu bar dropdown is the main "Status" screen.
        MenuBarExtra {
            StatusPanel()
                .environment(store)
                .environment(engine)
                .environment(router)
        } label: {
            StatusBarLabel(
                isBroadcasting: engine.broadcastingCount > 0,
                hasError: engine.hasErrors,
                usesCrispyIcon: usesCrispyIcon
            )
        }
        .menuBarExtraStyle(.window)

        // The configuration window hosts Discovery / Whitelist / Settings / About.
        Window("Beacon", id: WindowID.main) {
            MainWindow()
                .environment(store)
                .environment(engine)
                .environment(router)
        }
        .windowResizability(.contentSize)
    }
}

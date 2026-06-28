import SwiftUI
import Observation

/// The screens hosted by the configuration window.
enum MainTab: String, CaseIterable, Identifiable {
    case discovery = "Discovery"
    case whitelist = "Whitelist"
    case settings = "Settings"
    case about = "About"

    var id: String { rawValue }
    var title: String { rawValue }

    var systemImage: String {
        switch self {
        case .discovery: "dot.radiowaves.left.and.right"
        case .whitelist: "checklist"
        case .settings: "gearshape"
        case .about: "info.circle"
        }
    }
}

/// Lets the menu bar panel deep-link into a specific tab of the main window.
@Observable
@MainActor
final class AppRouter {
    var mainTab: MainTab? = .discovery
}

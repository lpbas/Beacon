import SwiftUI

/// The menu bar status item icon.
///
/// - Dims to an inactive look when nothing is broadcasting (like Amphetamine's
///   inactive state).
/// - Becomes fully opaque when at least one service is broadcasting.
/// - Shows a status dot in the bottom-right: green when everything is
///   broadcasting cleanly, red when any service has errored. No dot when idle.
struct StatusBarLabel: View {
    let isBroadcasting: Bool
    let hasError: Bool
    let usesCrispyIcon: Bool

    var body: some View {
        if let image = StatusBarIconManager.statusBarImage(for: iconVariant, state: iconState) {
            Image(nsImage: image)
                .renderingMode(.original)
        } else {
            Image(systemName: "antenna.radiowaves.left.and.right")
                .opacity(iconState.iconAlpha)
        }
    }

    private var iconVariant: IconVariant {
        usesCrispyIcon ? .crispy : .normal
    }

    private var iconState: MenuBarIconState {
        if hasError {
            return isBroadcasting ? .failedBroadcasting : .failedIdle
        }
        if isBroadcasting {
            return .broadcasting
        }
        return .idle
    }
}

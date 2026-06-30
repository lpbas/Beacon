import SwiftUI

/// The menu bar status item icon.
///
/// - Dims to an inactive look when nothing is broadcasting (like Amphetamine's
///   inactive state).
/// - Becomes fully opaque when at least one service is broadcasting.
/// - Shows a small red badge in the bottom-right when any service has errored
///   (like the status dot on a Teams avatar). The badge is independent of the
///   dim state, so an all-errored set shows a dim icon with a red badge.
struct StatusBarLabel: View {
    let isBroadcasting: Bool
    let hasError: Bool
    let usesCrispyIcon: Bool

    var body: some View {
        icon
            .opacity(isBroadcasting ? 1 : 0.45)
            .overlay(alignment: .bottomTrailing) {
                if hasError {
                    Circle()
                        .fill(.red)
                        .frame(width: 6, height: 6)
                }
            }
    }

    @ViewBuilder
    private var icon: some View {
        if usesCrispyIcon, let crispy = StatusBarIconManager.statusBarImage(for: .crispy) {
            Image(nsImage: crispy)
        } else if let normal = StatusBarIconManager.statusBarImage(for: .normal) {
            Image(nsImage: normal)
        } else {
            Image(systemName: "antenna.radiowaves.left.and.right")
        }
    }
}

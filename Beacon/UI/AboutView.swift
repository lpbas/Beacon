import SwiftUI

struct AboutView: View {
    @AppStorage(CrispyDefaults.unlocked) private var crispyUnlocked = false
    @AppStorage(CrispyDefaults.usesCrispy) private var usesCrispyIcon = false

    @State private var versionTapCount = 0
    @State private var lastVersionTap = Date.distantPast
    @State private var showUnlockMessage = false

    private var version: String {
        let short = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "-"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "-"
        return "Version \(short) (\(build))"
    }

    var body: some View {
        VStack(spacing: 14) {
            headerIcon
            VStack(spacing: 4) {
                Text("Beacon").font(.largeTitle.bold())
                // Tapping the version 5 times unlocks the hidden Crispy icon.
                // Styled as plain text on purpose so it does not look tappable.
                Text(version)
                    .foregroundStyle(.secondary)
                    .onTapGesture { registerVersionTap() }
                if showUnlockMessage {
                    Text("🥓 Crispy Mode unlocked.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .transition(.opacity)
                }
            }

            Text("Beacon re-broadcasts Bonjour/mDNS services on your local network, so other devices can see services that Docker/OrbStack on macOS won't relay, such as HomeKit bridges, Home Assistant, and more.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 460)

            HStack(spacing: 12) {
                Link(destination: URL(string: "https://github.com/orbstack/orbstack/issues/342")!) {
                    Label("OrbStack issue #342", systemImage: "link")
                }
                Link(destination: URL(string: "https://github.com/")!) {
                    Label("Source on GitHub", systemImage: "chevron.left.forwardslash.chevron.right")
                }
            }
            .font(.callout)

            Text("Based on the homekit-mdns-broadcaster script. MIT License.")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Crispy app-icon preview when enabled and the asset exists; otherwise the
    /// normal symbol (fallback).
    @ViewBuilder
    private var headerIcon: some View {
        if let image = StatusBarIconManager.appPreviewImage(for: usesCrispyIcon ? .crispy : .normal) {
            Image(nsImage: image)
                .resizable()
                .scaledToFit()
                .frame(width: 104, height: 104)
                .clipShape(RoundedRectangle(cornerRadius: 23, style: .continuous))
        } else {
            Image(systemName: "antenna.radiowaves.left.and.right")
                .font(.system(size: 72))
                .foregroundStyle(.tint)
        }
    }

    private func registerVersionTap() {
        let now = Date()
        if now.timeIntervalSince(lastVersionTap) > 2 { versionTapCount = 0 } // reset if taps are too slow
        lastVersionTap = now
        versionTapCount += 1
        guard versionTapCount >= 5 else { return }
        versionTapCount = 0
        guard !crispyUnlocked else { return }
        crispyUnlocked = true
        withAnimation { showUnlockMessage = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
            withAnimation { showUnlockMessage = false }
        }
    }
}

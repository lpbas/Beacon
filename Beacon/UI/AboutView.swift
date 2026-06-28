import SwiftUI

struct AboutView: View {
    private var version: String {
        let short = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "-"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "-"
        return "Version \(short) (\(build))"
    }

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "antenna.radiowaves.left.and.right")
                .font(.system(size: 56))
                .foregroundStyle(.tint)
            VStack(spacing: 4) {
                Text("Beacon").font(.largeTitle.bold())
                Text(version).foregroundStyle(.secondary)
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
}

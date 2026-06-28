import SwiftUI

/// A small colored status indicator for a service's run state, shared by the
/// Status panel and Whitelist screen.
struct ServiceStateBadge: View {
    let state: ServiceRunState
    var showsText = true

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(color)
                .frame(width: 7, height: 7)
            if showsText {
                Text(text)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .help(text)
    }

    private var text: String {
        switch state {
        case .stopped: "Stopped"
        case .resolving: "Resolving…"
        case .broadcasting: "Broadcasting"
        case .failed(let message): message
        }
    }

    private var color: Color {
        switch state {
        case .stopped: .secondary
        case .resolving: .orange
        case .broadcasting: .green
        case .failed: .red
        }
    }
}

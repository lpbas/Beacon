import SwiftUI

/// A run/stop toggle with a fixed-size icon box. `play.fill` and `stop.fill`
/// have different widths, so without a fixed frame the control shifts when
/// toggled and throws off row alignment. Shared by the Status panel and Whitelist.
struct RunStopButton: View {
    let isRunning: Bool
    var size: CGFloat = 14
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: isRunning ? "stop.fill" : "play.fill")
                .font(.system(size: size))
                .frame(width: size + 10, height: size + 6)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .help(isRunning ? "Stop broadcasting" : "Start broadcasting")
    }
}

import SwiftUI
import AppKit

/// The menu bar dropdown, the app's main "Status" screen. Lists enabled
/// whitelisted services with per-service run/stop and a master toggle.
struct StatusPanel: View {
    @Environment(Store.self) private var store
    @Environment(BroadcastEngine.self) private var engine
    @Environment(AppRouter.self) private var router
    @Environment(\.openWindow) private var openWindow

    /// Fixed row height so the list can be sized deterministically. A bare
    /// ScrollView collapses to zero height in the self-sizing menu bar window,
    /// so we give it an explicit height of up to `maxVisibleRows` rows.
    private let rowHeight: CGFloat = 52
    /// Showing a half row when there are more services hints that the list scrolls.
    private let maxVisibleRows: CGFloat = 4.5

    private var enabledEntries: [WhitelistEntry] {
        store.entries.filter(\.isEnabled)
    }

    /// Height that shows all rows up to 4.5, beyond which the list scrolls.
    private var listHeight: CGFloat {
        min(CGFloat(enabledEntries.count), maxVisibleRows) * rowHeight
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            if enabledEntries.isEmpty {
                emptyState
            } else {
                serviceList
            }
            Divider()
            footer
        }
        .frame(width: 330)
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 1) {
                Text("Beacon").font(.system(size: 15, weight: .semibold))
                Text(subtitle).font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Spacer()
            if !enabledEntries.isEmpty {
                Button(engine.isAnyActive ? "Stop All" : "Start All") {
                    if engine.isAnyActive { engine.stopAll() } else { engine.startAll() }
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    private var subtitle: String {
        let broadcasting = engine.broadcastingCount
        if broadcasting > 0 { return "\(broadcasting) broadcasting" }
        if engine.isAnyActive { return "Starting…" }
        return enabledEntries.isEmpty ? "No services" : "Idle"
    }

    // MARK: - Service list

    private var serviceList: some View {
        ScrollView {
            VStack(spacing: 0) {
                ForEach(enabledEntries) { entry in
                    StatusRow(entry: entry)
                        .frame(height: rowHeight)
                        .overlay(alignment: .bottom) {
                            if entry.id != enabledEntries.last?.id { Divider() }
                        }
                }
            }
        }
        .frame(height: listHeight)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "antenna.radiowaves.left.and.right.slash")
                .font(.title)
                .foregroundStyle(.secondary)
            Text("No services yet")
                .font(.system(size: 14))
            Text("Discover services on your network or add them to your whitelist to start broadcasting.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Discover Services…") { open(.discovery) }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 20)
        .padding(.horizontal, 16)
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 2) {
            FooterButton(title: "Discover", systemImage: "dot.radiowaves.left.and.right") { open(.discovery) }
            FooterButton(title: "Whitelist", systemImage: "checklist") { open(.whitelist) }
            FooterButton(title: "Settings", systemImage: "gearshape") { open(.settings) }
            Spacer()
            Menu {
                Button("About Beacon") { open(.about) }
                Divider()
                Button("Quit Beacon") { NSApplication.shared.terminate(nil) }
            } label: {
                Image(systemName: "ellipsis.circle").font(.system(size: 15))
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    // MARK: - Navigation

    private func open(_ tab: MainTab) {
        router.mainTab = tab
        openWindow(id: WindowID.main)
        // Raise the app and the window. For a menu bar (accessory) app, openWindow
        // alone can leave the window behind other apps' windows.
        DispatchQueue.main.async {
            if #available(macOS 14.0, *) {
                NSApp.activate()
            } else {
                NSApp.activate(ignoringOtherApps: true)
            }
            mainWindow()?.makeKeyAndOrderFront(nil)
        }
    }

    private func mainWindow() -> NSWindow? {
        NSApp.windows.first { $0.identifier?.rawValue == WindowID.main }
            ?? NSApp.windows.first { $0.title == "Beacon" && $0.styleMask.contains(.titled) }
    }
}

/// One row in the status list: service name, state, and a run/stop control.
private struct StatusRow: View {
    @Environment(BroadcastEngine.self) private var engine
    let entry: WhitelistEntry

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.instanceName)
                    .font(.system(size: 14))
                    .lineLimit(1)
                    .truncationMode(.middle)
                ServiceStateBadge(state: engine.runState(for: entry.id), font: .system(size: 12))
            }
            Spacer()
            RunStopButton(isRunning: engine.isActive(entry.id)) { engine.toggle(entry) }
        }
        .padding(.horizontal, 14)
    }
}

private struct FooterButton: View {
    let title: String
    let systemImage: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 2) {
                Image(systemName: systemImage).font(.system(size: 14))
                Text(title).font(.system(size: 11))
            }
            .frame(minWidth: 60)
            .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
    }
}

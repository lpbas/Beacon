import SwiftUI
import AppKit

/// The menu bar dropdown, the app's main "Status" screen. Lists enabled
/// whitelisted services with per-service run/stop and a master toggle.
struct StatusPanel: View {
    @Environment(Store.self) private var store
    @Environment(BroadcastEngine.self) private var engine
    @Environment(AppRouter.self) private var router
    @Environment(\.openWindow) private var openWindow

    private var enabledEntries: [WhitelistEntry] {
        store.entries.filter(\.isEnabled)
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
        .frame(width: 320)
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 1) {
                Text("Beacon").font(.headline)
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if !enabledEntries.isEmpty {
                Button(engine.isAnyActive ? "Stop All" : "Start All") {
                    if engine.isAnyActive { engine.stopAll() } else { engine.startAll() }
                }
                .controlSize(.small)
            }
        }
        .padding(12)
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
                    if entry.id != enabledEntries.last?.id { Divider() }
                }
            }
        }
        .frame(maxHeight: 320)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "antenna.radiowaves.left.and.right.slash")
                .font(.title)
                .foregroundStyle(.secondary)
            Text("No services yet")
                .font(.callout)
            Text("Discover services on your network or add them to your whitelist to start broadcasting.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Discover Services…") { open(.discovery) }
                .controlSize(.small)
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
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    private func open(_ tab: MainTab) {
        router.mainTab = tab
        openWindow(id: WindowID.main)
        NSApp.activate(ignoringOtherApps: true)
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
                    .lineLimit(1)
                    .truncationMode(.middle)
                ServiceStateBadge(state: engine.runState(for: entry.id))
            }
            Spacer()
            Button {
                engine.toggle(entry)
            } label: {
                Image(systemName: engine.isActive(entry.id) ? "stop.fill" : "play.fill")
            }
            .buttonStyle(.borderless)
            .help(engine.isActive(entry.id) ? "Stop broadcasting" : "Start broadcasting")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

private struct FooterButton: View {
    let title: String
    let systemImage: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 2) {
                Image(systemName: systemImage)
                Text(title).font(.system(size: 10))
            }
            .frame(minWidth: 56)
            .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
    }
}

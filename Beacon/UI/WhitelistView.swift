import SwiftUI

/// Manage the set of services Beacon re-broadcasts: add, pause/resume, reorder
/// and delete.
struct WhitelistView: View {
    @Environment(Store.self) private var store
    @Environment(BroadcastEngine.self) private var engine
    @Environment(AppRouter.self) private var router

    @State private var showAdd = false

    var body: some View {
        Group {
            if store.entries.isEmpty {
                emptyState
            } else {
                list
            }
        }
        .navigationTitle("Whitelist")
        .toolbar {
            ToolbarItem {
                Button { showAdd = true } label: { Label("Add Service", systemImage: "plus") }
            }
        }
        .sheet(isPresented: $showAdd) {
            AddServiceSheet { name in store.addEntry(instanceName: name) }
        }
    }

    private var list: some View {
        List {
            ForEach(store.entries) { entry in
                WhitelistRow(entry: entry)
            }
            .onMove { store.move(fromOffsets: $0, toOffset: $1) }
            .onDelete(perform: deleteEntries)
        }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No services in your whitelist", systemImage: "checklist")
        } description: {
            Text("Add services manually, or discover them on your network.")
        } actions: {
            Button("Discover Services") { router.mainTab = .discovery }
            Button("Add Manually") { showAdd = true }
        }
    }

    private func deleteEntries(_ offsets: IndexSet) {
        for index in offsets {
            engine.stop(store.entries[index].id)
        }
        store.delete(atOffsets: offsets)
    }
}

/// A whitelist row: enable toggle, name + details, state, run/stop and delete.
private struct WhitelistRow: View {
    @Environment(Store.self) private var store
    @Environment(BroadcastEngine.self) private var engine
    let entry: WhitelistEntry

    var body: some View {
        HStack(spacing: 10) {
            Toggle("", isOn: enabledBinding)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
                .help(entry.isEnabled ? "Pause (stop broadcasting)" : "Resume")

            VStack(alignment: .leading, spacing: 2) {
                Text(entry.instanceName)
                    .fontWeight(.medium)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(entry.isEnabled ? .primary : .secondary)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if entry.isEnabled {
                ServiceStateBadge(state: engine.runState(for: entry.id), showsText: false)
                Button {
                    engine.toggle(entry)
                } label: {
                    Image(systemName: engine.isActive(entry.id) ? "stop.fill" : "play.fill")
                }
                .buttonStyle(.borderless)
                .help(engine.isActive(entry.id) ? "Stop broadcasting" : "Start broadcasting")
            } else {
                Text("Paused").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 3)
        .contextMenu {
            if entry.isEnabled {
                Button(engine.isActive(entry.id) ? "Stop" : "Start") { engine.toggle(entry) }
                Button("Pause") { setEnabled(false) }
            } else {
                Button("Resume") { setEnabled(true) }
            }
            Divider()
            Button("Delete", role: .destructive) {
                engine.stop(entry.id)
                store.delete(entry.id)
            }
        }
    }

    private var subtitle: String {
        var parts: [String] = []
        if let type = entry.preferredServiceType {
            parts.append(ServiceTypeCatalog.friendlyName(for: type))
        }
        if let summary = entry.lastResolvedSummary {
            parts.append(summary)
        }
        return parts.isEmpty ? "Not yet resolved" : parts.joined(separator: "  ·  ")
    }

    private var enabledBinding: Binding<Bool> {
        Binding(get: { entry.isEnabled }, set: { setEnabled($0) })
    }

    private func setEnabled(_ enabled: Bool) {
        store.setEnabled(enabled, for: entry.id)
        if !enabled { engine.stop(entry.id) }
    }
}

/// Sheet for adding a service by its exact instance name.
private struct AddServiceSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    let onAdd: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Add Service").font(.headline)
            Text("Enter the exact instance name as it appears on the network (as seen in Discovery or `dns-sd -B`).")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField("e.g. HASS Bridge WP C94970 (2)", text: $name)
                .textFieldStyle(.roundedBorder)
                .onSubmit(commit)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Add") { commit() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 420)
    }

    private func commit() {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        onAdd(trimmed)
        dismiss()
    }
}

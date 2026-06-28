import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct SettingsView: View {
    @Environment(Store.self) private var store
    @Environment(BroadcastEngine.self) private var engine

    @State private var loginError: String?
    @State private var importMessage: String?
    @State private var newType = ""

    var body: some View {
        @Bindable var store = store
        Form {
            Section("Service Groups") {
                Text("Choose which service types Beacon scans for discovery and tries when resolving.")
                    .font(.caption).foregroundStyle(.secondary)
                ForEach(ServiceTypeCatalog.groups) { group in
                    Toggle(isOn: groupBinding(group.id)) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(group.title)
                            Text("\(group.types.count) type\(group.types.count == 1 ? "" : "s")")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }

            Section("Custom Service Types") {
                ForEach(store.settings.extraServiceTypes, id: \.self) { type in
                    HStack {
                        Text(type).font(.system(.body, design: .monospaced))
                        Spacer()
                        Button(role: .destructive) { removeType(type) } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.borderless)
                    }
                }
                HStack {
                    TextField("_custom._tcp", text: $newType)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(addType)
                    Button("Add", action: addType)
                        .disabled(!newType.hasPrefix("_"))
                }
            }

            Section("Startup") {
                Toggle("Launch Beacon at login", isOn: launchAtLoginBinding)
                if let loginError {
                    Text(loginError).font(.caption).foregroundStyle(.red)
                }
                Toggle("Start broadcasting on launch", isOn: $store.settings.startBroadcastingOnLaunch)
                Picker("Start delay", selection: $store.settings.startDelaySeconds) {
                    Text("None").tag(0)
                    Text("5 seconds").tag(5)
                    Text("10 seconds").tag(10)
                    Text("30 seconds").tag(30)
                    Text("60 seconds").tag(60)
                }
                .help("Wait before auto-starting, useful so Docker/containers finish booting first.")
            }

            Section("Maintenance") {
                Picker("Auto-refresh", selection: $store.settings.autoRefreshMinutes) {
                    Text("Off").tag(0)
                    Text("Every 5 minutes").tag(5)
                    Text("Every 15 minutes").tag(15)
                    Text("Every 30 minutes").tag(30)
                    Text("Every hour").tag(60)
                }
                .help("Periodically re-resolve broadcasting services to catch container restarts.")
                Toggle("Verbose logging", isOn: $store.settings.verboseLogging)
            }

            Section("Whitelist") {
                Button("Import service_whitelist.txt…", action: importLegacy)
                if let importMessage {
                    Text(importMessage).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Settings")
        .onAppear { store.settings.launchAtLogin = LoginItem.isEnabled }
        .onChange(of: store.settings.autoRefreshMinutes) { _, _ in engine.reconfigureAutoRefresh() }
    }

    // MARK: - Bindings

    private func groupBinding(_ id: String) -> Binding<Bool> {
        Binding(
            get: { store.settings.selectedGroupIDs.contains(id) },
            set: { isOn in
                if isOn { store.settings.selectedGroupIDs.insert(id) }
                else { store.settings.selectedGroupIDs.remove(id) }
            }
        )
    }

    private var launchAtLoginBinding: Binding<Bool> {
        Binding(
            get: { store.settings.launchAtLogin },
            set: { newValue in
                do {
                    try LoginItem.setEnabled(newValue)
                    store.settings.launchAtLogin = newValue
                    loginError = nil
                } catch {
                    loginError = "Couldn’t \(newValue ? "enable" : "disable") launch at login: \(error.localizedDescription)"
                    store.settings.launchAtLogin = LoginItem.isEnabled
                }
            }
        )
    }

    // MARK: - Actions

    private func addType() {
        let trimmed = newType.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("_"), !store.settings.extraServiceTypes.contains(trimmed) else { return }
        store.settings.extraServiceTypes.append(trimmed)
        newType = ""
    }

    private func removeType(_ type: String) {
        store.settings.extraServiceTypes.removeAll { $0 == type }
    }

    private func importLegacy() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.plainText, .text]
        panel.allowsMultipleSelection = false
        panel.message = "Choose a service_whitelist.txt file"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let count = try store.importLegacyWhitelist(at: url)
            importMessage = "Imported \(count) new service\(count == 1 ? "" : "s")."
        } catch {
            importMessage = "Import failed: \(error.localizedDescription)"
        }
    }
}

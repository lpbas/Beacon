import SwiftUI

/// Polls the local network for the selected service types, lists what's found,
/// resolves a selected service to show its details, and adds services to the
/// whitelist.
struct DiscoveryView: View {
    @Environment(Store.self) private var store
    @Environment(BroadcastEngine.self) private var engine
    @Environment(AppRouter.self) private var router

    @State private var browser = ServiceBrowser()
    @State private var search = ""
    @State private var selection: DiscoveredService.ID?
    @State private var resolved: ResolvedService?
    @State private var resolveError: String?
    @State private var isResolving = false

    // Browsing is a continuous live subscription, so we only show the spinner
    // for a short window after (re)starting rather than forever.
    @State private var isScanning = false
    @State private var scanTask: Task<Void, Never>?
    private let scanIndicatorSeconds: Double = 3

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            content
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            // Presented as a bottom inset rather than a VStack sibling, so showing
            // it does not resize the list and reset its scroll position.
            if let service = selectedService {
                VStack(spacing: 0) {
                    Divider()
                    detail(for: service)
                }
                .background(.regularMaterial)
            }
        }
        .navigationTitle("Discovery")
        .onAppear(perform: restart)
        .onDisappear {
            browser.stop()
            scanTask?.cancel()
            isScanning = false
        }
        .onChange(of: store.settings.discoveryServiceTypes) { _, _ in restart() }
        .onChange(of: selection) { _, _ in resolveSelection() }
    }

    // MARK: - Toolbar

    private var toolbar: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Filter by name or type", text: $search)
                .textFieldStyle(.plain)
            if isScanning {
                ProgressView().controlSize(.small)
            }
            Button(action: restart) {
                Image(systemName: "arrow.clockwise")
            }
            .help("Scan again")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if browser.services.isEmpty {
            ContentUnavailableView {
                Label(isScanning ? "Searching the local network…" : "No services found",
                      systemImage: "dot.radiowaves.left.and.right")
            } description: {
                Text("Browsing \(store.settings.discoveryServiceTypes.count) service type(s) from your selected groups. Adjust them in Settings.")
            } actions: {
                Button("Open Settings") { router.mainTab = .settings }
            }
            .frame(maxHeight: .infinity)
        } else {
            List(selection: $selection) {
                ForEach(groupedServices, id: \.type) { group in
                    Section(ServiceTypeCatalog.friendlyName(for: group.type)) {
                        ForEach(group.services) { service in
                            DiscoveryRow(
                                service: service,
                                isWhitelisted: isWhitelisted(service.name),
                                isOwnRebroadcast: isOwnRebroadcast(service),
                                add: { add(service) }
                            )
                            .tag(service.id)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Detail

    private func detail(for service: DiscoveredService) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(service.name).font(.headline).lineLimit(1)
                Spacer()
                if isOwnRebroadcast(service) {
                    Label("Beacon re-broadcast", systemImage: "antenna.radiowaves.left.and.right")
                        .foregroundStyle(.secondary).font(.caption)
                } else if isWhitelisted(service.name) {
                    Label("In whitelist", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green).font(.caption)
                } else {
                    Button("Add to Whitelist") { add(service) }
                        .controlSize(.small)
                }
            }

            if isResolving {
                HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Resolving…").foregroundStyle(.secondary) }
                    .font(.caption)
            } else if let resolved {
                Text("\(ServiceType.trimmingTrailingDot(resolved.hostTarget)) : \(resolved.displayPort)")
                    .font(.callout).textSelection(.enabled)
                if !resolved.txtPairs.isEmpty {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(resolved.txtPairs, id: \.key) { pair in
                                Text("\(pair.key) = \(pair.value)")
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 120)
                }
            } else if let resolveError {
                Text(resolveError).font(.caption).foregroundStyle(.red)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Data

    private var selectedService: DiscoveredService? {
        browser.services.first { $0.id == selection }
    }

    private var groupedServices: [(type: String, services: [DiscoveredService])] {
        let filtered = browser.services.filter {
            search.isEmpty
            || $0.name.localizedCaseInsensitiveContains(search)
            || $0.serviceType.localizedCaseInsensitiveContains(search)
            || ServiceTypeCatalog.friendlyName(for: $0.serviceType).localizedCaseInsensitiveContains(search)
        }
        return Dictionary(grouping: filtered, by: \.serviceType)
            .map { (type: $0.key, services: $0.value.sorted { $0.name < $1.name }) }
            .sorted { $0.type < $1.type }
    }

    private func isWhitelisted(_ name: String) -> Bool {
        store.entries.contains { $0.instanceName == name }
    }

    /// True when this discovered service is one Beacon is itself advertising, so
    /// we can flag it and prevent whitelisting a copy of our own re-broadcast.
    private func isOwnRebroadcast(_ service: DiscoveredService) -> Bool {
        engine.broadcastedNames.contains(service.name)
    }

    // MARK: - Actions

    private func restart() {
        selection = nil
        let types = store.settings.discoveryServiceTypes
        browser.start(types: types)
        // Show the scan spinner briefly; the browse itself keeps running live.
        scanTask?.cancel()
        isScanning = !types.isEmpty
        guard isScanning else { return }
        scanTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(scanIndicatorSeconds))
            guard !Task.isCancelled else { return }
            isScanning = false
        }
    }

    private func add(_ service: DiscoveredService) {
        store.addEntry(instanceName: service.name, preferredServiceType: service.serviceType)
    }

    private func resolveSelection() {
        resolved = nil
        resolveError = nil
        guard let service = selectedService else { return }
        isResolving = true
        Task {
            do {
                resolved = try await ServiceResolver.resolve(name: service.name,
                                                             type: service.serviceType,
                                                             domain: service.resolveDomain)
            } catch {
                resolveError = error.localizedDescription
            }
            isResolving = false
        }
    }
}

/// A single discovered-service row with an add-to-whitelist control.
private struct DiscoveryRow: View {
    let service: DiscoveredService
    let isWhitelisted: Bool
    let isOwnRebroadcast: Bool
    let add: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(service.name).lineLimit(1).truncationMode(.middle)
                Text(service.serviceType).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if isOwnRebroadcast {
                Text("Beacon")
                    .font(.caption2.weight(.medium))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.quaternary, in: Capsule())
                    .foregroundStyle(.secondary)
                    .help("This is Beacon's own re-broadcast")
            } else if isWhitelisted {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .help("Already in whitelist")
            } else {
                Button {
                    add()
                } label: {
                    Image(systemName: "plus.circle")
                }
                .buttonStyle(.borderless)
                .help("Add to whitelist")
            }
        }
        .padding(.vertical, 2)
        .opacity(isOwnRebroadcast ? 0.6 : 1)
    }
}

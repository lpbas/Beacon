import Foundation
import Observation
import Network

/// Per-service lifecycle state shown in the UI.
enum ServiceRunState: Equatable {
    case stopped
    case resolving
    case broadcasting(serviceType: String, host: String, port: UInt16)
    case failed(String)
}

/// Orchestrates resolve → register for whitelisted services, tracks per-service
/// state, and supports per-service and master start/stop plus auto-refresh.
@Observable
@MainActor
final class BroadcastEngine {
    @ObservationIgnored private let store: Store

    /// Observed per-entry run state, keyed by entry id.
    private(set) var states: [WhitelistEntry.ID: ServiceRunState] = [:]

    /// Entries the user wants running (survives transient resolve failures).
    @ObservationIgnored private var desiredRunning: Set<WhitelistEntry.ID> = []
    @ObservationIgnored private var active: [WhitelistEntry.ID: ActiveRegistration] = [:]
    @ObservationIgnored private var refreshTimer: Timer?
    @ObservationIgnored private let pathMonitor = NWPathMonitor()
    @ObservationIgnored private var lastPathStatus: NWPath.Status?

    private struct ActiveRegistration {
        let registrar: ServiceRegistrar
        var type: String
        var port: UInt16     // network byte order
        var txt: Data
    }

    init(store: Store) {
        self.store = store
        startPathMonitor()
        reconfigureAutoRefresh()

        if store.settings.startBroadcastingOnLaunch {
            let delay = store.settings.startDelaySeconds
            Task { @MainActor in
                if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
                self.startAll()
            }
        }
    }

    // MARK: - Queries

    func runState(for id: WhitelistEntry.ID) -> ServiceRunState { states[id] ?? .stopped }
    func isActive(_ id: WhitelistEntry.ID) -> Bool { desiredRunning.contains(id) }
    var isAnyActive: Bool { !desiredRunning.isEmpty }

    var broadcastingCount: Int {
        states.reduce(0) { count, pair in
            if case .broadcasting = pair.value { return count + 1 }
            return count
        }
    }

    var errorCount: Int {
        states.reduce(0) { count, pair in
            if case .failed = pair.value { return count + 1 }
            return count
        }
    }

    var hasErrors: Bool { errorCount > 0 }

    // MARK: - Start / stop

    func start(_ entry: WhitelistEntry) {
        desiredRunning.insert(entry.id)
        setState(.resolving, for: entry.id)
        Task { @MainActor in await self.resolveAndRegister(entry) }
    }

    func stop(_ id: WhitelistEntry.ID) {
        desiredRunning.remove(id)
        active[id]?.registrar.stop()
        active[id] = nil
        setState(.stopped, for: id)
    }

    func toggle(_ entry: WhitelistEntry) {
        if isActive(entry.id) { stop(entry.id) } else { start(entry) }
    }

    func startAll() {
        for entry in store.entries where entry.isEnabled && !desiredRunning.contains(entry.id) {
            start(entry)
        }
    }

    func stopAll() {
        for id in Array(desiredRunning) { stop(id) }
    }

    // MARK: - Resolve + register

    private func resolveAndRegister(_ entry: WhitelistEntry) async {
        guard let (type, resolved) = await resolveFirst(entry) else {
            guard desiredRunning.contains(entry.id) else { return }
            handleFailure("Couldn’t resolve on any selected service type", for: entry.id)
            return
        }
        guard desiredRunning.contains(entry.id) else { return }
        applyRegistration(entry: entry, type: type, resolved: resolved)
    }

    /// Mark a service failed and drop it from the active set, so its row shows a
    /// retry (play) control instead of staying "running". Does not auto-retry;
    /// the user taps play to try again.
    private func handleFailure(_ message: String, for id: WhitelistEntry.ID) {
        desiredRunning.remove(id)
        active[id]?.registrar.stop()
        active[id] = nil
        setState(.failed(message), for: id)
    }

    /// Try each candidate service type in order (preferred first, then the
    /// selected groups) and return the first that resolves, mirroring the
    /// Python script's `extract_service_info`.
    private func resolveFirst(_ entry: WhitelistEntry) async -> (type: String, resolved: ResolvedService)? {
        for type in resolveOrder(for: entry) {
            if let resolved = try? await ServiceResolver.resolve(name: entry.instanceName, type: type) {
                return (type, resolved)
            }
        }
        return nil
    }

    private func resolveOrder(for entry: WhitelistEntry) -> [String] {
        var seen = Set<String>()
        var order: [String] = []
        if let preferred = entry.preferredServiceType { order.append(preferred); seen.insert(preferred) }
        for type in store.settings.resolveServiceTypes where seen.insert(type).inserted {
            order.append(type)
        }
        return order
    }

    private func applyRegistration(entry: WhitelistEntry, type: String, resolved: ResolvedService) {
        store.recordResolve(id: entry.id, host: resolved.hostTarget, port: resolved.displayPort, serviceType: type)
        let registrar = active[entry.id]?.registrar ?? ServiceRegistrar()
        active[entry.id] = ActiveRegistration(registrar: registrar, type: type, port: resolved.port, txt: resolved.txtData)
        let host = ServiceType.trimmingTrailingDot(resolved.hostTarget)
        let displayPort = resolved.displayPort
        registrar.register(name: entry.instanceName, type: type, port: resolved.port, txt: resolved.txtData) { [weak self] state in
            guard let self else { return }
            switch state {
            case .registered:
                self.setState(.broadcasting(serviceType: type, host: host, port: displayPort), for: entry.id)
            case .failed(let message):
                self.handleFailure(message, for: entry.id)
            case .registering, .idle:
                break
            }
        }
    }

    // MARK: - Auto refresh

    func reconfigureAutoRefresh() {
        refreshTimer?.invalidate()
        refreshTimer = nil
        let minutes = store.settings.autoRefreshMinutes
        guard minutes > 0 else { return }
        refreshTimer = Timer.scheduledTimer(withTimeInterval: Double(minutes) * 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshRunning() }
        }
    }

    /// Re-resolve running services and re-register only if host/port/TXT changed
    /// (handles container restarts and address changes).
    func refreshRunning() {
        for id in desiredRunning {
            guard let entry = store.entries.first(where: { $0.id == id }) else { continue }
            Task { @MainActor in await self.refresh(entry) }
        }
    }

    private func refresh(_ entry: WhitelistEntry) async {
        guard let (type, resolved) = await resolveFirst(entry) else { return } // keep current on failure
        guard desiredRunning.contains(entry.id) else { return }
        if let current = active[entry.id],
           current.type == type, current.port == resolved.port, current.txt == resolved.txtData {
            return // unchanged
        }
        applyRegistration(entry: entry, type: type, resolved: resolved)
    }

    // MARK: - Network monitoring

    private func startPathMonitor() {
        pathMonitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor in self?.handlePathUpdate(path) }
        }
        pathMonitor.start(queue: DispatchQueue(label: "beacon.path"))
    }

    private func handlePathUpdate(_ path: NWPath) {
        if path.status == .satisfied, lastPathStatus != .satisfied, lastPathStatus != nil {
            refreshRunning()
        }
        lastPathStatus = path.status
    }

    // MARK: - Helpers

    private func setState(_ state: ServiceRunState, for id: WhitelistEntry.ID) {
        states[id] = state
    }
}

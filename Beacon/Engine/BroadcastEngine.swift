import Foundation
import Observation
import Network
import OSLog

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

    /// Final advertised name per running entry. May differ from the requested
    /// name when mDNS auto-renames a re-broadcast (e.g. "Name (2)").
    private(set) var broadcastNames: [WhitelistEntry.ID: String] = [:]

    /// Entries the user wants running (survives transient resolve failures).
    @ObservationIgnored private var desiredRunning: Set<WhitelistEntry.ID> = []
    @ObservationIgnored private var active: [WhitelistEntry.ID: ActiveRegistration] = [:]
    @ObservationIgnored private var resolveTasks: [WhitelistEntry.ID: Task<Void, Never>] = [:]
    @ObservationIgnored private var resolveTaskGenerations: [WhitelistEntry.ID: Int] = [:]
    @ObservationIgnored private var refreshTimer: Timer?
    @ObservationIgnored private let pathMonitor = NWPathMonitor()
    @ObservationIgnored private var lastPathStatus: NWPath.Status?

    private struct ActiveRegistration {
        let registrar: ServiceRegistrar
        var type: String
        var port: UInt16     // network byte order
        var txt: Data
    }

    private enum ResolvePurpose {
        case start
        case refresh

        var logPrefix: String {
            switch self {
            case .start: "Start"
            case .refresh: "Auto-refresh"
            }
        }
    }

    init(store: Store) {
        self.store = store
        startPathMonitor()
        reconfigureAutoRefresh()
        BeaconLog.engine.notice("Broadcast engine initialized")

        if store.settings.startBroadcastingOnLaunch {
            let delay = store.settings.startDelaySeconds
            if BeaconLog.isVerboseEnabled {
                BeaconLog.engine.info("Start on launch enabled with \(delay, privacy: .public) second delay")
            }
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

    /// Names Beacon is currently advertising, used to flag our own re-broadcasts
    /// in Discovery so they are not whitelisted by mistake.
    var broadcastedNames: Set<String> { Set(broadcastNames.values) }

    // MARK: - Start / stop

    func start(_ entry: WhitelistEntry) {
        if BeaconLog.isVerboseEnabled {
            BeaconLog.engine.info("Starting \(entry.instanceName, privacy: .private)")
        }
        desiredRunning.insert(entry.id)
        setState(.resolving, for: entry.id)
        scheduleResolveTask(for: entry, purpose: .start)
    }

    func stop(_ id: WhitelistEntry.ID) {
        if BeaconLog.isVerboseEnabled {
            let name = store.entries.first { $0.id == id }?.instanceName ?? "unknown"
            BeaconLog.engine.info("Stopping \(name, privacy: .private)")
        }
        desiredRunning.remove(id)
        cancelResolveTask(for: id)
        active[id]?.registrar.stop()
        active[id] = nil
        broadcastNames[id] = nil
        setState(.stopped, for: id)
    }

    func toggle(_ entry: WhitelistEntry) {
        if isActive(entry.id) { stop(entry.id) } else { start(entry) }
    }

    func startAll() {
        if BeaconLog.isVerboseEnabled {
            BeaconLog.engine.info("Starting all enabled services")
        }
        for entry in store.entries where entry.isEnabled && !desiredRunning.contains(entry.id) {
            start(entry)
        }
    }

    func stopAll() {
        if BeaconLog.isVerboseEnabled {
            BeaconLog.engine.info("Stopping all running services")
        }
        for id in Array(desiredRunning) { stop(id) }
    }

    // MARK: - Resolve + register

    private func resolveAndRegister(_ entry: WhitelistEntry) async {
        guard !Task.isCancelled else { return }
        guard let (type, resolved) = await resolveFirst(entry, purpose: .start) else {
            guard !Task.isCancelled, desiredRunning.contains(entry.id) else { return }
            handleFailure("Couldn’t resolve on any selected service type", for: entry.id)
            return
        }
        guard !Task.isCancelled, desiredRunning.contains(entry.id) else { return }
        applyRegistration(entry: entry, type: type, resolved: resolved)
    }

    /// Mark a service failed and drop it from the active set, so its row shows a
    /// retry (play) control instead of staying "running". Does not auto-retry;
    /// the user taps play to try again.
    private func handleFailure(_ message: String, for id: WhitelistEntry.ID) {
        let name = store.entries.first { $0.id == id }?.instanceName ?? "unknown"
        BeaconLog.engine.error("Broadcast failed for \(name, privacy: .private): \(message, privacy: .public)")
        desiredRunning.remove(id)
        active[id]?.registrar.stop()
        active[id] = nil
        broadcastNames[id] = nil
        setState(.failed(message), for: id)
    }

    /// Try each candidate service type in order (preferred first, then the
    /// selected groups) and return the first that resolves, mirroring the
    /// Python script's `extract_service_info`.
    private func resolveFirst(_ entry: WhitelistEntry, purpose: ResolvePurpose) async -> (type: String, resolved: ResolvedService)? {
        for type in resolveOrder(for: entry) {
            guard !Task.isCancelled, desiredRunning.contains(entry.id) else { return nil }
            do {
                let resolved = try await ServiceResolver.resolve(name: entry.instanceName, type: type)
                guard !Task.isCancelled, desiredRunning.contains(entry.id) else { return nil }
                if BeaconLog.isVerboseEnabled {
                    BeaconLog.engine.info("\(purpose.logPrefix, privacy: .public) resolved \(entry.instanceName, privacy: .private) with service type \(type, privacy: .public)")
                }
                return (type, resolved)
            } catch is CancellationError {
                return nil
            } catch {
                guard !Task.isCancelled, desiredRunning.contains(entry.id) else { return nil }
                if BeaconLog.isVerboseEnabled {
                    BeaconLog.engine.debug("\(purpose.logPrefix, privacy: .public) could not resolve \(entry.instanceName, privacy: .private) as \(type, privacy: .public): \(error.localizedDescription, privacy: .public)")
                }
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
        if BeaconLog.isVerboseEnabled {
            BeaconLog.engine.info("Applying registration for \(entry.instanceName, privacy: .private) as \(type, privacy: .public) to \(resolved.hostTarget, privacy: .private):\(resolved.displayPort, privacy: .public)")
        }
        let registrar = active[entry.id]?.registrar ?? ServiceRegistrar()
        active[entry.id] = ActiveRegistration(registrar: registrar, type: type, port: resolved.port, txt: resolved.txtData)
        let host = ServiceType.trimmingTrailingDot(resolved.hostTarget)
        let displayPort = resolved.displayPort
        registrar.register(name: entry.instanceName, type: type, port: resolved.port, txt: resolved.txtData) { [weak self] state in
            guard let self else { return }
            switch state {
            case .registered(let finalName):
                self.broadcastNames[entry.id] = finalName
                if BeaconLog.isVerboseEnabled {
                    BeaconLog.engine.info("Broadcasting \(entry.instanceName, privacy: .private) as \(finalName, privacy: .private)")
                }
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
        guard minutes > 0 else {
            if BeaconLog.isVerboseEnabled {
                BeaconLog.engine.info("Auto-refresh disabled")
            }
            return
        }
        if BeaconLog.isVerboseEnabled {
            BeaconLog.engine.info("Auto-refresh configured for every \(minutes, privacy: .public) minute(s)")
        }
        refreshTimer = Timer.scheduledTimer(withTimeInterval: Double(minutes) * 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshRunning() }
        }
    }

    /// Re-resolve running services and re-register only if host/port/TXT changed
    /// (handles container restarts and address changes).
    func refreshRunning() {
        let runningIDs = desiredRunning.intersection(active.keys)
        guard !runningIDs.isEmpty else { return }
        if BeaconLog.isVerboseEnabled {
            BeaconLog.engine.info("Auto-refresh checking \(runningIDs.count, privacy: .public) registered service(s)")
        }
        for id in runningIDs {
            guard let entry = store.entries.first(where: { $0.id == id }) else { continue }
            guard resolveTasks[id] == nil else { continue }
            scheduleResolveTask(for: entry, purpose: .refresh)
        }
    }

    private func refresh(_ entry: WhitelistEntry) async {
        guard !Task.isCancelled, desiredRunning.contains(entry.id) else { return }
        guard let (type, resolved) = await resolveFirst(entry, purpose: .refresh) else {
            guard !Task.isCancelled, desiredRunning.contains(entry.id) else { return }
            if BeaconLog.isVerboseEnabled {
                BeaconLog.engine.debug("Auto-refresh could not resolve \(entry.instanceName, privacy: .private); keeping current registration")
            }
            return
        }
        guard !Task.isCancelled, desiredRunning.contains(entry.id) else { return }
        if let current = active[entry.id],
           current.type == type, current.port == resolved.port, current.txt == resolved.txtData {
            if BeaconLog.isVerboseEnabled {
                BeaconLog.engine.debug("Refresh found no changes for \(entry.instanceName, privacy: .private)")
            }
            return // unchanged
        }
        if BeaconLog.isVerboseEnabled {
            BeaconLog.engine.info("Refresh detected changes for \(entry.instanceName, privacy: .private)")
        }
        applyRegistration(entry: entry, type: type, resolved: resolved)
    }

    // MARK: - Network monitoring

    private func startPathMonitor() {
        if BeaconLog.isVerboseEnabled {
            BeaconLog.engine.info("Starting network path monitor")
        }
        pathMonitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor in self?.handlePathUpdate(path) }
        }
        pathMonitor.start(queue: DispatchQueue(label: "beacon.path"))
    }

    private func handlePathUpdate(_ path: NWPath) {
        if BeaconLog.isVerboseEnabled {
            BeaconLog.engine.debug("Network path status changed to \(String(describing: path.status), privacy: .public)")
        }
        if path.status == .satisfied, lastPathStatus != .satisfied, lastPathStatus != nil {
            BeaconLog.engine.notice("Network became available; refreshing running services")
            refreshRunning()
        }
        lastPathStatus = path.status
    }

    // MARK: - Helpers

    private func scheduleResolveTask(for entry: WhitelistEntry, purpose: ResolvePurpose) {
        let id = entry.id
        resolveTasks[id]?.cancel()
        let generation = nextResolveTaskGeneration(for: id)
        resolveTasks[id] = Task { @MainActor [weak self] in
            guard let self else { return }
            switch purpose {
            case .start:
                await self.resolveAndRegister(entry)
            case .refresh:
                await self.refresh(entry)
            }
            if self.resolveTaskGenerations[id] == generation {
                self.resolveTasks[id] = nil
            }
        }
    }

    private func cancelResolveTask(for id: WhitelistEntry.ID) {
        resolveTasks[id]?.cancel()
        resolveTasks[id] = nil
        _ = nextResolveTaskGeneration(for: id)
    }

    private func nextResolveTaskGeneration(for id: WhitelistEntry.ID) -> Int {
        let generation = (resolveTaskGenerations[id] ?? 0) + 1
        resolveTaskGenerations[id] = generation
        return generation
    }

    private func setState(_ state: ServiceRunState, for id: WhitelistEntry.ID) {
        states[id] = state
    }
}

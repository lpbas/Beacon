import Foundation
import Observation
import Network
import OSLog

/// Per-service lifecycle state shown in the UI.
enum ServiceRunState: Equatable {
    case stopped
    case resolving
    case broadcasting(serviceType: String, host: String, port: UInt16)
    /// A transient failure; another attempt is already scheduled.
    case retrying(message: String, attempt: Int)
    /// Gave up after exhausting the retry schedule: the user has to start it again.
    case failed(String)
}

/// Orchestrates resolve → register for whitelisted services, tracks per-service
/// state, and supports per-service and master start/stop, auto-refresh, automatic
/// retry of transient failures, and network awareness.
@Observable
@MainActor
final class BroadcastEngine {
    @ObservationIgnored private let store: Store

    /// Observed per-entry run state, keyed by entry id.
    private(set) var states: [WhitelistEntry.ID: ServiceRunState] = [:]

    /// Final advertised name per running entry. May differ from the requested
    /// name when the daemon renames a re-broadcast (e.g. "Name (2)").
    private(set) var broadcastNames: [WhitelistEntry.ID: String] = [:]

    /// Entries the user wants running (survives transient resolve failures).
    @ObservationIgnored private var desiredRunning: Set<WhitelistEntry.ID> = []
    @ObservationIgnored private var active: [WhitelistEntry.ID: ActiveRegistration] = [:]
    @ObservationIgnored private var resolveTasks: [WhitelistEntry.ID: Task<Void, Never>] = [:]
    @ObservationIgnored private var resolveTaskGenerations: [WhitelistEntry.ID: Int] = [:]
    @ObservationIgnored private var retryAttempts: [WhitelistEntry.ID: Int] = [:]
    @ObservationIgnored private var retryTasks: [WhitelistEntry.ID: Task<Void, Never>] = [:]
    @ObservationIgnored private var refreshTimer: Timer?
    @ObservationIgnored private let pathMonitor = NWPathMonitor()
    @ObservationIgnored private var lastPathStatus: NWPath.Status?
    /// LAN interface to publish on, learned from the path monitor. `nil` until the
    /// monitor has reported once; 0 (all interfaces) is used in that window.
    @ObservationIgnored private var lanInterface: UInt32?

    private struct ActiveRegistration {
        let registrar: ServiceRegistrar
        var type: String
        var port: UInt16     // network byte order
        var txt: Data
        var interfaceIndex: UInt32
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

    /// Backoff schedule for automatic re-registration, in seconds. Starts fast —
    /// a container that is still booting is the common case — then settles at five
    /// minutes. Running out of entries means the service has been down for about
    /// twenty minutes and is reported as a failure the user has to act on.
    static let retryDelays: [Int] = [5, 15, 30, 60, 120, 300, 300, 300]

    /// Routine retries should not light up the menu bar. A service that is still
    /// down after a couple of attempts is worth an error indicator.
    private static let retryingCountsAsErrorFromAttempt = 3

    /// How many candidate service types to resolve at once. A name that matches
    /// nothing used to cost one timeout per candidate, one after another; the
    /// parallel batches cost one timeout per batch.
    private static let resolveBatchSize = 6

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

    /// Interface Beacon publishes on right now, for display in diagnostics.
    var broadcastInterfaceIndex: UInt32 { effectiveBroadcastInterface }

    var broadcastingCount: Int {
        states.reduce(0) { count, pair in
            if case .broadcasting = pair.value { return count + 1 }
            return count
        }
    }

    var errorCount: Int {
        states.reduce(0) { count, pair in
            switch pair.value {
            case .failed:
                return count + 1
            case .retrying(_, let attempt) where attempt >= Self.retryingCountsAsErrorFromAttempt:
                return count + 1
            default:
                return count
            }
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
        // A manual start is a fresh intent: drop any backoff from earlier failures.
        cancelRetry(for: entry.id)
        retryAttempts[entry.id] = nil
        desiredRunning.insert(entry.id)
        setState(.resolving, for: entry.id)
        scheduleResolveTask(for: entry, purpose: .start)
    }

    func stop(_ id: WhitelistEntry.ID) {
        if BeaconLog.isVerboseEnabled {
            let name = store.entries.first { $0.id == id }?.instanceName ?? "unknown"
            BeaconLog.engine.info("Stopping \(name, privacy: .private)")
        }
        cancelRetry(for: id)
        retryAttempts[id] = nil
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
        await applyRegistration(entry: entry, type: type, resolved: resolved)
    }

    /// Mark a service failed. Services the user wants running are retried
    /// automatically on a backoff schedule; only after that schedule is exhausted
    /// does the entry become a terminal failure that needs a manual start.
    ///
    /// Not retrying at all — what Beacon 1.0 did — means the common transient cases
    /// (container still booting when Beacon starts at login, container restart, IP
    /// change, daemon restart) leave the service silently unadvertised until
    /// somebody happens to open the menu and press play.
    private func handleFailure(_ message: String, for id: WhitelistEntry.ID) {
        let name = store.entries.first { $0.id == id }?.instanceName ?? "unknown"
        BeaconLog.engine.error("Broadcast failed for \(name, privacy: .private): \(message, privacy: .public)")
        active[id]?.registrar.stop()
        active[id] = nil
        broadcastNames[id] = nil

        guard desiredRunning.contains(id) else {
            setState(.failed(message), for: id)
            return
        }

        let attempt = (retryAttempts[id] ?? 0) + 1
        guard attempt <= Self.retryDelays.count else {
            retryAttempts[id] = nil
            desiredRunning.remove(id)
            BeaconLog.engine.error("Giving up on \(name, privacy: .private) after \(attempt - 1, privacy: .public) attempt(s)")
            setState(.failed(message), for: id)
            return
        }

        let seconds = Self.retryDelays[attempt - 1]
        retryAttempts[id] = attempt
        BeaconLog.engine.notice("Retrying \(name, privacy: .private) in \(seconds, privacy: .public)s (attempt \(attempt, privacy: .public))")
        setState(.retrying(message: message, attempt: attempt), for: id)

        retryTasks[id]?.cancel()
        retryTasks[id] = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard let self, !Task.isCancelled else { return }
            self.retryTasks[id] = nil
            guard self.desiredRunning.contains(id),
                  let entry = self.store.entries.first(where: { $0.id == id }) else { return }
            if BeaconLog.isVerboseEnabled {
                BeaconLog.engine.info("Retry attempt \(attempt, privacy: .public) for \(entry.instanceName, privacy: .private)")
            }
            self.setState(.resolving, for: id)
            self.scheduleResolveTask(for: entry, purpose: .start)
        }
    }

    /// Resolve the first candidate that answers.
    ///
    /// When the entry remembers the service type that worked last time, that one is
    /// tried on its own first: the common case stays a single resolve. Everything
    /// else is tried in parallel batches, first success wins — attempting candidates
    /// one at a time at 3s each meant an unresolvable name took minutes once several
    /// groups were selected. Candidates are only taken concurrently when they are
    /// not known to be a preference, since that would just add a timeout.
    private func resolveFirst(_ entry: WhitelistEntry, purpose: ResolvePurpose) async -> (type: String, resolved: ResolvedService)? {
        let candidates = resolveOrder(for: entry)
        guard !candidates.isEmpty else { return nil }

        var remaining = candidates
        if let preferred = entry.preferredServiceType, !ServiceType.isMetaQuery(preferred) {
            if let resolved = await resolve(entry, type: preferred, purpose: purpose) {
                return (preferred, resolved)
            }
            remaining = candidates.filter { $0 != preferred }
        }
        guard !remaining.isEmpty, !Task.isCancelled else { return nil }

        var start = 0
        while start < remaining.count {
            guard !Task.isCancelled, desiredRunning.contains(entry.id) else { return nil }
            let batch = Array(remaining[start..<min(start + Self.resolveBatchSize, remaining.count)])
            start += batch.count
            let match = await resolveBatch(entry, types: batch, purpose: purpose)
            if let match { return match }
        }
        return nil
    }

    private func resolveBatch(_ entry: WhitelistEntry,
                              types: [String],
                              purpose: ResolvePurpose) async -> (type: String, resolved: ResolvedService)? {
        await withTaskGroup(of: (String, ResolvedService)?.self) { group in
            for type in types {
                group.addTask { [weak self] in
                    guard let self,
                          let resolved = await self.resolve(entry, type: type, purpose: purpose) else { return nil }
                    return (type, resolved)
                }
            }
            for await result in group {
                if let result {
                    group.cancelAll()   // stop the other candidates in this batch
                    return result
                }
            }
            return nil
        }
    }

    /// One candidate service type. Mirrors the Python script's `extract_service_info`:
    /// a type that does not resolve is not an error, it just is not the right one.
    private func resolve(_ entry: WhitelistEntry,
                         type: String,
                         purpose: ResolvePurpose) async -> ResolvedService? {
        guard !Task.isCancelled, desiredRunning.contains(entry.id) else { return nil }
        do {
            let resolved = try await ServiceResolver.resolve(name: entry.instanceName, type: type)
            guard !Task.isCancelled, desiredRunning.contains(entry.id) else { return nil }
            if BeaconLog.isVerboseEnabled {
                BeaconLog.engine.info("\(purpose.logPrefix, privacy: .public) resolved \(entry.instanceName, privacy: .private) with service type \(type, privacy: .public)")
            }
            return resolved
        } catch is CancellationError {
            return nil
        } catch {
            guard !Task.isCancelled, desiredRunning.contains(entry.id) else { return nil }
            if BeaconLog.isVerboseEnabled {
                BeaconLog.engine.debug("\(purpose.logPrefix, privacy: .public) could not resolve \(entry.instanceName, privacy: .private) as \(type, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
            return nil
        }
    }

    private func resolveOrder(for entry: WhitelistEntry) -> [String] {
        var seen = Set<String>()
        var order: [String] = []
        if let preferred = entry.preferredServiceType, !ServiceType.isMetaQuery(preferred) {
            order.append(preferred)
            seen.insert(preferred)
        }
        // The enumeration meta query lists service types, not instances: resolving
        // it can only ever time out.
        for type in store.settings.resolveServiceTypes
        where !ServiceType.isMetaQuery(type) && seen.insert(type).inserted {
            order.append(type)
        }
        return order
    }

    private func applyRegistration(entry: WhitelistEntry, type: String, resolved: ResolvedService) async {
        store.recordResolve(id: entry.id, host: resolved.hostTarget, port: resolved.displayPort, serviceType: type)
        let interfaceIndex = await broadcastInterface()
        if BeaconLog.isVerboseEnabled {
            BeaconLog.engine.info("Applying registration for \(entry.instanceName, privacy: .private) as \(type, privacy: .public) to \(resolved.hostTarget, privacy: .private):\(resolved.displayPort, privacy: .public) on interface \(interfaceIndex, privacy: .public)")
        }
        let registrar = active[entry.id]?.registrar ?? ServiceRegistrar()
        active[entry.id] = ActiveRegistration(registrar: registrar,
                                              type: type,
                                              port: resolved.port,
                                              txt: resolved.txtData,
                                              interfaceIndex: interfaceIndex)
        let host = ServiceType.trimmingTrailingDot(resolved.hostTarget)
        let displayPort = resolved.displayPort
        registrar.register(name: entry.instanceName,
                           type: type,
                           port: resolved.port,
                           txt: resolved.txtData,
                           interfaceIndex: interfaceIndex) { [weak self] state in
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
        await applyRegistration(entry: entry, type: type, resolved: resolved)
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
        updateBroadcastInterface(from: path)
        if path.status == .satisfied, lastPathStatus != .satisfied, lastPathStatus != nil {
            BeaconLog.engine.notice("Network became available; refreshing running services")
            refreshRunning()
            recoverStaleEntries()
        }
        lastPathStatus = path.status
    }

    /// Keep the publish interface in step with the network. Wi-Fi ↔ Ethernet moves
    /// are the case that matters: the old interface's advertisement has to be
    /// withdrawn and the new one used, or the LAN stops seeing the service.
    private func updateBroadcastInterface(from path: NWPath) {
        let candidates = LanInterfaces.candidates(from: path)
        let candidate = candidates.first?.index
        guard candidate != lanInterface else { return }
        lanInterface = candidate
        if let primary = candidates.first {
            BeaconLog.engine.notice("Re-broadcasting on \(primary.description, privacy: .public)")
        } else {
            BeaconLog.engine.notice("No LAN-facing interface with an address yet; publishing on all interfaces until one appears")
        }
        rebindActiveRegistrations()
    }

    /// Point live registrations at the current interface without re-resolving:
    /// only the interface changed, the service details did not.
    private func rebindActiveRegistrations() {
        let index = effectiveBroadcastInterface
        for id in Array(active.keys) {
            guard var registration = active[id], registration.interfaceIndex != index else { continue }
            registration.interfaceIndex = index
            active[id] = registration
            registration.registrar.updateInterface(index)
        }
        // Entries that failed while no LAN interface was known deserve another go.
        recoverStaleEntries()
    }

    /// Re-attempt services the user wants running that are not registered — failed,
    /// or waiting for their next scheduled retry. A network change is a good moment
    /// to try again: whatever caused the failure may be gone.
    private func recoverStaleEntries() {
        let stale = desiredRunning.subtracting(active.keys)
        guard !stale.isEmpty else { return }
        for id in stale {
            guard let entry = store.entries.first(where: { $0.id == id }) else { continue }
            cancelRetry(for: id)
            guard resolveTasks[id] == nil else { continue }
            if BeaconLog.isVerboseEnabled {
                BeaconLog.engine.info("Network changed; retrying \(entry.instanceName, privacy: .private)")
            }
            retryAttempts[id] = nil
            setState(.resolving, for: id)
            scheduleResolveTask(for: entry, purpose: .start)
        }
    }

    /// Interface to publish on: the LAN interface once the monitor has reported,
    /// and all interfaces (the pre-scoping behaviour) in the window before that.
    private var effectiveBroadcastInterface: UInt32 { lanInterface ?? 0 }

    /// The path monitor needs a moment after launch. Registering before it has
    /// reported would publish on every interface — including the container bridges
    /// — which is exactly what makes the daemon rename the service, so wait briefly
    /// for a LAN interface instead. Falling back to 0 after the wait keeps Beacon
    /// working on a Mac that has no LAN-facing address at all.
    private func broadcastInterface(timeout: Duration = .seconds(1)) async -> UInt32 {
        if let lanInterface { return lanInterface }
        if BeaconLog.isVerboseEnabled {
            BeaconLog.engine.info("Waiting up to \(timeout, privacy: .public) for the network path before registering")
        }
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if Task.isCancelled { break }
            try? await Task.sleep(for: .milliseconds(50))
            if let lanInterface { return lanInterface }
        }
        BeaconLog.engine.notice("No LAN-facing interface after waiting; publishing on all interfaces")
        return effectiveBroadcastInterface
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

    private func cancelRetry(for id: WhitelistEntry.ID) {
        retryTasks[id]?.cancel()
        retryTasks[id] = nil
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

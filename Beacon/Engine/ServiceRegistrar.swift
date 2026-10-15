import Foundation
import dnssd
import OSLog

/// Re-broadcasts a single service via `DNSServiceRegister`, holding the
/// registration alive until `stop()`. Registers with host = NULL so the SRV
/// target is the local machine, which is what makes the workaround function.
///
/// Registration is scoped to one interface. Passing `0` means "every interface the
/// daemon is on", which includes the container bridges where the original
/// advertisement lives; publishing the same instance name there makes the daemon
/// rename the re-broadcast ("Name (2)") on all interfaces. See `LanInterfaces`.
///
/// This is a worker object (not bound to the main actor); state changes are
/// reported through `onState`, always delivered on the main queue.
final class ServiceRegistrar {
    enum State: Equatable {
        case idle
        case registering
        /// Registered. `name` is the final instance name (the daemon may rename
        /// on conflict).
        case registered(name: String)
        case failed(String)
    }

    private struct Request: Equatable {
        let name: String
        let type: String
        let domain: String
        /// Network byte order, as produced by `ResolvedService.port`.
        let port: UInt16
        let txt: Data
    }

    private(set) var state: State = .idle
    private var ref: DNSServiceRef?
    private var context: UnsafeMutableRawPointer?
    private var request: Request?
    private var interfaceIndex: UInt32 = 0
    private var onState: ((State) -> Void)?
    private let queue = DispatchQueue(label: "beacon.register")
    /// Marks work already running on `queue`, so teardown never blocks on itself.
    private static let queueKey = DispatchSpecificKey<UInt8>()

    init() {
        queue.setSpecific(key: Self.queueKey, value: 1)
    }

    /// - Parameter interfaceIndex: interface to publish on, or 0 for all of them.
    func register(name: String,
                  type: String,
                  domain: String = "local",
                  port: UInt16,
                  txt: Data,
                  interfaceIndex: UInt32 = 0,
                  onState: @escaping (State) -> Void) {
        stop()
        request = Request(name: name, type: type, domain: domain, port: port, txt: txt)
        self.interfaceIndex = interfaceIndex
        self.onState = onState
        start()
    }

    /// Re-publish the current service on a different interface, keeping the name,
    /// port and TXT record. No-op when the interface did not change. Used when the
    /// LAN interface moves, e.g. Wi-Fi ↔ Ethernet. The previous registration is
    /// released first: leaving it alive would keep advertising on the interface
    /// Beacon no longer considers ours.
    func updateInterface(_ interfaceIndex: UInt32) {
        guard request != nil, interfaceIndex != self.interfaceIndex else { return }
        self.interfaceIndex = interfaceIndex
        start()
    }

    func stop() {
        let requestedName = request?.name
        onState = nil
        request = nil
        if state != .idle { set(.idle) }
        guard ref != nil || context != nil else { return }
        if BeaconLog.isVerboseEnabled {
            BeaconLog.registrar.info("Stopping registration for \(requestedName ?? "unknown", privacy: .private)")
        }
        releaseRegistration()
    }

    /// Releases the current ref and its retained context, if any. Idempotent, and
    /// guaranteed to have finished by the time it returns — see `teardown`.
    private func releaseRegistration() {
        let ref = self.ref; self.ref = nil
        let context = self.context; self.context = nil
        guard ref != nil || context != nil else { return }
        teardown(ref: ref, context: context)
    }

    // MARK: - Register

    private func start() {
        guard let request else { return }
        // Safe to call repeatedly: whatever registration is live is released first,
        // on the callback queue, so the instance name is free before this one probes
        // for it.
        releaseRegistration()
        set(.registering)
        if BeaconLog.isVerboseEnabled {
            BeaconLog.registrar.info("Registering \(request.name, privacy: .private) as \(request.type, privacy: .public) on port \(UInt16(bigEndian: request.port), privacy: .public) with \(request.txt.count, privacy: .public) TXT bytes on interface \(self.interfaceIndex, privacy: .public)")
        }

        let context = Unmanaged.passRetained(self).toOpaque()
        self.context = context

        var ref: DNSServiceRef?
        let callback: DNSServiceRegisterReply = { _, _, errorCode, name, _, _, context in
            guard let context else { return }
            let registrar = Unmanaged<ServiceRegistrar>.fromOpaque(context).takeUnretainedValue()
            let finalName = name.map { String(cString: $0) } ?? ""
            DispatchQueue.main.async {
                if errorCode.isOK {
                    registrar.report(registeredAs: finalName)
                } else {
                    BeaconLog.registrar.error("Register reply failed for \(finalName, privacy: .private): \(DNSSDError.message(for: errorCode), privacy: .public)")
                    registrar.set(.failed(DNSSDError(code: errorCode, context: "Register reply").localizedDescription))
                }
            }
        }

        let err = request.txt.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> DNSServiceErrorType in
            DNSServiceRegister(
                &ref,
                0,  // allow auto-rename: a re-broadcast coexists with the original as "name (2)"
                interfaceIndex,
                request.name,
                request.type,
                request.domain,
                nil,                                   // host = NULL → local machine
                request.port,                          // already network byte order
                UInt16(request.txt.count),
                raw.baseAddress,
                callback,
                context
            )
        }

        guard err.isOK, let ref else {
            self.context = nil
            Unmanaged<ServiceRegistrar>.fromOpaque(context).release()
            BeaconLog.registrar.error("DNSServiceRegister failed for \(request.name, privacy: .private) as \(request.type, privacy: .public) on interface \(self.interfaceIndex, privacy: .public): \(DNSSDError.message(for: err), privacy: .public)")
            set(.failed(DNSSDError(code: err, context: "DNSServiceRegister(\(request.name))").localizedDescription))
            return
        }
        self.ref = ref
        DNSServiceSetDispatchQueue(ref, queue)
    }

    /// The daemon renames a registration when the requested instance name is
    /// already taken on the interface we publish on. That is worth saying out loud:
    /// the LAN then sees a different instance name than the source service has, and
    /// the fix is to publish on an interface the source is not advertised on.
    private func report(registeredAs finalName: String) {
        if let requested = request?.name, finalName != requested {
            BeaconLog.registrar.error("Daemon renamed the re-broadcast: asked for \(requested, privacy: .private), registered as \(finalName, privacy: .private) on interface \(self.interfaceIndex, privacy: .public)")
        } else if BeaconLog.isVerboseEnabled {
            BeaconLog.registrar.info("Registered as \(finalName, privacy: .private)")
        }
        set(.registered(name: finalName))
    }

    // MARK: - Teardown

    private func teardown(ref: DNSServiceRef?, context: UnsafeMutableRawPointer?) {
        let work = {
            if let ref { DNSServiceRefDeallocate(ref) }
            if let context { Unmanaged<ServiceRegistrar>.fromOpaque(context).release() }
        }
        if DispatchQueue.getSpecific(key: Self.queueKey) != nil {
            work()
        } else {
            queue.sync(execute: work)
        }
    }

    private func set(_ newState: State) {
        state = newState
        onState?(newState)
    }
}

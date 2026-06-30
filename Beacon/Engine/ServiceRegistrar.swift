import Foundation
import dnssd

/// Re-broadcasts a single service via `DNSServiceRegister`, holding the
/// registration alive until `stop()`. Registers with host = NULL so the SRV
/// target is the local machine, which is what makes the workaround function.
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

    private(set) var state: State = .idle
    private var ref: DNSServiceRef?
    private var context: UnsafeMutableRawPointer?
    private var onState: ((State) -> Void)?
    private let queue = DispatchQueue(label: "beacon.register")

    /// - Parameter port: in **network byte order** (as produced by `ResolvedService.port`).
    func register(name: String,
                  type: String,
                  domain: String = "local",
                  port: UInt16,
                  txt: Data,
                  onState: @escaping (State) -> Void) {
        stop()
        self.onState = onState
        set(.registering)

        let context = Unmanaged.passRetained(self).toOpaque()
        self.context = context

        var ref: DNSServiceRef?
        let callback: DNSServiceRegisterReply = { _, _, errorCode, name, _, _, context in
            guard let context else { return }
            let registrar = Unmanaged<ServiceRegistrar>.fromOpaque(context).takeUnretainedValue()
            let finalName = name.map { String(cString: $0) } ?? ""
            DispatchQueue.main.async {
                if errorCode.isOK {
                    registrar.set(.registered(name: finalName))
                } else {
                    registrar.set(.failed(DNSSDError(code: errorCode, context: "Register reply").localizedDescription))
                }
            }
        }

        let err = txt.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> DNSServiceErrorType in
            DNSServiceRegister(
                &ref,
                0,  // allow auto-rename: a re-broadcast coexists with the original as "name (2)"
                0,
                name,
                type,
                domain,
                nil,                                   // host = NULL → local machine
                port,                                  // already network byte order
                UInt16(txt.count),
                raw.baseAddress,
                callback,
                context
            )
        }

        guard err.isOK, let ref else {
            self.context = nil
            Unmanaged<ServiceRegistrar>.fromOpaque(context).release()
            set(.failed(DNSSDError(code: err, context: "DNSServiceRegister(\(name))").localizedDescription))
            return
        }
        self.ref = ref
        DNSServiceSetDispatchQueue(ref, queue)
    }

    func stop() {
        onState = nil
        let ref = self.ref; self.ref = nil
        let context = self.context; self.context = nil
        if state != .idle { set(.idle) }
        guard ref != nil || context != nil else { return }
        queue.async {
            if let ref { DNSServiceRefDeallocate(ref) }
            if let context { Unmanaged<ServiceRegistrar>.fromOpaque(context).release() }
        }
    }

    private func set(_ newState: State) {
        state = newState
        onState?(newState)
    }
}

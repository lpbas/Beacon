import Foundation
import dnssd
import OSLog

/// The outcome of resolving a single service instance.
struct ResolvedService {
    let fullName: String
    /// SRV target host, e.g. "LP-mini.local." (informational only); we register
    /// with host = NULL so the broadcast points at the local machine (matching
    /// `dns-sd -R`, which is what makes the Docker/OrbStack workaround function).
    let hostTarget: String
    /// Port in **network byte order**, ready to hand straight to DNSServiceRegister.
    let port: UInt16
    /// Raw TXT record bytes, round-tripped verbatim into the re-broadcast.
    let txtData: Data
    let interfaceIndex: UInt32

    /// Port in host byte order, for display.
    var displayPort: UInt16 { UInt16(bigEndian: port) }
    var txtPairs: [(key: String, value: String)] { TXT.parse(txtData) }
}

/// One-shot resolve of a service instance via `DNSServiceResolve`, with a timeout
/// (the underlying call never stops on its own, exactly like `dns-sd -L`).
enum ServiceResolver {
    static func resolve(name: String,
                        type: String,
                        domain: String = "local",
                        interfaceIndex: UInt32 = 0,
                        timeout: TimeInterval = 3) async throws -> ResolvedService {
        let queue = DispatchQueue(label: "beacon.resolve")
        let cancellationBox = ResolveCancellationBox()
        try Task.checkCancellation()
        if BeaconLog.isVerboseEnabled {
            BeaconLog.resolver.info("Resolving \(name, privacy: .private) as \(type, privacy: .public) on interface \(interfaceIndex, privacy: .public)")
        }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let op = ResolveOperation(name: name,
                                          type: type,
                                          queue: queue,
                                          continuation: continuation) {
                    cancellationBox.clear($0)
                }
                let context = Unmanaged.passRetained(op).toOpaque()
                op.selfPtr = context

                var ref: DNSServiceRef?
                let err = DNSServiceResolve(
                    &ref,
                    0,
                    interfaceIndex,
                    name,
                    type,
                    domain,
                    { _, _, ifIndex, errorCode, fullname, hosttarget, port, txtLen, txtRecord, context in
                        guard let context else { return }
                        let op = Unmanaged<ResolveOperation>.fromOpaque(context).takeUnretainedValue()
                        op.handleReply(errorCode: errorCode,
                                       ifIndex: ifIndex,
                                       fullname: fullname,
                                       hosttarget: hosttarget,
                                       port: port,
                                       txtLen: txtLen,
                                       txtRecord: txtRecord)
                    },
                    context
                )

                guard err.isOK, let ref else {
                    BeaconLog.resolver.error("DNSServiceResolve failed for \(name, privacy: .private) as \(type, privacy: .public): \(DNSSDError.message(for: err), privacy: .public)")
                    op.fail(with: DNSSDError(code: err, context: "DNSServiceResolve(\(name))"))
                    return
                }

                op.ref = ref
                DNSServiceSetDispatchQueue(ref, queue)

                let timeoutItem = DispatchWorkItem {
                    op.fail(with: DNSSDError(code: DNSServiceErrorType(kDNSServiceErr_Timeout),
                                            context: "Resolving \"\(name)\" as \(type)"))
                }
                op.timeoutItem = timeoutItem
                queue.asyncAfter(deadline: .now() + timeout, execute: timeoutItem)

                guard cancellationBox.set(op) else {
                    op.cancel()
                    return
                }
            }
        } onCancel: {
            cancellationBox.cancel()
        }
    }
}

private final class ResolveCancellationBox {
    private let lock = NSLock()
    private var operation: ResolveOperation?
    private var isCancelled = false

    func set(_ operation: ResolveOperation) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !isCancelled else { return false }
        self.operation = operation
        return true
    }

    func cancel() {
        lock.lock()
        isCancelled = true
        let operation = self.operation
        self.operation = nil
        lock.unlock()
        operation?.cancel()
    }

    func clear(_ operation: ResolveOperation) {
        lock.lock()
        if self.operation === operation {
            self.operation = nil
        }
        lock.unlock()
    }
}

/// Holds the in-flight state for a single resolve. All completion paths funnel
/// through `finish`, which guarantees the continuation resumes exactly once and
/// the dns_sd resources are released.
private final class ResolveOperation {
    var ref: DNSServiceRef?
    var timeoutItem: DispatchWorkItem?
    var selfPtr: UnsafeMutableRawPointer?
    private let queue: DispatchQueue
    private let lock = NSLock()
    private var finished = false
    private let name: String
    private let type: String
    private let continuation: CheckedContinuation<ResolvedService, Error>
    private let onFinish: (ResolveOperation) -> Void

    init(name: String,
         type: String,
         queue: DispatchQueue,
         continuation: CheckedContinuation<ResolvedService, Error>,
         onFinish: @escaping (ResolveOperation) -> Void) {
        self.name = name
        self.type = type
        self.queue = queue
        self.continuation = continuation
        self.onFinish = onFinish
    }

    func handleReply(errorCode: DNSServiceErrorType,
                     ifIndex: UInt32,
                     fullname: UnsafePointer<CChar>?,
                     hosttarget: UnsafePointer<CChar>?,
                     port: UInt16,
                     txtLen: UInt16,
                     txtRecord: UnsafePointer<UInt8>?) {
        guard errorCode.isOK else {
            BeaconLog.resolver.error("Resolve reply failed for \(self.name, privacy: .private) as \(self.type, privacy: .public): \(DNSSDError.message(for: errorCode), privacy: .public)")
            fail(with: DNSSDError(code: errorCode, context: "Resolve reply"))
            return
        }
        let full = fullname.map { String(cString: $0) } ?? ""
        let host = hosttarget.map { String(cString: $0) } ?? ""
        let txt: Data = (txtRecord != nil && txtLen > 0) ? Data(bytes: txtRecord!, count: Int(txtLen)) : Data()
        let result = ResolvedService(fullName: full,
                                     hostTarget: host,
                                     port: port,
                                     txtData: txt,
                                     interfaceIndex: ifIndex)
        guard finish({ $0.resume(returning: result) }) else { return }
        if BeaconLog.isVerboseEnabled {
            BeaconLog.resolver.info("Resolved \(self.name, privacy: .private) as \(self.type, privacy: .public) to \(host, privacy: .private):\(result.displayPort, privacy: .public) with \(txt.count, privacy: .public) TXT bytes")
        }
    }

    @discardableResult
    func fail(with error: Error, shouldLog: Bool = true) -> Bool {
        guard finish({ $0.resume(throwing: error) }) else { return false }
        if shouldLog, BeaconLog.isVerboseEnabled {
            BeaconLog.resolver.debug("Resolve finished with error for \(self.name, privacy: .private) as \(self.type, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
        return true
    }

    func cancel() {
        queue.async {
            self.fail(with: CancellationError(), shouldLog: false)
        }
    }

    @discardableResult
    private func finish(_ body: (CheckedContinuation<ResolvedService, Error>) -> Void) -> Bool {
        lock.lock()
        guard !finished else {
            lock.unlock()
            return false
        }
        finished = true
        let timeoutItem = self.timeoutItem
        let ref = self.ref
        let selfPtr = self.selfPtr
        self.timeoutItem = nil
        self.ref = nil
        self.selfPtr = nil
        lock.unlock()

        timeoutItem?.cancel()
        if let ref { DNSServiceRefDeallocate(ref) }
        body(continuation)
        onFinish(self)
        if let selfPtr { Unmanaged<ResolveOperation>.fromOpaque(selfPtr).release() }
        return true
    }
}

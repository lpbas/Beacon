import Foundation
import dnssd

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
        return try await withCheckedThrowingContinuation { continuation in
            let op = ResolveOperation(continuation: continuation)
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
        }
    }
}

/// Holds the in-flight state for a single resolve. All completion paths funnel
/// through `finish`, which guarantees the continuation resumes exactly once and
/// the dns_sd resources are released.
private final class ResolveOperation {
    var ref: DNSServiceRef?
    var timeoutItem: DispatchWorkItem?
    var selfPtr: UnsafeMutableRawPointer?
    private var finished = false
    private let continuation: CheckedContinuation<ResolvedService, Error>

    init(continuation: CheckedContinuation<ResolvedService, Error>) {
        self.continuation = continuation
    }

    func handleReply(errorCode: DNSServiceErrorType,
                     ifIndex: UInt32,
                     fullname: UnsafePointer<CChar>?,
                     hosttarget: UnsafePointer<CChar>?,
                     port: UInt16,
                     txtLen: UInt16,
                     txtRecord: UnsafePointer<UInt8>?) {
        guard !finished else { return }
        guard errorCode.isOK else {
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
        finish { $0.resume(returning: result) }
    }

    func fail(with error: Error) {
        guard !finished else { return }
        finish { $0.resume(throwing: error) }
    }

    private func finish(_ body: (CheckedContinuation<ResolvedService, Error>) -> Void) {
        finished = true
        timeoutItem?.cancel()
        timeoutItem = nil
        if let ref {
            DNSServiceRefDeallocate(ref)
            self.ref = nil
        }
        body(continuation)
        if let selfPtr {
            self.selfPtr = nil
            Unmanaged<ResolveOperation>.fromOpaque(selfPtr).release()
        }
    }
}

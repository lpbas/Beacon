import Foundation
import Observation
import dnssd

/// A service instance discovered by browsing (not yet resolved).
struct DiscoveredService: Identifiable, Hashable {
    let name: String
    /// regtype as returned by the daemon, e.g. "_hap._tcp."
    let type: String
    /// reply domain, e.g. "local."
    let domain: String
    let interfaceIndex: UInt32

    var id: String { "\(name)|\(type)|\(domain)|\(interfaceIndex)" }

    /// Service type without trailing dot, e.g. "_hap._tcp".
    var serviceType: String { ServiceType.trimmingTrailingDot(type) }
    /// Domain without trailing dot, e.g. "local".
    var resolveDomain: String { ServiceType.trimmingTrailingDot(domain) }
}

/// Live browse across one or more service types via `DNSServiceBrowse`.
/// Observed by the Discovery screen; `services` is only mutated on the main thread.
@Observable
final class ServiceBrowser {
    private(set) var services: [DiscoveredService] = []
    private(set) var isBrowsing = false

    @ObservationIgnored private var refs: [DNSServiceRef] = []
    @ObservationIgnored private var contexts: [UnsafeMutableRawPointer] = []
    @ObservationIgnored private let queue = DispatchQueue(label: "beacon.browse")

    func start(types: [String]) {
        stop()
        guard !types.isEmpty else { return }
        isBrowsing = true
        for type in types { browse(type: type) }
    }

    func stop() {
        let refs = self.refs; self.refs.removeAll()
        let contexts = self.contexts; self.contexts.removeAll()
        services.removeAll()
        isBrowsing = false
        guard !refs.isEmpty || !contexts.isEmpty else { return }
        // Deallocate on the same serial queue the callbacks use, so we never tear
        // down a ref while a callback for it is running.
        queue.async {
            for ref in refs { DNSServiceRefDeallocate(ref) }
            for ctx in contexts { Unmanaged<ServiceBrowser>.fromOpaque(ctx).release() }
        }
    }

    private func browse(type: String) {
        let context = Unmanaged.passRetained(self).toOpaque()
        var ref: DNSServiceRef?
        let err = DNSServiceBrowse(
            &ref,
            0,
            0,
            type,
            "local",
            { _, flags, ifIndex, errorCode, serviceName, regtype, replyDomain, context in
                guard let context, errorCode.isOK else { return }
                let browser = Unmanaged<ServiceBrowser>.fromOpaque(context).takeUnretainedValue()
                let isAdd = (flags & DNSServiceFlags(kDNSServiceFlagsAdd)) != 0
                let svc = DiscoveredService(
                    name: serviceName.map { String(cString: $0) } ?? "",
                    type: regtype.map { String(cString: $0) } ?? "",
                    domain: replyDomain.map { String(cString: $0) } ?? "",
                    interfaceIndex: ifIndex
                )
                DispatchQueue.main.async { browser.apply(svc, isAdd: isAdd) }
            },
            context
        )

        guard err.isOK, let ref else {
            Unmanaged<ServiceBrowser>.fromOpaque(context).release()
            return
        }
        DNSServiceSetDispatchQueue(ref, queue)
        refs.append(ref)
        contexts.append(context)
    }

    private func apply(_ service: DiscoveredService, isAdd: Bool) {
        if isAdd {
            if !services.contains(service) { services.append(service) }
        } else {
            services.removeAll { $0 == service }
        }
    }
}

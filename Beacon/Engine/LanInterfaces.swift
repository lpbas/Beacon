import Foundation
import Network

/// Picks the interface Beacon re-broadcasts on.
///
/// `DNSServiceRegister` takes a single `interfaceIndex`, and `0` means "every
/// interface the daemon is running on". That is what the first release passed, and
/// it is the reason a re-broadcast can come out renamed: the Docker/OrbStack
/// container bridges are part of "every interface", and the original advertisement
/// lives there. Publishing the same instance name on those bridges collides with the
/// original record, and the daemon resolves the collision by silently renaming the
/// re-broadcast to "Name (2)" — on *every* interface, the LAN included. It also put
/// the service on `lo0` and the VPN tunnels, where nobody needs it.
///
/// So: exactly one interface, the primary LAN-facing one. One rather than all of
/// them is deliberate — two LAN interfaces on the same link would put the same
/// instance name on the wire twice, which can trigger the very rename this avoids.
enum LanInterfaces {
    /// A LAN-facing interface we could re-broadcast on.
    struct Candidate: CustomStringConvertible {
        let index: UInt32
        let name: String
        let type: String
        let address: String

        var description: String { "\(name) (\(type), index \(index), \(address))" }
    }

    /// Interface kinds that can reach LAN peers. Tunnels (`utun*`, `ipsec*`), the
    /// container bridges (`bridge100`/`bridge101`), AWDL and `lo0` all report
    /// `.other`, which is exactly the set we do not want to publish on.
    static func isLanCandidate(_ interface: NWInterface) -> Bool {
        switch interface.type {
        case .wiredEthernet, .wifi: return true
        default: return false
        }
    }

    /// LAN-facing interfaces from a path, in the path's order of preference.
    static func candidates(from path: NWPath) -> [Candidate] {
        path.availableInterfaces.compactMap { interface in
            guard isLanCandidate(interface),
                  let address = routableAddress(of: interface.index) else { return nil }
            return Candidate(index: UInt32(interface.index),
                             name: interface.name,
                             type: describe(interface.type),
                             address: address)
        }
    }

    /// The interface to re-broadcast on, or `nil` when the Mac has no LAN address
    /// yet. The path monitor reports that later and the engine re-binds.
    static func primary(from path: NWPath) -> Candidate? {
        candidates(from: path).first
    }

    /// First non-link-local address on `index`, if it has one. An interface can be
    /// "available" (cable plugged in, Wi-Fi associated) without ever getting an
    /// address, and registering on it would reach nobody.
    private static func routableAddress(of index: Int) -> String? {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0 else { return nil }
        defer { freeifaddrs(head) }

        var cursor = head
        while let entry = cursor {
            defer { cursor = entry.pointee.ifa_next }
            guard let addr = entry.pointee.ifa_addr else { continue }
            let family = addr.pointee.sa_family
            guard family == UInt8(AF_INET) || family == UInt8(AF_INET6) else { continue }
            guard let name = entry.pointee.ifa_name,
                  if_nametoindex(name) == UInt32(index) else { continue }

            var text = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let result = getnameinfo(addr,
                                     socklen_t(addr.pointee.sa_len),
                                     &text,
                                     socklen_t(text.count),
                                     nil,
                                     0,
                                     NI_NUMERICHOST)
            guard result == 0 else { continue }
            let address = String(cString: text)
            guard !address.hasPrefix("169.254."),      // IPv4 link-local
                  !address.hasPrefix("fe80:"),         // IPv6 link-local
                  address != "::1",
                  !address.hasPrefix("127.") else { continue }
            return address
        }
        return nil
    }

    private static func describe(_ type: NWInterface.InterfaceType) -> String {
        switch type {
        case .wiredEthernet: return "ethernet"
        case .wifi: return "wifi"
        case .cellular: return "cellular"
        case .loopback: return "loopback"
        default: return "other"
        }
    }
}

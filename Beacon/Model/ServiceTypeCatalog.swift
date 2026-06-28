import Foundation

/// A named group of mDNS service types, ported from the `SERVICE_GROUPS` table in
/// the original homekit-mdns-broadcaster.py. Order is preserved, with `homekit`
/// first so it's the fast default.
struct ServiceGroup: Identifiable, Hashable {
    let id: String
    let title: String
    let types: [String]
    /// Whether the group is part of the "scan everything" set. `enumeration` is a
    /// meta-query, so it's excluded (matching NON_DEFAULT_GROUPS in the script).
    let includedInAll: Bool
}

enum ServiceTypeCatalog {
    static let groups: [ServiceGroup] = [
        ServiceGroup(id: "homekit", title: "HomeKit & Matter", types: [
            "_hap._tcp", "_homekit._tcp", "_matterc._udp", "_matter._tcp", "_matterd._udp",
        ], includedInAll: true),
        ServiceGroup(id: "enumeration", title: "Service Enumeration", types: [
            "_services._dns-sd._udp",
        ], includedInAll: false),
        ServiceGroup(id: "web", title: "Web & Remote Access", types: [
            "_http._tcp", "_https._tcp", "_ssh._tcp", "_telnet._tcp", "_rfb._tcp",
            "_rdp._tcp", "_webdav._tcp", "_workstation._tcp",
        ], includedInAll: true),
        ServiceGroup(id: "files", title: "File Sharing", types: [
            "_ftp._tcp", "_smb._tcp", "_afpovertcp._tcp", "_nfs._tcp", "_adisk._tcp",
            "_esdevice._tcp", "_esfileshare._tcp",
        ], includedInAll: true),
        ServiceGroup(id: "printing", title: "Printing & Scanning", types: [
            "_ipp._tcp", "_ipps._tcp", "_printer._tcp", "_scanner._tcp", "_printer._sub._http._tcp",
        ], includedInAll: true),
        ServiceGroup(id: "apple", title: "Apple Devices", types: [
            "_airdrop._tcp", "_airplay._tcp", "_raop._tcp", "_airport._tcp", "_appletv-v2._tcp",
            "_companion-link._tcp", "_home-sharing._tcp", "_daap._tcp", "_dpap._tcp", "_atc._tcp",
            "_device-info._tcp", "_apple-mobdev2._tcp", "_apple-sasl._tcp", "_eppc._tcp",
            "_ica-networking._tcp", "_ichat._tcp",
        ], includedInAll: true),
        ServiceGroup(id: "google", title: "Google & Cast", types: [
            "_googlecast._tcp", "_googlezone._tcp", "_androidtvremote._tcp",
            "_amzn-wplay._tcp", "_amazonecho-remote._tcp",
        ], includedInAll: true),
        ServiceGroup(id: "iot", title: "Smart Home / IoT", types: [
            "_shelly._tcp", "_philipshue._tcp", "_aqara._tcp", "_aqara-setup._tcp", "_tplink._tcp",
        ], includedInAll: true),
        ServiceGroup(id: "media", title: "Media & Streaming", types: [
            "_spotify-connect._tcp", "_sonos._tcp", "_roku._tcp", "_rsp._tcp",
            "_plexmediasvr._tcp", "_xbmc-jsonrpc-h._tcp", "_bose._tcp",
        ], includedInAll: true),
        ServiceGroup(id: "dev", title: "Developer Tools", types: [
            "_hudson._tcp", "_jenkins._tcp", "_distcc._tcp", "_sketchmirror._tcp",
            "_bcbonjour._tcp", "_cloud._tcp", "_airdroid._tcp",
        ], includedInAll: true),
        ServiceGroup(id: "p2p", title: "Peer-to-Peer", types: [
            "_bp2p._tcp", "_Friendly._sub._bp2p._tcp", "_invoke._sub._bp2p._tcp", "_webdav._sub._bp2p._tcp",
        ], includedInAll: true),
    ]

    static func group(id: String) -> ServiceGroup? {
        groups.first { $0.id == id }
    }

    /// All service types across every group, de-duplicated, in catalog order.
    static let allTypes: [String] = {
        var seen = Set<String>()
        var result: [String] = []
        for group in groups {
            for type in group.types where seen.insert(type).inserted {
                result.append(type)
            }
        }
        return result
    }()

    /// A human-friendly label for common service types; falls back to the raw type.
    static func friendlyName(for type: String) -> String {
        friendlyNames[ServiceType.trimmingTrailingDot(type)] ?? ServiceType.trimmingTrailingDot(type)
    }

    private static let friendlyNames: [String: String] = [
        "_hap._tcp": "HomeKit Accessory",
        "_homekit._tcp": "HomeKit",
        "_matter._tcp": "Matter",
        "_matterc._udp": "Matter (commissioning)",
        "_http._tcp": "Web (HTTP)",
        "_https._tcp": "Web (HTTPS)",
        "_ssh._tcp": "SSH",
        "_rfb._tcp": "Screen Sharing (VNC)",
        "_smb._tcp": "File Sharing (SMB)",
        "_afpovertcp._tcp": "File Sharing (AFP)",
        "_ipp._tcp": "Printer (IPP)",
        "_ipps._tcp": "Printer (IPPS)",
        "_airplay._tcp": "AirPlay",
        "_raop._tcp": "AirPlay Audio",
        "_companion-link._tcp": "Apple Companion",
        "_device-info._tcp": "Device Info",
        "_googlecast._tcp": "Google Cast",
        "_spotify-connect._tcp": "Spotify Connect",
        "_sonos._tcp": "Sonos",
        "_plexmediasvr._tcp": "Plex",
    ]
}

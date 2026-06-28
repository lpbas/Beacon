import Foundation

/// User-configurable settings, persisted as JSON alongside the whitelist.
struct AppSettings: Codable, Equatable {
    /// Catalog group IDs whose service types are used for discovery and the
    /// resolve search order.
    var selectedGroupIDs: Set<String>
    /// Extra literal service types (e.g. "_custom._tcp") added on top of groups.
    var extraServiceTypes: [String]
    var launchAtLogin: Bool
    /// Delay before auto-starting broadcasts at launch (the script's `--delay`).
    var startDelaySeconds: Int
    /// Re-resolve interval in minutes to catch container restarts; 0 = off.
    var autoRefreshMinutes: Int
    var verboseLogging: Bool
    /// Automatically start enabled services when the app launches.
    var startBroadcastingOnLaunch: Bool

    static let `default` = AppSettings(
        selectedGroupIDs: ["homekit"],
        extraServiceTypes: [],
        launchAtLogin: false,
        startDelaySeconds: 0,
        autoRefreshMinutes: 0,
        verboseLogging: false,
        startBroadcastingOnLaunch: true
    )

    /// Ordered, de-duplicated service types to scan: selected groups in catalog
    /// order, then extras. Mirrors the Python script's group/type resolution.
    var resolveServiceTypes: [String] {
        var seen = Set<String>()
        var result: [String] = []
        for group in ServiceTypeCatalog.groups where selectedGroupIDs.contains(group.id) {
            for type in group.types where seen.insert(type).inserted {
                result.append(type)
            }
        }
        for type in extraServiceTypes where seen.insert(type).inserted {
            result.append(type)
        }
        return result
    }

    /// Service types to browse on the Discovery screen (same set, minus the
    /// meta enumeration query which isn't a browsable instance type).
    var discoveryServiceTypes: [String] {
        resolveServiceTypes.filter { $0 != "_services._dns-sd._udp" }
    }
}

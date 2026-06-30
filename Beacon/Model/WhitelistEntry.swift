import Foundation

/// A service the user wants Beacon to re-broadcast. Stored as the exact dns-sd
/// instance name (as seen in `dns-sd -B`); the service type is learned on resolve.
struct WhitelistEntry: Identifiable, Codable, Hashable {
    var id: UUID
    /// Exact instance name, e.g. "HASS Bridge WP C94970".
    var instanceName: String
    /// Service type that last resolved (tried first next time), e.g. "_hap._tcp".
    var preferredServiceType: String?
    /// When false the entry is paused: kept but never broadcast.
    var isEnabled: Bool
    var notes: String

    // Informational snapshot from the most recent successful resolve.
    var lastResolvedHost: String?
    var lastResolvedPort: UInt16?
    var lastResolvedDate: Date?

    init(id: UUID = UUID(),
         instanceName: String,
         preferredServiceType: String? = nil,
         isEnabled: Bool = true,
         notes: String = "") {
        self.id = id
        self.instanceName = instanceName
        self.preferredServiceType = preferredServiceType
        self.isEnabled = isEnabled
        self.notes = notes
    }

    /// "host:port" if we've resolved it at least once, else nil.
    var lastResolvedSummary: String? {
        guard let host = lastResolvedHost, let port = lastResolvedPort else { return nil }
        return "\(ServiceType.trimmingTrailingDot(host)):\(port)"
    }
}

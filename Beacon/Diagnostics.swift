import Foundation
import OSLog

/// Centralized Unified Logging configuration.
///
/// Logs are available in Console.app by filtering for the subsystem
/// `com.lplaboratories.beacon`, or from Terminal:
///
///     log stream --predicate 'subsystem == "com.lplaboratories.beacon"'
enum BeaconLog {
    static let subsystem = "com.lplaboratories.beacon"

    static let app = Logger(subsystem: subsystem, category: "app")
    static let store = Logger(subsystem: subsystem, category: "store")
    static let browser = Logger(subsystem: subsystem, category: "browser")
    static let resolver = Logger(subsystem: subsystem, category: "resolver")
    static let registrar = Logger(subsystem: subsystem, category: "registrar")
    static let engine = Logger(subsystem: subsystem, category: "engine")

    private static let lock = NSLock()
    private static var verboseLogging = false

    static var isVerboseEnabled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return verboseLogging
    }

    static func setVerboseLogging(_ enabled: Bool, announce: Bool = true) {
        lock.lock()
        let changed = verboseLogging != enabled
        verboseLogging = enabled
        lock.unlock()

        guard announce && changed else { return }
        let state = enabled ? "enabled" : "disabled"
        app.notice("Verbose diagnostics \(state, privacy: .public)")
    }
}

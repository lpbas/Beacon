import Foundation
import Observation
import OSLog

/// Owns the persisted app state (whitelist + settings) as JSON files in
/// Application Support, and is the single source of truth shared across screens.
@Observable
@MainActor
final class Store {
    var settings: AppSettings {
        didSet {
            guard settings != oldValue else { return }
            if settings.verboseLogging != oldValue.verboseLogging {
                BeaconLog.setVerboseLogging(settings.verboseLogging)
            }
            saveSettings()
        }
    }
    private(set) var entries: [WhitelistEntry]

    @ObservationIgnored private let directory: URL
    @ObservationIgnored private let settingsURL: URL
    @ObservationIgnored private let entriesURL: URL

    init() {
        let base = (try? FileManager.default.url(for: .applicationSupportDirectory,
                                                 in: .userDomainMask,
                                                 appropriateFor: nil,
                                                 create: true))
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        let dir = base.appendingPathComponent("Beacon", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        directory = dir
        settingsURL = dir.appendingPathComponent("settings.json")
        entriesURL = dir.appendingPathComponent("whitelist.json")

        settings = Self.load(AppSettings.self, from: settingsURL) ?? .default
        entries = Self.load([WhitelistEntry].self, from: entriesURL) ?? []
        BeaconLog.setVerboseLogging(settings.verboseLogging, announce: false)
        BeaconLog.store.notice("Loaded settings and \(self.entries.count, privacy: .public) whitelist entries")
    }

    // MARK: - Entry mutations

    /// Add an entry if its instance name isn't already present. Returns the entry
    /// (existing or new).
    @discardableResult
    func addEntry(instanceName: String, preferredServiceType: String? = nil) -> WhitelistEntry {
        let trimmed = instanceName.trimmingCharacters(in: .whitespacesAndNewlines)
        if let existing = entries.first(where: { $0.instanceName == trimmed }) {
            return existing
        }
        let entry = WhitelistEntry(instanceName: trimmed, preferredServiceType: preferredServiceType)
        entries.append(entry)
        saveEntries()
        return entry
    }

    func update(_ entry: WhitelistEntry) {
        guard let idx = entries.firstIndex(where: { $0.id == entry.id }) else { return }
        entries[idx] = entry
        saveEntries()
    }

    func setEnabled(_ enabled: Bool, for id: WhitelistEntry.ID) {
        guard let idx = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[idx].isEnabled = enabled
        saveEntries()
    }

    func delete(_ id: WhitelistEntry.ID) {
        entries.removeAll { $0.id == id }
        saveEntries()
    }

    func delete(atOffsets offsets: IndexSet) {
        entries.remove(atOffsets: offsets)
        saveEntries()
    }

    func move(fromOffsets source: IndexSet, toOffset destination: Int) {
        entries.move(fromOffsets: source, toOffset: destination)
        saveEntries()
    }

    /// Record the most recent successful resolve for display.
    func recordResolve(id: WhitelistEntry.ID, host: String, port: UInt16, serviceType: String) {
        guard let idx = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[idx].lastResolvedHost = host
        entries[idx].lastResolvedPort = port
        entries[idx].lastResolvedDate = Date()
        entries[idx].preferredServiceType = serviceType
        saveEntries()
    }

    // MARK: - Legacy import

    /// Import a plain-text `service_whitelist.txt` (one instance name per line,
    /// `#` comments ignored), as used by the original Python script. Returns the
    /// number of new entries added.
    @discardableResult
    func importLegacyWhitelist(at url: URL) throws -> Int {
        let text = try String(contentsOf: url, encoding: .utf8)
        let names = text
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
        let before = entries.count
        for name in names { addEntry(instanceName: name) }
        let importedCount = entries.count - before
        BeaconLog.store.notice("Imported \(importedCount, privacy: .public) whitelist entries from legacy file")
        return importedCount
    }

    // MARK: - Persistence

    private static func load<T: Decodable>(_ type: T.Type, from url: URL) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder.beacon.decode(T.self, from: data)
    }

    private func saveSettings() { write(settings, to: settingsURL) }
    private func saveEntries() { write(entries, to: entriesURL) }

    private func write<T: Encodable>(_ value: T, to url: URL) {
        do {
            let data = try JSONEncoder.beacon.encode(value)
            try data.write(to: url, options: .atomic)
        } catch {
            BeaconLog.store.error("Failed to save \(url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }
}

private extension JSONEncoder {
    static var beacon: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

private extension JSONDecoder {
    static var beacon: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

import Foundation

/// Identifiers retained from Paster so an in-place upgrade keeps existing data and settings.
enum LegacyCompatibility {
    static let applicationSupportDirectoryName = "Paster"
    static let bundleIdentifier = "com.davidgrossman.Paster"
    static let settingsKey = "settings"
    static let hasLaunchedKey = "hasLaunched"
    static let clipDragTypeIdentifier = "com.davidgrossman.paster.clip-ids"
    static let boardDragTypeIdentifier = "com.davidgrossman.paster.board-id"
}

struct AppSettings: Codable, Equatable {
    var maxItems = 2000
    var retentionDays = 30
    var ignoredBundleIDs = ClipboardService.defaultIgnored.joined(separator: "\n")
    var launchAtLogin = false
    var soundEnabled = false
    var pasteAfterSelection = true
    @MainActor static func load(from defaults: UserDefaults = .standard) -> Self {
        guard let data = defaults.data(forKey: LegacyCompatibility.settingsKey), let value = try? JSONDecoder().decode(Self.self, from: data) else { return Self() }
        return value
    }
    func save(to defaults: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(self) {
            defaults.set(data, forKey: LegacyCompatibility.settingsKey)
        }
    }
}

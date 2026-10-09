import Foundation

struct AppSettings: Codable, Equatable {
    var maxItems = 2000
    var retentionDays = 30
    var ignoredBundleIDs = ClipboardService.defaultIgnored.joined(separator: "\n")
    var launchAtLogin = false
    var soundEnabled = false
    var pasteAfterSelection = true
    @MainActor static func load() -> Self {
        guard let data = UserDefaults.standard.data(forKey: "settings"), let value = try? JSONDecoder().decode(Self.self, from: data) else { return Self() }
        return value
    }
    func save() { if let data = try? JSONEncoder().encode(self) { UserDefaults.standard.set(data, forKey: "settings") } }
}

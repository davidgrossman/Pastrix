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
    var shortcut = GlobalShortcut.default
    var historyOrder = ClipSortOrder.newestFirst
    var boardOrder = ClipSortOrder.manual
    init(maxItems: Int = 2000, retentionDays: Int = 30,
         ignoredBundleIDs: String = ClipboardService.defaultIgnored.joined(separator: "\n"),
         launchAtLogin: Bool = false, soundEnabled: Bool = false,
         pasteAfterSelection: Bool = true, shortcut: GlobalShortcut = .default,
         historyOrder: ClipSortOrder = .newestFirst, boardOrder: ClipSortOrder = .manual) {
        self.maxItems = maxItems
        self.retentionDays = retentionDays
        self.ignoredBundleIDs = ignoredBundleIDs
        self.launchAtLogin = launchAtLogin
        self.soundEnabled = soundEnabled
        self.pasteAfterSelection = pasteAfterSelection
        self.shortcut = shortcut
        self.historyOrder = historyOrder
        self.boardOrder = boardOrder
    }
    private enum CodingKeys: String, CodingKey {
        case maxItems, retentionDays, ignoredBundleIDs, launchAtLogin, soundEnabled, pasteAfterSelection
        case shortcut, historyOrder, boardOrder
    }
    init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        maxItems = try c.decodeIfPresent(Int.self, forKey: .maxItems) ?? maxItems
        retentionDays = try c.decodeIfPresent(Int.self, forKey: .retentionDays) ?? retentionDays
        ignoredBundleIDs = try c.decodeIfPresent(String.self, forKey: .ignoredBundleIDs) ?? ignoredBundleIDs
        launchAtLogin = try c.decodeIfPresent(Bool.self, forKey: .launchAtLogin) ?? launchAtLogin
        soundEnabled = try c.decodeIfPresent(Bool.self, forKey: .soundEnabled) ?? soundEnabled
        pasteAfterSelection = try c.decodeIfPresent(Bool.self, forKey: .pasteAfterSelection) ?? pasteAfterSelection
        let stored = try c.decodeIfPresent(GlobalShortcut.self, forKey: .shortcut)
        if let stored, stored.isValid { shortcut = stored }
        historyOrder = try c.decodeIfPresent(ClipSortOrder.self, forKey: .historyOrder) ?? historyOrder
        boardOrder = try c.decodeIfPresent(ClipSortOrder.self, forKey: .boardOrder) ?? boardOrder
    }
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

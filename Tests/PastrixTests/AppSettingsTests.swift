import XCTest
import Carbon
@testable import Pastrix

final class AppSettingsTests: XCTestCase {
    @MainActor func testFailedShortcutChangeKeepsCurrentPreference() throws {
        let model = try AppModel(demo: true)
        model.onChangeShortcut = { _ in false }
        let replacement = GlobalShortcut(keyCode: UInt32(kVK_ANSI_P), modifiers: UInt32(cmdKey | optionKey), key: "P")
        model.changeShortcut(replacement)
        XCTAssertEqual(model.settings.shortcut, .default)
        XCTAssertNotNil(model.shortcutError)
        model.onChangeShortcut = { _ in true }
        model.changeShortcut(replacement)
        XCTAssertEqual(model.settings.shortcut, replacement)
        XCTAssertNil(model.shortcutError)
    }
    func testOldSettingsKeepValuesAndDefaultNewFields() throws {
        let data = Data(#"{"maxItems":700,"retentionDays":14,"ignoredBundleIDs":"test.app","launchAtLogin":false,"soundEnabled":true,"pasteAfterSelection":false}"#.utf8)
        let settings = try JSONDecoder().decode(AppSettings.self, from: data)
        XCTAssertEqual(settings.maxItems, 700)
        XCTAssertTrue(settings.soundEnabled)
        XCTAssertFalse(settings.pasteAfterSelection)
        XCTAssertEqual(settings.shortcut, .default)
        XCTAssertEqual(settings.historyOrder, .newestFirst)
        XCTAssertEqual(settings.boardOrder, .manual)
    }
    func testShortcutAndOrderingRoundTripAndRejectReservedCommands() throws {
        var settings = AppSettings()
        settings.shortcut = GlobalShortcut(keyCode: UInt32(kVK_ANSI_P), modifiers: UInt32(cmdKey | optionKey), key: "P")
        settings.historyOrder = .manual
        XCTAssertEqual(try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings)), settings)
        XCTAssertTrue(settings.shortcut.isValid)
        XCTAssertFalse(GlobalShortcut(keyCode: UInt32(kVK_ANSI_V), modifiers: UInt32(cmdKey | controlKey), key: "V").isValid)
        XCTAssertFalse(GlobalShortcut(keyCode: UInt32(kVK_ANSI_Comma), modifiers: UInt32(cmdKey), key: ",").isValid)
        XCTAssertFalse(GlobalShortcut(keyCode: 0, modifiers: 0, key: "A").isValid)
        XCTAssertEqual(GlobalShortcut.default.display, "⇧⌘V")
    }
}

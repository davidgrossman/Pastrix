import Foundation
import XCTest
@testable import Pastrix

final class BrandCompatibilityTests: XCTestCase {
    func testLegacyIdentifiersRemainStableAcrossRebrand() {
        XCTAssertEqual(LegacyCompatibility.applicationSupportDirectoryName, "Paster")
        XCTAssertEqual(LegacyCompatibility.bundleIdentifier, "com.davidgrossman.Paster")
        XCTAssertEqual(LegacyCompatibility.settingsKey, "settings")
        XCTAssertEqual(LegacyCompatibility.hasLaunchedKey, "hasLaunched")
        XCTAssertEqual(LegacyCompatibility.clipDragTypeIdentifier, "com.davidgrossman.paster.clip-ids")
        XCTAssertEqual(LegacyCompatibility.boardDragTypeIdentifier, "com.davidgrossman.paster.board-id")
    }

    @MainActor
    func testSettingsLoadFromLegacyPreferenceKey() throws {
        let suiteName = "PastrixTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let expected = AppSettings(
            maxItems: 321,
            retentionDays: 17,
            ignoredBundleIDs: "com.example.private",
            launchAtLogin: true,
            soundEnabled: true,
            pasteAfterSelection: false
        )
        defaults.set(try JSONEncoder().encode(expected), forKey: "settings")

        XCTAssertEqual(AppSettings.load(from: defaults), expected)
    }
}

import Foundation
import XCTest
@testable import Pastrix

final class ReleaseToolsTests: XCTestCase {
    func testNumericComparisonDoesNotUseLexicographicOrdering() {
        XCTAssertEqual(
            ReleaseTools.compareNumericVersions("1.10", "1.9"),
            .orderedDescending
        )
        XCTAssertEqual(
            ReleaseTools.compareNumericVersions("2.3.4", "2.12.0"),
            .orderedAscending
        )
    }

    func testTrailingZeroComponentsAreEquivalent() {
        XCTAssertEqual(
            ReleaseTools.compareNumericVersions("1.2", "1.2.0.0"),
            .orderedSame
        )
        XCTAssertEqual(
            ReleaseTools.compareNumericVersions("01.002.0003", "1.2.3"),
            .orderedSame
        )
    }

    func testMalformedVersionsCannotBeCompared() {
        XCTAssertNil(ReleaseTools.compareNumericVersions("1.2-beta", "1.2"))
        XCTAssertNil(ReleaseTools.compareNumericVersions("1..2", "1.2"))
        XCTAssertNil(ReleaseTools.compareNumericVersions("", "1.2"))
    }

    func testDecodesNumericVersionFromGitHubReleaseResponse() throws {
        let response = Data(#"{"tag_name":"v1.2.2","name":"Pastrix 1.2.2"}"#.utf8)

        XCTAssertEqual(
            try ReleaseTools.decodeLatestReleaseVersion(from: response),
            "1.2.2"
        )
    }

    func testRejectsMissingOrNonnumericReleaseTags() {
        let missingTag = Data(#"{"name":"Pastrix 1.2.2"}"#.utf8)
        let prereleaseTag = Data(#"{"tag_name":"v1.2.2-beta"}"#.utf8)

        XCTAssertThrowsError(
            try ReleaseTools.decodeLatestReleaseVersion(from: missingTag)
        )
        XCTAssertThrowsError(
            try ReleaseTools.decodeLatestReleaseVersion(from: prereleaseTag)
        )
    }
}

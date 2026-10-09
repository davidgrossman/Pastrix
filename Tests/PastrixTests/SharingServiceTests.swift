import AppKit
import XCTest
@testable import Pastrix

@MainActor
final class SharingServiceTests: XCTestCase {
    func testTextAndLinkUseNativeShareObjects() throws {
        try withTemporaryDirectory { directory in
            let text = makeClip(kind: .text, representations: [representation(.string, "hello")])
            let link = makeClip(kind: .link, representations: [representation(.URL, "https://example.com/path")])

            let items = try SharingService.shareItems(for: [text, link], directory: directory)

            XCTAssertEqual(items.count, 2)
            XCTAssertEqual(items[0] as? NSString, "hello")
            XCTAssertEqual((items[1] as? NSURL)?.absoluteString, "https://example.com/path")
        }
    }

    func testAllOriginalFilesAndPayloadItemBoundariesArePreserved() throws {
        try withTemporaryDirectory { directory in
            let first = directory.appendingPathComponent("first.txt")
            let second = directory.appendingPathComponent("second.txt")
            try Data("one".utf8).write(to: first)
            try Data("two".utf8).write(to: second)
            let clip = makeClip(kind: .file, items: [
                [representation(.fileURL, first.absoluteString)],
                [representation(.fileURL, second.absoluteString)],
            ])

            let items = try SharingService.shareItems(for: [clip], directory: directory.appendingPathComponent("exports"))

            XCTAssertEqual(items.count, 2)
            XCTAssertEqual((items[0] as? NSURL)?.path, first.path)
            XCTAssertEqual((items[1] as? NSURL)?.path, second.path)
        }
    }

    func testPNGAndPDFAreExportedWithOriginalBytesAndRestrictedPermissions() throws {
        try withTemporaryDirectory { directory in
            let png = Data([0x89, 0x50, 0x4e, 0x47])
            let pdf = Data("%PDF-1.7 fixture".utf8)
            let clips = [
                makeClip(kind: .image, representations: [ClipRepresentation(type: NSPasteboard.PasteboardType.png.rawValue, data: png)]),
                makeClip(kind: .image, representations: [ClipRepresentation(type: NSPasteboard.PasteboardType.pdf.rawValue, data: pdf)]),
            ]

            let items = try SharingService.shareItems(for: clips, directory: directory)
            let urls = try items.map { try XCTUnwrap($0 as? NSURL) as URL }

            XCTAssertEqual(urls.map(\.pathExtension), ["png", "pdf"])
            XCTAssertEqual(try Data(contentsOf: urls[0]), png)
            XCTAssertEqual(try Data(contentsOf: urls[1]), pdf)
            XCTAssertEqual(permissions(of: directory), 0o700)
            XCTAssertEqual(permissions(of: urls[0]), 0o600)
            XCTAssertEqual(permissions(of: urls[1]), 0o600)
        }
    }

    func testMissingOriginalFileFailsBeforeReturningShareItems() throws {
        try withTemporaryDirectory { directory in
            let missing = directory.appendingPathComponent("missing.txt")
            let clip = makeClip(kind: .file, representations: [representation(.fileURL, missing.absoluteString)])

            XCTAssertThrowsError(try SharingService.shareItems(for: [clip], directory: directory.appendingPathComponent("exports"))) { error in
                guard case SharingService.SharingError.missingFile(let path) = error else {
                    return XCTFail("Expected missingFile, got \(error)")
                }
                XCTAssertEqual(path, missing.path)
            }
        }
    }

    func testEverySelectedClipAndEveryPayloadItemIsIncluded() throws {
        try withTemporaryDirectory { directory in
            let first = makeClip(kind: .text, items: [
                [representation(.string, "one")],
                [representation(.string, "two")],
            ])
            let second = makeClip(kind: .text, representations: [representation(.string, "three")])

            let items = try SharingService.shareItems(for: [first, second], directory: directory)

            XCTAssertEqual(items.count, 3)
            XCTAssertEqual(items.compactMap { $0 as? NSString }, ["one", "two", "three"])
        }
    }

    func testUnsupportedRepresentationFailsWithoutPartialExports() throws {
        try withTemporaryDirectory { directory in
            let exportDirectory = directory.appendingPathComponent("exports")
            let png = makeClip(kind: .image, representations: [
                ClipRepresentation(type: NSPasteboard.PasteboardType.png.rawValue, data: Data([1, 2, 3]))
            ])
            let unsupported = makeClip(kind: .image, representations: [
                ClipRepresentation(type: "com.example.unsupported", data: Data([4, 5, 6]))
            ])

            XCTAssertThrowsError(try SharingService.shareItems(for: [png, unsupported], directory: exportDirectory))
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: exportDirectory.path), [])
        }
    }

    private func makeClip(
        kind: ClipKind,
        items: [[ClipRepresentation]]
    ) -> Clip {
        Clip(
            kind: kind,
            title: "Fixture",
            text: "",
            sourceApp: "Tests",
            sourceBundleID: "com.example.tests",
            fingerprint: UUID().uuidString,
            payload: ClipPayload(items: items)
        )
    }

    private func makeClip(
        kind: ClipKind,
        representations: [ClipRepresentation]
    ) -> Clip {
        makeClip(kind: kind, items: [representations])
    }

    private func representation(_ type: NSPasteboard.PasteboardType, _ value: String) -> ClipRepresentation {
        ClipRepresentation(type: type.rawValue, data: Data(value.utf8))
    }

    private func permissions(of url: URL) -> Int {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return attributes?[.posixPermissions] as? Int ?? -1
    }

    private func withTemporaryDirectory(_ body: (URL) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("Pastrix-SharingTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try body(directory)
    }
}

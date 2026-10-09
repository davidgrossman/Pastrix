import AppKit
import XCTest
@testable import Pastrix

@MainActor
final class ClipboardServiceTests: XCTestCase {
    func testCaptureClassifiesTextLinkFileImageAndColor() throws {
        let text = try capture(item(string: "First line\nSecond line"))
        XCTAssertEqual(text.kind, .text)
        XCTAssertEqual(text.title, "First line")
        XCTAssertEqual(text.text, "First line\nSecond line")

        let link = try capture(item(string: "https://example.com/path?q=1"))
        XCTAssertEqual(link.kind, .link)
        XCTAssertEqual(link.title, "example.com")

        let fileURL = URL(fileURLWithPath: "/tmp/Quarterly Report.pdf")
        let fileItem = NSPasteboardItem()
        XCTAssertTrue(fileItem.setString(fileURL.absoluteString, forType: .fileURL))
        let file = try capture(fileItem)
        XCTAssertEqual(file.kind, .file)
        XCTAssertEqual(file.title, "Quarterly Report.pdf")
        XCTAssertEqual(file.text, fileURL.absoluteString)

        let imageItem = NSPasteboardItem()
        XCTAssertTrue(imageItem.setData(Data([0x89, 0x50, 0x4e, 0x47]), forType: .png))
        let image = try capture(imageItem)
        XCTAssertEqual(image.kind, .image)
        XCTAssertEqual(image.title, "Image")

        let color = try capture(item(string: "  #a1b2c3dd\n"))
        XCTAssertEqual(color.kind, .color)
        XCTAssertEqual(color.title, "#A1B2C3DD")
    }

    func testCapturePreservesAllowedRichRepresentationsExactly() throws {
        let stringData = Data("Rich text".utf8)
        let htmlData = Data("<strong>Rich text</strong>".utf8)
        let rtfData = Data("{\\rtf1\\ansi Rich text}".utf8)
        let item = NSPasteboardItem()
        XCTAssertTrue(item.setData(rtfData, forType: .rtf))
        XCTAssertTrue(item.setData(stringData, forType: .string))
        XCTAssertTrue(item.setData(htmlData, forType: .html))

        let clip = try capture(item)

        XCTAssertEqual(clip.payload.items.count, 1)
        XCTAssertEqual(
            clip.payload.items[0],
            [
                ClipRepresentation(type: NSPasteboard.PasteboardType.html.rawValue, data: htmlData),
                ClipRepresentation(type: NSPasteboard.PasteboardType.rtf.rawValue, data: rtfData),
                ClipRepresentation(type: NSPasteboard.PasteboardType.string.rawValue, data: stringData),
            ].sorted { $0.type < $1.type }
        )
    }

    func testFingerprintIsDeterministicAcrossRepresentationInsertionOrder() throws {
        let first = NSPasteboardItem()
        XCTAssertTrue(first.setData(Data("<b>same</b>".utf8), forType: .html))
        XCTAssertTrue(first.setString("same", forType: .string))

        let second = NSPasteboardItem()
        XCTAssertTrue(second.setString("same", forType: .string))
        XCTAssertTrue(second.setData(Data("<b>same</b>".utf8), forType: .html))

        let firstClip = try capture(first, sourceApp: "First App", bundleID: "com.example.first")
        let secondClip = try capture(second, sourceApp: "Second App", bundleID: "com.example.second")

        XCTAssertEqual(firstClip.payload, secondClip.payload)
        XCTAssertEqual(firstClip.fingerprint, secondClip.fingerprint)
        XCTAssertEqual(firstClip.fingerprint.count, 64)
    }

    func testCapturePreservesMultiItemOrderAndOrderAffectsFingerprint() throws {
        let first = item(string: "first")
        let second = item(string: "second")

        let forward = try XCTUnwrap(ClipboardService.capture(
            items: [first, second], sourceApp: "Tests", bundleID: "com.example.tests"
        ))
        let reversed = try XCTUnwrap(ClipboardService.capture(
            items: [second, first], sourceApp: "Tests", bundleID: "com.example.tests"
        ))

        XCTAssertEqual(forward.payload.items.map(firstString), ["first", "second"])
        XCTAssertEqual(reversed.payload.items.map(firstString), ["second", "first"])
        XCTAssertNotEqual(forward.fingerprint, reversed.fingerprint)
    }

    func testCaptureRejectsAnyItemWithASensitiveMarker() throws {
        for rawType in ClipboardService.sensitiveTypes {
            let safe = item(string: "must not be retained")
            XCTAssertTrue(safe.setData(Data([0x01]), forType: .init(rawType)))

            XCTAssertNil(try ClipboardService.capture(
                items: [safe], sourceApp: "Password Manager", bundleID: "com.example.passwords"
            ), "Expected sensitive marker \(rawType) to suppress capture")
        }

        let ordinary = item(string: "ordinary text")
        let sensitive = item(string: "secret")
        XCTAssertTrue(sensitive.setData(Data([0x01]), forType: .init("org.nspasteboard.ConcealedType")))
        XCTAssertNil(try ClipboardService.capture(
            items: [ordinary, sensitive], sourceApp: "Tests", bundleID: "com.example.tests"
        ))
    }

    func testCaptureRejectsPayloadOverSizeCap() {
        let item = NSPasteboardItem()
        XCTAssertTrue(item.setData(Data(count: ClipboardService.maxBytes + 1), forType: .png))

        XCTAssertThrowsError(try ClipboardService.capture(
            items: [item], sourceApp: "Tests", bundleID: "com.example.tests"
        )) { error in
            guard case ClipboardService.CaptureError.tooLarge = error else {
                return XCTFail("Expected tooLarge, got \(error)")
            }
        }
    }

    func testPlainWriteRoundTripsCombinedTextOnIsolatedPasteboard() throws {
        try withNamedPasteboard { pasteboard in
            let service = ClipboardService(pasteboard: pasteboard)
            let clips = [makeClip(text: "alpha"), makeClip(text: "beta")]

            XCTAssertTrue(service.write(clips, plain: true))
            let writtenItems = try XCTUnwrap(pasteboard.pasteboardItems)
            XCTAssertEqual(writtenItems.count, 1)
            XCTAssertEqual(writtenItems[0].types, [.string])
            XCTAssertEqual(writtenItems[0].string(forType: .string), "alpha\nbeta")

            let roundTripped = try XCTUnwrap(ClipboardService.capture(
                items: writtenItems, sourceApp: "Tests", bundleID: "com.example.tests"
            ))
            XCTAssertEqual(roundTripped.kind, .text)
            XCTAssertEqual(roundTripped.text, "alpha\nbeta")
        }
    }

    func testRichWriteRoundTripsRepresentationsAndItemOrderOnIsolatedPasteboard() throws {
        try withNamedPasteboard { pasteboard in
            let service = ClipboardService(pasteboard: pasteboard)
            let payload = ClipPayload(items: [
                [
                    ClipRepresentation(type: NSPasteboard.PasteboardType.string.rawValue, data: Data("first".utf8)),
                    ClipRepresentation(type: NSPasteboard.PasteboardType.html.rawValue, data: Data("<b>first</b>".utf8)),
                ],
                [
                    ClipRepresentation(type: NSPasteboard.PasteboardType.string.rawValue, data: Data("second".utf8)),
                    ClipRepresentation(type: NSPasteboard.PasteboardType.rtf.rawValue, data: Data("{\\rtf1 second}".utf8)),
                ],
            ])

            XCTAssertTrue(service.write([makeClip(text: "first", payload: payload)], plain: false))
            let writtenItems = try XCTUnwrap(pasteboard.pasteboardItems)
            XCTAssertEqual(writtenItems.count, 2)

            let roundTripped = try XCTUnwrap(ClipboardService.capture(
                items: writtenItems, sourceApp: "Tests", bundleID: "com.example.tests"
            ))
            XCTAssertEqual(roundTripped.payload.items.map(firstString), ["first", "second"])
            XCTAssertEqual(roundTripped.payload.items, payload.items.map { $0.sorted { $0.type < $1.type } })
        }
    }

    func testEmptyRichPayloadLeavesExistingPasteboardContentIntact() throws {
        try withNamedPasteboard { pasteboard in
            XCTAssertTrue(pasteboard.setString("sentinel", forType: .string))
            let changeCount = pasteboard.changeCount
            let service = ClipboardService(pasteboard: pasteboard)
            let empty = makeClip(text: "empty", payload: ClipPayload(items: []))

            XCTAssertFalse(service.write([empty], plain: false))
            XCTAssertEqual(pasteboard.changeCount, changeCount)
            XCTAssertEqual(pasteboard.string(forType: .string), "sentinel")
        }
    }

    // MARK: - Fixtures

    private func capture(
        _ item: NSPasteboardItem,
        sourceApp: String = "Tests",
        bundleID: String = "com.example.tests"
    ) throws -> Clip {
        try XCTUnwrap(ClipboardService.capture(items: [item], sourceApp: sourceApp, bundleID: bundleID))
    }

    private func item(string: String) -> NSPasteboardItem {
        let item = NSPasteboardItem()
        XCTAssertTrue(item.setString(string, forType: .string))
        return item
    }

    private func firstString(in representations: [ClipRepresentation]) -> String? {
        representations
            .first { $0.type == NSPasteboard.PasteboardType.string.rawValue }
            .flatMap { String(data: $0.data, encoding: .utf8) }
    }

    private func makeClip(text: String, payload: ClipPayload? = nil) -> Clip {
        Clip(
            kind: .text,
            title: text,
            text: text,
            sourceApp: "Tests",
            sourceBundleID: "com.example.tests",
            fingerprint: UUID().uuidString,
            payload: payload ?? ClipPayload(items: [[
                ClipRepresentation(type: NSPasteboard.PasteboardType.string.rawValue, data: Data(text.utf8))
            ]])
        )
    }

    private func withNamedPasteboard(_ body: (NSPasteboard) throws -> Void) throws {
        let pasteboard = NSPasteboard(name: .init("PastrixTests-\(UUID().uuidString)"))
        pasteboard.clearContents()
        defer {
            pasteboard.clearContents()
            pasteboard.releaseGlobally()
        }
        try body(pasteboard)
    }
}

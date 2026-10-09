import AppKit
import XCTest
@testable import Pastrix

final class QueueSessionTests: XCTestCase {
    func testOnlyPlainCommandVIsInterceptedAndSyntheticPastePasses() {
        XCTAssertTrue(QueuePasteMonitor.isQueuePaste(keyCode: 9, flags: .maskCommand, tag: 0))
        for flags: CGEventFlags in [.maskShift, .maskAlternate, .maskControl] {
            XCTAssertFalse(QueuePasteMonitor.isQueuePaste(keyCode: 9, flags: [.maskCommand, flags], tag: 0))
        }
        XCTAssertFalse(QueuePasteMonitor.isQueuePaste(keyCode: 9, flags: [], tag: 0))
        XCTAssertFalse(QueuePasteMonitor.isQueuePaste(keyCode: 8, flags: .maskCommand, tag: 0))
        XCTAssertFalse(QueuePasteMonitor.isQueuePaste(keyCode: 9, flags: .maskCommand, tag: 0x50535452))
    }
    @MainActor func testSessionCapturesCanonicalClipAndEndKeepsQueue() async throws {
        let model = try AppModel(demo: true)
        try await wait { !model.recentClips.isEmpty }
        let clip = try makeClip("queue-session-\(UUID())")
        model.startQueueSession(); model.capture(clip)
        try await wait { model.queue.count == 1 }
        model.capture(clip)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(model.queue.map(\.id), [clip.id])
        model.endQueueSession()
        model.capture(try makeClip("not queued"))
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertFalse(model.isQueueSessionActive)
        XCTAssertEqual(model.queue.count, 1)
        model.pasteNextInQueue()
        try await wait { model.queue.isEmpty }
    }
    @MainActor func testEndedSessionDoesNotReceivePendingCapture() async throws {
        let model = try AppModel(demo: true)
        try await wait { !model.recentClips.isEmpty }
        model.startQueueSession()
        model.capture(try makeClip("pending-\(UUID())"))
        model.endQueueSession(); model.startQueueSession()
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertTrue(model.queue.isEmpty)
        model.endQueueSession()
    }
    @MainActor func testRecentCopiesIgnoreShelfFilters() async throws {
        let model = try AppModel(demo: true)
        try await wait { !model.recentClips.isEmpty }
        model.query = "no matching synthetic fixture"
        try await wait { model.clips.isEmpty }
        XCTAssertEqual(model.recentClips.count, 5)
    }
    @MainActor private func makeClip(_ text: String) throws -> Clip {
        let item = NSPasteboardItem(); item.setString(text, forType: .string)
        return try XCTUnwrap(ClipboardService.capture(items: [item], sourceApp: "Test", bundleID: "test"))
    }
    @MainActor private func wait(_ condition: () -> Bool) async throws {
        for _ in 0..<200 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Timed out waiting for isolated model state")
    }
}

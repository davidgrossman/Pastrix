import XCTest
@testable import Pastrix

final class PasteQueueTests: XCTestCase {
    private func clip(_ id: String) -> Clip {
        Clip(id: id, kind: .text, title: id, text: id, sourceApp: "Test", sourceBundleID: "test", fingerprint: id, payload: ClipPayload(items: [[ClipRepresentation(type: "public.utf8-plain-text", data: Data(id.utf8))]]))
    }
    func testAppendPreservesOrderAndDeduplicates() {
        var queue = PasteQueue()
        queue.append([clip("a"), clip("b")]); queue.append([clip("b"), clip("c")])
        XCTAssertEqual(queue.clips.map(\.id), ["a", "b", "c"])
    }
    func testRemoveOnlyAdvancesChosenItemAndReversePreservesContent() {
        var queue = PasteQueue(); queue.append([clip("a"), clip("b"), clip("c")])
        queue.reverse(); XCTAssertEqual(queue.clips.map(\.id), ["c", "b", "a"])
        queue.remove(id: "c"); XCTAssertEqual(queue.clips.map(\.id), ["b", "a"])
        queue.clear(); XCTAssertTrue(queue.clips.isEmpty)
    }
}

import AppKit
import XCTest
@testable import Pastrix

final class ShelfInteractionTests: XCTestCase {
    func testCommandClickTogglesWithoutDiscardingOtherSelections() {
        let first = ClipSelectionRules.selecting(
            "b",
            orderedIDs: ["a", "b", "c", "d"],
            selectedIDs: ["a", "c"],
            anchorID: "a",
            extending: true,
            range: false
        )
        XCTAssertEqual(first.selectedIDs, ["a", "b", "c"])
        XCTAssertEqual(first.anchorID, "b")

        let second = ClipSelectionRules.selecting(
            "c",
            orderedIDs: ["a", "b", "c", "d"],
            selectedIDs: first.selectedIDs,
            anchorID: first.anchorID,
            extending: true,
            range: false
        )
        XCTAssertEqual(second.selectedIDs, ["a", "b"])
        XCTAssertEqual(second.anchorID, "c")
    }

    func testShiftClickSelectsContiguousRangeFromAnchorInEitherDirection() {
        let forward = ClipSelectionRules.selecting(
            "d",
            orderedIDs: ["a", "b", "c", "d", "e"],
            selectedIDs: ["b"],
            anchorID: "b",
            extending: false,
            range: true
        )
        XCTAssertEqual(forward.selectedIDs, ["b", "c", "d"])
        XCTAssertEqual(forward.anchorID, "b")

        let backward = ClipSelectionRules.selecting(
            "a",
            orderedIDs: ["a", "b", "c", "d", "e"],
            selectedIDs: forward.selectedIDs,
            anchorID: forward.anchorID,
            extending: false,
            range: true
        )
        XCTAssertEqual(backward.selectedIDs, ["a", "b"])
        XCTAssertEqual(backward.anchorID, "b")
    }

    func testDraggingSelectedClipRetainsOrderedGroupAndDraggingUnselectedClipDoesNot() {
        let ordered = ["a", "b", "c", "d"]
        let selected: Set<String> = ["a", "c", "d"]
        XCTAssertEqual(
            ClipSelectionRules.dragIDs(startingWith: "c", orderedIDs: ordered, selectedIDs: selected),
            ["a", "c", "d"]
        )
        XCTAssertEqual(
            ClipSelectionRules.dragIDs(startingWith: "b", orderedIDs: ordered, selectedIDs: selected),
            ["b"]
        )
    }

    @MainActor
    func testRapidAssignmentsFinishInRequestOrderAndUndoRestoresIntermediateBoard() async throws {
        let model = try AppModel(demo: true)
        try await waitUntil {
            Set(model.boards.map(\.id)).isSuperset(of: ["work", "ideas"])
        }
        let id = "assignment-sequence-\(UUID().uuidString)"
        let payload = ClipPayload(items: [[
            ClipRepresentation(type: "public.utf8-plain-text", data: Data(id.utf8))
        ]])
        let clip = Clip(
            id: id,
            kind: .text,
            title: id,
            text: id,
            sourceApp: "Pastrix Tests",
            sourceBundleID: "com.example.PastrixTests",
            fingerprint: id,
            payload: payload
        )
        model.capture(clip)
        try await waitUntil { try await model.database.clip(id: id) != nil }

        model.assign(ids: [id], to: "work")
        model.assign(ids: [id], to: "ideas")
        try await waitUntil {
            try await model.database.clip(id: id)?.boardID == "ideas"
                && model.status == "Added 1 clip to Ideas · ⌘Z to undo"
        }
        XCTAssertTrue(model.canUndo)

        model.undoLastAction()
        try await waitUntil { try await model.database.clip(id: id)?.boardID == "work" }
        XCTAssertFalse(model.canUndo)
    }

    @MainActor
    func testAssignmentUndoFeedbackCountsOnlyClipsThatStillExist() async throws {
        let model = try AppModel(demo: true)
        try await waitUntil {
            Set(model.boards.map(\.id)).isSuperset(of: ["work", "ideas"])
        }
        let ids = ["undo-survivor-\(UUID().uuidString)", "undo-deleted-\(UUID().uuidString)"]
        for id in ids {
            let payload = ClipPayload(items: [[
                ClipRepresentation(type: "public.utf8-plain-text", data: Data(id.utf8))
            ]])
            model.capture(Clip(
                id: id,
                kind: .text,
                title: id,
                text: id,
                sourceApp: "Pastrix Tests",
                sourceBundleID: "com.example.PastrixTests",
                fingerprint: id,
                payload: payload
            ))
        }
        try await waitUntil {
            let first = try await model.database.clip(id: ids[0])
            let second = try await model.database.clip(id: ids[1])
            return first != nil && second != nil
        }

        model.assign(ids: ids, to: "work")
        try await waitUntil {
            let first = try await model.database.clip(id: ids[0])
            let second = try await model.database.clip(id: ids[1])
            return first?.boardID == "work" && second?.boardID == "work"
        }
        model.assign(ids: ids, to: "ideas")
        try await waitUntil {
            let first = try await model.database.clip(id: ids[0])
            let second = try await model.database.clip(id: ids[1])
            return first?.boardID == "ideas"
                && second?.boardID == "ideas"
                && model.status == "Added 2 clips to Ideas · ⌘Z to undo"
        }

        try await model.database.delete(ids: [ids[1]])
        model.undoLastAction()
        try await waitUntil {
            try await model.database.clip(id: ids[0])?.boardID == "work"
                && model.status == "Restored 1 clip to their previous pinboards"
        }
        let deleted = try await model.database.clip(id: ids[1])
        XCTAssertNil(deleted)
    }

    @MainActor
    func testMouseModifiersRemainThoseOfMouseDownUntilDelayedButtonAction() {
        let modifiers = ClipMouseModifiers()
        modifiers.record(.command)
        let releasedMouseUp = NSEvent.mouseEvent(
            with: .leftMouseUp, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: 0, context: nil, eventNumber: 1, clickCount: 1, pressure: 0
        )
        XCTAssertEqual(modifiers.consume(currentEvent: releasedMouseUp), .command)
        XCTAssertNil(modifiers.captured)
        XCTAssertEqual(modifiers.lastRecorded, .command)
        XCTAssertEqual(modifiers.consume(currentEvent: releasedMouseUp), [])
    }

    @MainActor
    func testShelfPointerSelectionKeepsViewportAndSupportsExplicitMultipleSelection() async throws {
        let model = try AppModel(demo: true)
        try await waitUntil { model.clips.count >= 4 }
        let clips = Array(model.clips.prefix(4))
        model.selectFromShelf(clips[0], modifiers: [])
        model.selectFromShelf(clips[2], modifiers: .command)
        XCTAssertEqual(model.selectedIDs, [clips[0].id, clips[2].id])
        XCTAssertNil(model.navigationTargetID, "Pointer changes must not recenter the shelf")

        model.selectingMultiple = true
        model.selectFromShelf(clips[3], modifiers: [])
        model.selectFromShelf(clips[2], modifiers: [])
        XCTAssertEqual(model.selectedIDs, [clips[0].id, clips[3].id])
        XCTAssertEqual(model.dragIDs(startingWith: clips[3]), [clips[0].id, clips[3].id])
        XCTAssertNil(model.navigationTargetID)

        model.selectingMultiple = false
        model.selectFromShelf(clips[0], modifiers: [])
        model.selectFromShelf(clips[2], modifiers: .shift)
        XCTAssertEqual(model.selectedIDs, Set(clips.prefix(3).map(\.id)))
        model.moveSelection(1)
        XCTAssertEqual(model.navigationTargetID, clips[1].id)
        let navigation = model.navigationTargetID
        model.selectFromShelf(clips[3], modifiers: [])
        XCTAssertEqual(model.navigationTargetID, navigation, "Only keyboard navigation requests scrolling")
    }

    @MainActor
    func testArrangeClipsClearsFiltersAndRetainsSelectedPinboard() async throws {
        let model = try AppModel(demo: true)
        try await waitUntil { !model.boards.isEmpty }
        model.selectedBoardID = "work"
        model.query = "synthetic filter"
        model.kindFilter = .text
        model.sortOrder = .newestFirst
        XCTAssertFalse(model.canReorderClips)
        model.beginArrangingClips()
        XCTAssertEqual(model.selectedBoardID, "work")
        XCTAssertEqual(model.query, "")
        XCTAssertNil(model.kindFilter)
        XCTAssertEqual(model.sortOrder, .manual)
        XCTAssertTrue(model.canReorderClips)
    }

    @MainActor
    private func waitUntil(_ condition: () async throws -> Bool) async throws {
        for _ in 0..<250 {
            if try await condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Timed out waiting for isolated shelf interaction state")
    }
}

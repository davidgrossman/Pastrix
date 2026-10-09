import XCTest
@testable import Pastrix

final class ItemOrderingTests: XCTestCase {
    func testExplicitInsertionAtBothEdgesAndGroupOrder() {
        let ids = ["a", "b", "c", "d"]
        XCTAssertEqual(ItemOrdering.inserting(["a"], at: "b", after: false, in: ids), ids)
        XCTAssertEqual(ItemOrdering.inserting(["a"], at: "d", after: true, in: ids), ["b", "c", "d", "a"])
        XCTAssertEqual(ItemOrdering.inserting(["d"], at: "a", after: false, in: ids), ["d", "a", "b", "c"])
        XCTAssertEqual(ItemOrdering.inserting(["b", "a"], at: "c", after: true, in: ids), ["c", "a", "b", "d"])
        XCTAssertEqual(ItemOrdering.inserting(["a", "a"], at: "c", after: true, in: ids), ids)
        XCTAssertEqual(ItemOrdering.inserting(["a", "b"], at: "b", after: true, in: ids), ids)
    }
    func testDragCanReachBothEndsAndAdjacentRightTarget() {
        XCTAssertEqual(ItemOrdering.moving(["a"], to: "b", in: ["a", "b", "c"]), ["b", "a", "c"])
        XCTAssertEqual(ItemOrdering.moving(["a"], to: "c", in: ["a", "b", "c"]), ["b", "c", "a"])
        XCTAssertEqual(ItemOrdering.moving(["c"], to: "a", in: ["a", "b", "c"]), ["c", "a", "b"])
    }
    func testGroupMoveKeepsRelativeOrderAndInvalidDropIsUnchanged() {
        let ids = ["a", "b", "c", "d"]
        XCTAssertEqual(ItemOrdering.moving(["b", "a"], to: "d", in: ids), ["c", "d", "a", "b"])
        XCTAssertEqual(ItemOrdering.moving(["c", "d"], to: "a", in: ids), ["c", "d", "a", "b"])
        XCTAssertEqual(ItemOrdering.moving(["a", "b"], to: "b", in: ids), ids)
        XCTAssertEqual(ItemOrdering.moving(["missing"], to: "a", in: ids), ids)
    }
}

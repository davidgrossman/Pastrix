import XCTest
@testable import Pastrix

final class ItemOrderingTests: XCTestCase {
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

import XCTest
@testable import Pastrix

final class PinboardIconCatalogTests: XCTestCase {
    func testDefaultIconFallsBackToPinForUnknownPreference() {
        XCTAssertEqual(PinboardIconCatalog.defaultOption().symbol, "pin.fill")
        XCTAssertEqual(PinboardIconCatalog.defaultOption(preferredSymbol: "not.in.catalog").symbol, "pin.fill")
        XCTAssertEqual(PinboardIconCatalog.defaultOption(preferredSymbol: "briefcase.fill").symbol, "briefcase.fill")
    }

    func testExistingIconOutsideCatalogRemainsAvailableForSelection() {
        let sections = PinboardIconCatalog.sections(matching: "", currentSymbol: "custom.symbol")
        let current = sections.first { $0.category == .current }
        XCTAssertEqual(current?.options.map(\.symbol), ["custom.symbol"])
    }
}

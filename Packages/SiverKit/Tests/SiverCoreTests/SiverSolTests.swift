import XCTest
@testable import SiverCore

final class SiverSolTests: XCTestCase {
    func testFooterCarriesVersion() {
        XCTAssertEqual(SiverSol.footer, "SiverSol v1.0.0")
    }
}

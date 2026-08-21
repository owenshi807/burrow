import XCTest
@testable import Burrow

final class CleanScanPresentationTests: XCTestCase {
    func testEngineFailureIsAnErrorNotAZeroByteResult() {
        XCTAssertEqual(
            CleanScanFinishedPresentation.from(.failed("mo not found")),
            .failure("mo not found")
        )
    }

    func testSuccessfulScanRemainsAResult() {
        XCTAssertEqual(CleanScanFinishedPresentation.from(.done(exit: 0)), .result)
    }
}

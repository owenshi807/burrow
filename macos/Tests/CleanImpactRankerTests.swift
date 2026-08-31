import XCTest
@testable import Burrow

final class CleanImpactRankerTests: XCTestCase {
    func testRankOrder() {
        XCTAssertLessThan(CleanImpactRanker.rank(category: "App caches"), CleanImpactRanker.rank(category: "Logs"))
        XCTAssertLessThan(CleanImpactRanker.rank(category: "Logs"), CleanImpactRanker.rank(category: "User essentials"))
        XCTAssertEqual(CleanImpactRanker.rank(category: "Keychain leftovers"), 4)
        XCTAssertEqual(CleanImpactRanker.rank(category: "Browsers"), 0)
        XCTAssertEqual(CleanImpactRanker.rank(category: "Unknown scanner group"), 3)
    }

    func testSortedAscendingImpactStable() {
        let items: [(category: String, value: String)] = [
            ("User essentials", "a"), ("Caches", "b"), ("Logs", "c"), ("Caches", "d"),
        ]
        XCTAssertEqual(CleanImpactRanker.sorted(items), ["b", "d", "c", "a"])
    }
}

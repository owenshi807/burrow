import XCTest
@testable import Burrow

final class NativeStatusSourceTests: XCTestCase {
    func testSnapshotDecodesAsMoleStatus() throws {
        let json = try NativeStatusSource().statusJSON()
        let status = try JSONDecoder().decode(MoleStatus.self, from: Data(json.utf8))

        XCTAssertFalse(status.host.isEmpty)
        XCTAssertEqual(status.platform, "macOS")
        XCTAssertGreaterThan(status.hardware.totalRam.count, 0)
        XCTAssertGreaterThan(status.memory.total, 0)
        XCTAssertGreaterThanOrEqual(status.cpu.usage, 0)
        XCTAssertLessThanOrEqual(status.cpu.usage, 100)
        XCTAssertEqual(status.disks.first?.mount, "/")
    }
}

import XCTest
@testable import Spindle

/// A disc whose eject macOS refused while the Mac was locked waits to be
/// ejected on unlock, once, unless it leaves the drive first.
final class DeferredEjectsTests: XCTestCase {

    func testWaitsOnceAndEmptiesWhenTaken() {
        let ejects = DeferredEjects()
        ejects.add(.init(devicePath: "/dev/disk14", name: "Michael Clayton"))
        ejects.add(.init(devicePath: "/dev/disk14", name: "Michael Clayton"))
        ejects.add(.init(devicePath: "/dev/disk15", name: "Firefly"))
        XCTAssertEqual(ejects.discs.map(\.devicePath), ["/dev/disk14", "/dev/disk15"])
        XCTAssertEqual(ejects.takeAll().count, 2)
        XCTAssertTrue(ejects.discs.isEmpty)
    }

    func testDiscEjectedByHandIsForgotten() {
        let ejects = DeferredEjects()
        ejects.add(.init(devicePath: "/dev/disk14", name: "Michael Clayton"))
        ejects.remove(devicePath: "/dev/disk14")
        XCTAssertTrue(ejects.takeAll().isEmpty)
    }

    func testLockStateIsReadable() {
        // Not locked while tests run; mostly checks the session lookup doesn't crash.
        XCTAssertFalse(ScreenLock.isLocked)
    }
}

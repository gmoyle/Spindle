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

/// An eject only counts once the disc is no longer mounted: drutil exits 0
/// even when macOS refuses the unmount.
final class EjectVerificationTests: XCTestCase {

    func testMountPointFromDiskInfo() {
        XCTAssertTrue(MainViewController.isMounted(diskInfo: ["MountPoint": "/Volumes/OCEANS_ELEVEN_2001"]))
        XCTAssertFalse(MainViewController.isMounted(diskInfo: ["MountPoint": ""]))
        XCTAssertFalse(MainViewController.isMounted(diskInfo: ["DeviceIdentifier": "disk13"]))
        XCTAssertFalse(MainViewController.isMounted(diskInfo: nil))
    }

    func testMountPointPaths() throws {
        XCTAssertTrue(MainViewController.discIsMounted("/"))   // a volume's root
        let folder = NSTemporaryDirectory().appending("not-a-volume-\(UUID().uuidString)")
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: folder) }
        XCTAssertFalse(MainViewController.discIsMounted(folder))
        XCTAssertFalse(MainViewController.discIsMounted("/Volumes/NO_SUCH_DISC_\(UUID().uuidString)"))
        XCTAssertFalse(MainViewController.discIsMounted("/dev/disk999"))
    }
}

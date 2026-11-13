import XCTest
@testable import Spindle

/// A disc macOS renames while it's in the drive ("Audio CD" → its album).
final class RenamedDiscTests: XCTestCase {

    func testEarlierNamesOfTheSameDevice() {
        let mounts = ["/Volumes/Audio CD": "/dev/disk13", "/Volumes/HEAT": "/dev/disk14"]
        let stale = { (device: String, mount: String, map: [String: String]) in
            MainViewController.staleMounts(ofDevice: device, renamedTo: mount, in: map)
        }
        XCTAssertEqual(stale("/dev/disk13", "/Volumes/All The Little Lights", mounts), ["/Volumes/Audio CD"])
        XCTAssertEqual(stale("/dev/disk14", "/Volumes/HEAT", mounts), [], "the same mount isn't stale")
        XCTAssertEqual(stale("/dev/disk15", "/Volumes/X", mounts), [], "another drive's disc is left alone")
        XCTAssertEqual(stale("", "/Volumes/X", ["/Volumes/Y": ""]), [], "an unknown device matches nothing")
    }

    func testSupersededRipIsCancelledAndItsNameForgotten() {
        let controller = MainViewController()
        controller.loadView()
        let old = OpticalDrive(mountPoint: "/Volumes/Audio CD", name: "Audio CD", type: .audioCD,
                               devicePath: "/dev/disk13")
        controller.mountDevices[old.mountPoint] = old.devicePath
        controller.detectedDrives.append(old)

        controller.supersedeReads(onDevice: "/dev/disk13", renamedTo: "/Volumes/All The Little Lights")

        XCTAssertFalse(controller.detectedDrives.contains { $0.mountPoint == old.mountPoint })
        XCTAssertNil(controller.mountDevices[old.mountPoint])
        XCTAssertTrue(controller.renamedMounts.contains(old.mountPoint))
    }
}

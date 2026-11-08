import XCTest
@testable import Spindle

final class KeepAwakeTests: XCTestCase {

    func testOffByDefaultAndPersists() {
        let key = "keepMacAwakeAndUnlocked"
        let saved = UserDefaults.standard.object(forKey: key)
        defer { UserDefaults.standard.set(saved, forKey: key) }
        UserDefaults.standard.removeObject(forKey: key)
        XCTAssertFalse(SettingsManager.shared.keepMacAwake)
        SettingsManager.shared.keepMacAwake = true
        XCTAssertTrue(SettingsManager.shared.keepMacAwake)
    }

    func testTurningOnAndOffHoldsAndReleasesTheRequest() {
        let keepAwake = KeepAwake()
        XCTAssertFalse(keepAwake.isActive)
        keepAwake.setEnabled(true)
        keepAwake.setEnabled(true)   // a second "on" doesn't stack
        XCTAssertTrue(keepAwake.isActive)
        keepAwake.setEnabled(false)
        XCTAssertFalse(keepAwake.isActive)
    }
}

import Foundation

/// "Keep this Mac awake and unlocked while Spindle is open": macOS won't mount
/// or eject discs while the Mac is locked, so feeding it discs unattended only
/// works if it never locks. Holding the same no-display-sleep request a video
/// player holds stops the display sleeping, the screen saver starting and the
/// automatic lock that follows. Locking the Mac by hand still locks it.
final class KeepAwake {

    static let shared = KeepAwake()

    init() {}

    private var activity: NSObjectProtocol?
    private let lock = NSLock()

    var isActive: Bool {
        lock.lock(); defer { lock.unlock() }
        return activity != nil
    }

    func setEnabled(_ enabled: Bool) {
        lock.lock(); defer { lock.unlock() }
        if enabled, activity == nil {
            activity = ProcessInfo.processInfo.beginActivity(
                options: [.idleDisplaySleepDisabled, .idleSystemSleepDisabled],
                reason: "Waiting for discs: macOS can't mount or eject discs while the Mac is locked")
        } else if !enabled, let current = activity {
            ProcessInfo.processInfo.endActivity(current)
            activity = nil
        }
    }
}

extension SettingsManager {
    /// Off unless the user turns it on: an unattended Mac stays unlocked.
    var keepMacAwake: Bool {
        get { UserDefaults.standard.bool(forKey: "keepMacAwakeAndUnlocked") }
        set { UserDefaults.standard.set(newValue, forKey: "keepMacAwakeAndUnlocked") }
    }
}

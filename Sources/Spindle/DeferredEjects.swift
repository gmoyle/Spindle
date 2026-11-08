import AppKit
import CoreGraphics

/// macOS refuses to eject (or mount) removable media while the Mac is locked:
/// DiskArbitration dissents with "not permitted". A disc whose read finished
/// while the screen was locked would stay in the drive, and the next disc
/// couldn't go in. Spindle remembers such discs and ejects them on unlock.
final class DeferredEjects {

    struct Disc: Equatable {
        let devicePath: String
        let name: String
    }

    private var pending: [Disc] = []
    private let lock = NSLock()

    var discs: [Disc] {
        lock.lock(); defer { lock.unlock() }
        return pending
    }

    func add(_ disc: Disc) {
        lock.lock(); defer { lock.unlock() }
        if !pending.contains(where: { $0.devicePath == disc.devicePath }) { pending.append(disc) }
    }

    /// The disc left the drive some other way (ejected by hand).
    func remove(devicePath: String) {
        lock.lock(); defer { lock.unlock() }
        pending.removeAll { $0.devicePath == devicePath }
    }

    /// Everything waiting, emptied.
    func takeAll() -> [Disc] {
        lock.lock(); defer { lock.unlock() }
        defer { pending.removeAll() }
        return pending
    }
}

enum ScreenLock {
    /// Posted (distributed) when the user unlocks the Mac.
    static let unlockedNotification = Notification.Name("com.apple.screenIsUnlocked")

    /// True while the login session's screen is locked.
    static var isLocked: Bool {
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
        return session["CGSSessionScreenIsLocked"] as? Bool ?? false
    }
}

extension MainViewController {

    /// Eject a disc now, or, if macOS refuses because the Mac is locked, as
    /// soon as it's unlocked. Runs off the main thread; reports to the log.
    /// - Parameter retries: further attempts, 3 s apart, for a refusal that
    ///   isn't explained by the lock (right after an unlock DiskArbitration can
    ///   still be catching up).
    func ejectWhenPossible(devicePath: String, name: String, retries: Int = 0,
                           completion: ((Bool) -> Void)? = nil) {
        DispatchQueue.global(qos: .background).async { [weak self] in
            guard let self = self else { return }
            let ejected = self.ejectDisk(at: devicePath)
            let locked = !ejected && ScreenLock.isLocked
            DispatchQueue.main.async {
                if ejected {
                    self.appendToLog("\(name) ejected — ready for the next disc.")
                    Logger.shared.log("Ejected \(name) (\(devicePath))", level: .info, category: .general)
                } else if retries > 0 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                        self.ejectWhenPossible(devicePath: devicePath, name: name, retries: retries - 1,
                                               completion: completion)
                    }
                    return
                } else if locked {
                    self.deferredEjects.add(DeferredEjects.Disc(devicePath: devicePath, name: name))
                    self.appendToLog("macOS doesn't allow discs to be ejected while your Mac is locked. "
                                     + "\(name) will eject when you unlock it.")
                    Logger.shared.log("Eject of \(name) refused while the screen is locked; will retry on unlock",
                                      level: .warning, category: .general)
                } else {
                    self.appendToLog("Failed to eject \(name) — manual ejection may be required.")
                    Logger.shared.log("Eject of \(name) (\(devicePath)) failed", level: .error, category: .general)
                }
                completion?(ejected)
            }
        }
    }

    /// Retry the ejects macOS refused while the Mac was locked.
    func observeScreenUnlock() {
        DistributedNotificationCenter.default().addObserver(
            forName: ScreenLock.unlockedNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self = self else { return }
            let waiting = self.deferredEjects.takeAll()
            guard !waiting.isEmpty else { return }
            // Give DiskArbitration a moment to see the unlock too.
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                for disc in waiting {
                    self.appendToLog("Mac unlocked — ejecting \(disc.name)...")
                    self.ejectWhenPossible(devicePath: disc.devicePath, name: disc.name, retries: 2)
                }
            }
        }
    }
}

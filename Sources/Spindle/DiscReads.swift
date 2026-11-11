import Foundation

/// The discs being read right now, at most one per drive. With two drives, two
/// discs are read at once, and nothing may open a drive another read is using.
///
/// MakeMKV finds a disc by enumerating every drive (`info disc:9999`), which
/// opens each one. While another drive is being read that open would contend
/// with the read, so a MakeMKV read then opens its own drive by device instead
/// (`dev:`), and a read starting while MakeMKV enumerates waits for it to end.
final class DiscReads {
    static let shared = DiscReads()

    private let lock = NSLock()
    /// Source paths being read, in the order their reads began.
    private var sources: [String] = []
    /// Held while makemkvcon enumerates drives, and while they settle after it.
    private let enumeration = NSLock()

    /// A read of `source` begins. Call before anything opens its drive.
    func begin(_ source: String) {
        lock.lock(); defer { lock.unlock() }
        if !sources.contains(source) { sources.append(source) }
    }

    /// The read of `source` is over (finished, failed or cancelled).
    func end(_ source: String) {
        lock.lock(); defer { lock.unlock() }
        sources.removeAll { $0 == source }
    }

    /// A disc other than the one at `path` is being read. `path` may be the
    /// source itself or a path inside it.
    func othersReading(than path: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return sources.contains { !Self.path(path, isIn: $0) }
    }

    /// A read of a disc other than the one at `path` began before it.
    func earlierReading(than path: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard let mine = sources.firstIndex(where: { Self.path(path, isIn: $0) }) else {
            return !sources.isEmpty
        }
        return mine > 0
    }

    /// Run `body` (a drive enumeration and its settle) with no other read
    /// starting meanwhile.
    func enumerating<T>(_ body: () throws -> T) rethrows -> T {
        enumeration.lock(); defer { enumeration.unlock() }
        return try body()
    }

    /// Wait for an enumeration in progress to end before opening a drive.
    func waitForEnumeration() {
        enumeration.lock()
        enumeration.unlock()
    }

    static func path(_ path: String, isIn source: String) -> Bool {
        path == source || path.hasPrefix(source.hasSuffix("/") ? source : source + "/")
    }
}

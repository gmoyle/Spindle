import Foundation
import CryptoKit

/// Moving finished files and folders into a library so a media server, the NAS
/// indexer or a Windows client never sees part of one: a rename on the same
/// volume, otherwise a copy under a hidden name, a rename, and only then is the
/// source removed.
enum LibraryFiles {

    static func isSameVolume(_ a: String, _ b: String, fileManager: FileManager = .default) -> Bool {
        let device = { (path: String) in (try? fileManager.attributesOfItem(atPath: path))?[.systemNumber] as? Int }
        guard let x = device(a), let y = device(b) else { return false }
        return x == y
    }

    /// Hidden sibling name used while a copy is in progress.
    static func partialPath(for destination: String) -> String {
        let parent = (destination as NSString).deletingLastPathComponent
        return (parent as NSString).appendingPathComponent(
            ".\((destination as NSString).lastPathComponent).partial-\(UUID().uuidString.prefix(8))")
    }

    /// Move one file to `requested`. An existing file of that name is replaced
    /// only when `replacing`; otherwise this one gets " (2)", " (3)"…
    /// Returns where the file went.
    @discardableResult
    static func placeFile(_ source: String, at requested: String, replacing: Bool,
                          fileManager: FileManager = .default) throws -> String {
        let folder = (requested as NSString).deletingLastPathComponent
        var destination = requested
        if fileManager.fileExists(atPath: requested) {
            if replacing {
                try fileManager.removeItem(atPath: requested)
            } else {
                destination = uniqueFilePath(requested, fileManager: fileManager)
            }
        }
        if isSameVolume(source, folder, fileManager: fileManager) {
            try fileManager.moveItem(atPath: source, toPath: destination)
        } else {
            let partial = partialPath(for: destination)
            do {
                try fileManager.copyItem(atPath: source, toPath: partial)
                try fileManager.moveItem(atPath: partial, toPath: destination)
            } catch {
                try? fileManager.removeItem(atPath: partial)
                throw error
            }
            try? fileManager.removeItem(atPath: source)
        }
        return destination
    }

    /// "Name.ext" → "Name (2).ext", the first that's free.
    static func uniqueFilePath(_ path: String, fileManager: FileManager = .default) -> String {
        let base = (path as NSString).deletingPathExtension
        let ext = (path as NSString).pathExtension
        var n = 2
        var candidate: String
        repeat {
            candidate = ext.isEmpty ? "\(base) (\(n))" : "\(base) (\(n)).\(ext)"
            n += 1
        } while fileManager.fileExists(atPath: candidate)
        return candidate
    }

    /// "Folder" → "Folder (2)", the first that's free.
    static func uniqueFolderPath(_ base: String, fileManager: FileManager = .default) -> String {
        var n = 2
        while true {
            let candidate = "\(base) (\(n))"
            if !fileManager.fileExists(atPath: candidate) { return candidate }
            n += 1
        }
    }

    /// Move a whole folder to `destination` (which must not exist).
    static func moveFolder(_ source: String, to destination: String, fileManager: FileManager = .default) throws {
        let parent = (destination as NSString).deletingLastPathComponent
        if isSameVolume(source, parent, fileManager: fileManager) {
            try fileManager.moveItem(atPath: source, toPath: destination)
            return
        }
        let partial = partialPath(for: destination)
        do {
            try fileManager.copyItem(atPath: source, toPath: partial)
            try fileManager.moveItem(atPath: partial, toPath: destination)
        } catch {
            try? fileManager.removeItem(atPath: partial)
            throw error
        }
        try? fileManager.removeItem(atPath: source)
    }

    /// Put each of `source`'s files into the existing `destination` folder,
    /// replacing same-named ones (a re-rip of the same disc). Each file lands
    /// under a hidden name and is renamed into place; the old file is removed
    /// only once the new one is fully copied. Subfolders are merged the same way.
    static func replaceFiles(from source: String, into destination: String,
                             fileManager: FileManager = .default) throws {
        let names = try fileManager.contentsOfDirectory(atPath: source).filter { $0 != ".DS_Store" }
        for name in names {
            let from = (source as NSString).appendingPathComponent(name)
            let to = (destination as NSString).appendingPathComponent(name)
            var isDirectory: ObjCBool = false
            if fileManager.fileExists(atPath: from, isDirectory: &isDirectory), isDirectory.boolValue,
               fileManager.fileExists(atPath: to) {
                try replaceFiles(from: from, into: to, fileManager: fileManager)
                continue
            }
            let partial = partialPath(for: to)
            do {
                try fileManager.copyItem(atPath: from, toPath: partial)
                if fileManager.fileExists(atPath: to) {
                    // replaceItemAt isn't supported on every network filesystem;
                    // the new copy is complete, so swapping by hand is safe.
                    do {
                        _ = try fileManager.replaceItemAt(URL(fileURLWithPath: to),
                                                          withItemAt: URL(fileURLWithPath: partial))
                    } catch {
                        try fileManager.removeItem(atPath: to)
                        try fileManager.moveItem(atPath: partial, toPath: to)
                    }
                } else {
                    try fileManager.moveItem(atPath: partial, toPath: to)
                }
            } catch {
                try? fileManager.removeItem(atPath: partial)
                throw error
            }
        }
        try? fileManager.removeItem(atPath: source)
    }

    /// File a finished folder into `root` under its own name. A re-import of the
    /// same disc (the folder already there was recorded for `discIdentity`)
    /// replaces that import's files in place; anyone else's folder of the same
    /// name is left alone and this one gets " (2)". Returns the destination.
    /// - Parameter asEditions: the folder is a film's: another disc of the same
    ///   film joins the existing folder as an edition (`fileEdition`) instead
    ///   of making a " (2)" folder.
    static func fileFolder(_ folderPath: String, into root: String, discIdentity: String?,
                           asEditions: Bool = false,
                           history: RipHistoryStore = .shared,
                           fileManager: FileManager = .default) throws -> String {
        try? fileManager.createDirectory(atPath: root, withIntermediateDirectories: true)
        var folderPath = folderPath
        var destination = (root as NSString).appendingPathComponent((folderPath as NSString).lastPathComponent)
        if asEditions, !fileManager.fileExists(atPath: destination),
           let existing = existingFilmFolder(named: (folderPath as NSString).lastPathComponent, in: root,
                                             fileManager: fileManager) {
            let name = (folderPath as NSString).lastPathComponent
            let existingName = (existing as NSString).lastPathComponent
            if MovieMatch.idTag(inLibraryName: name) != nil {
                // The film's folder predates ids in names: give it this rip's id.
                try TitleRetitler.retitle(folder: existing, from: existingName, to: name,
                                          history: history, fileManager: fileManager)
            } else {
                // This rip has no id but the film's folder does: use its name.
                folderPath = try TitleRetitler.retitle(folder: folderPath, from: name, to: existingName,
                                                       history: history, fileManager: fileManager)
                destination = existing
            }
        }
        if fileManager.fileExists(atPath: destination) {
            let sameDisc = discIdentity.flatMap { history.entry(forIdentity: $0) }
                .map { standardized($0.outputLocation) == standardized(destination) } ?? false
            // A folder holding editions: even a re-rip must touch only its own.
            let hasEditions = !MovieEdition.editions(in: destination, fileManager: fileManager)
                .allSatisfy { $0.edition == nil }
            if asEditions, !sameDisc || hasEditions {
                try fileEdition(from: folderPath, into: destination, fileManager: fileManager)
                return destination
            }
            if sameDisc {
                try replaceFiles(from: folderPath, into: destination, fileManager: fileManager)
                return destination
            }
            destination = uniqueFolderPath(destination, fileManager: fileManager)
        }
        try moveFolder(folderPath, to: destination, fileManager: fileManager)
        return destination
    }

    /// The same film's folder in `root` under its title and year, where one
    /// name has an id tag and the other doesn't ("Heat (1995)" and
    /// "Heat (1995) {imdb-tt0113277}"). Two different ids are different films.
    static func existingFilmFolder(named name: String, in root: String,
                                   fileManager: FileManager = .default) -> String? {
        let plain = MovieMatch.displayName(ofLibraryName: name)
        let id = MovieMatch.idTag(inLibraryName: name)
        let names = (try? fileManager.contentsOfDirectory(atPath: root)) ?? []
        guard let match = names.first(where: { other in
            other != name && MovieMatch.displayName(ofLibraryName: other) == plain
                && (id == nil) != (MovieMatch.idTag(inLibraryName: other) == nil)
        }) else { return nil }
        let path = (root as NSString).appendingPathComponent(match)
        return TitleRetitler.isMovieFolder(path, base: match, fileManager: fileManager) ? path : nil
    }

    static func standardized(_ path: String) -> String {
        ((path as NSString).standardizingPath as NSString).resolvingSymlinksInPath
    }
}

/// Copying a file off a disc and proving the copy matches: the source is hashed
/// as it's read, then the copy is read back and hashed again.
enum VerifiedCopy {

    enum CopyError: LocalizedError {
        case unreadable(String)
        case mismatch(String)

        var errorDescription: String? {
            switch self {
            case .unreadable(let path): return "Couldn't read \(path)."
            case .mismatch(let path): return "The copy of \(path) didn't match the original."
            }
        }
    }

    static let chunkSize = 1 << 20

    /// Copy `source` to `destination` (overwriting it) and return the content's
    /// SHA-256 as hex. Tries twice before giving up; a failed attempt leaves
    /// nothing at `destination`.
    @discardableResult
    static func copy(_ source: String, to destination: String, attempts: Int = 2,
                     fileManager: FileManager = .default) throws -> String {
        var lastError: Error = CopyError.unreadable(source)
        for _ in 0..<max(attempts, 1) {
            do {
                let hash = try copyOnce(source, to: destination, fileManager: fileManager)
                guard try sha256(of: destination) == hash else { throw CopyError.mismatch(source) }
                return hash
            } catch {
                try? fileManager.removeItem(atPath: destination)
                lastError = error
            }
        }
        throw lastError
    }

    private static func copyOnce(_ source: String, to destination: String,
                                 fileManager: FileManager) throws -> String {
        guard let input = FileHandle(forReadingAtPath: source) else { throw CopyError.unreadable(source) }
        defer { try? input.close() }
        try? fileManager.removeItem(atPath: destination)
        try fileManager.createDirectory(atPath: (destination as NSString).deletingLastPathComponent,
                                        withIntermediateDirectories: true)
        guard fileManager.createFile(atPath: destination, contents: nil),
              let output = FileHandle(forWritingAtPath: destination) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: destination])
        }
        defer { try? output.close() }
        var hasher = SHA256()
        while true {
            let chunk: Data
            do {
                chunk = try input.read(upToCount: chunkSize) ?? Data()
            } catch {
                throw CopyError.unreadable(source)
            }
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
            try output.write(contentsOf: chunk)
        }
        // Keep the original's dates (photo libraries and Finder sort by them).
        if let attributes = try? fileManager.attributesOfItem(atPath: source) {
            let dates = attributes.filter { $0.key == .modificationDate || $0.key == .creationDate }
            try? output.close()
            try? fileManager.setAttributes(dates, ofItemAtPath: destination)
        }
        return hex(hasher.finalize())
    }

    static func sha256(of path: String) throws -> String {
        guard let input = FileHandle(forReadingAtPath: path) else { throw CopyError.unreadable(path) }
        defer { try? input.close() }
        var hasher = SHA256()
        while let chunk = try input.read(upToCount: chunkSize), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hex(hasher.finalize())
    }

    private static func hex(_ digest: SHA256.Digest) -> String {
        digest.map { String(format: "%02x", $0) }.joined()
    }
}

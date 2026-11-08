import Foundation

/// A film rip whose title lookup wasn't sure. The rip goes ahead under the
/// best guess; the user's pick, whenever it comes (before or after the rip
/// finishes), renames the finished folder and files.
final class TitleChoice {
    let discName: String
    let resolution: DiscTitleQuery.Resolution
    /// The queue job ripping the disc.
    var jobId: UUID?
    /// Set once the rip finished: the folder its files ended up in.
    var finishedFolder: String?
    /// What the user picked: a film's "Title (Year)", or the disc's own name.
    var chosenName: String?

    init(discName: String, resolution: DiscTitleQuery.Resolution) {
        self.discName = discName
        self.resolution = resolution
    }

    /// The name the rip was made under.
    var guessedName: String { resolution.best.displayName }
}

/// Renames a finished movie rip from one "Title (Year)" to another: the folder
/// (`Movies/Old (Year)/` → `Movies/New (Year)/`) and every file in it whose name
/// starts with the old title (`Old (Year).mkv`, `Old (Year) - Extra.mkv`).
/// Both are renames in place, so a media server never sees a partial file.
enum TitleRetitler {

    enum RetitleError: LocalizedError {
        case notAMovieFolder(String)

        var errorDescription: String? {
            switch self {
            case .notAMovieFolder(let path):
                return "\(path) isn't a movie folder named after the guessed title, so it was left as it is."
            }
        }
    }

    /// Returns the renamed folder. Updates the rip history to the new place.
    @discardableResult
    static func retitle(folder: String, from oldName: String, to newName: String,
                        history: RipHistoryStore = .shared,
                        fileManager: FileManager = .default) throws -> String {
        let oldBase = fileBase(oldName)
        let newBase = fileBase(newName)
        guard (folder as NSString).lastPathComponent == oldBase else { throw RetitleError.notAMovieFolder(folder) }
        guard oldBase != newBase else { return folder }

        for name in try fileManager.contentsOfDirectory(atPath: folder) where name.hasPrefix(oldBase) {
            let renamed = newBase + name.dropFirst(oldBase.count)
            let from = (folder as NSString).appendingPathComponent(name)
            var to = (folder as NSString).appendingPathComponent(renamed)
            if fileManager.fileExists(atPath: to) { to = LibraryFiles.uniqueFilePath(to, fileManager: fileManager) }
            try fileManager.moveItem(atPath: from, toPath: to)
        }

        var destination = ((folder as NSString).deletingLastPathComponent as NSString).appendingPathComponent(newBase)
        if fileManager.fileExists(atPath: destination) {
            destination = LibraryFiles.uniqueFolderPath(destination, fileManager: fileManager)
        }
        try fileManager.moveItem(atPath: folder, toPath: destination)
        history.updateOutputLocation(from: folder, to: destination)
        return destination
    }

    /// The movie folder a finished job's files are in, if they're all in one
    /// folder named after `name` (a TV rip, filed episode by episode, isn't).
    static func movieFolder(of files: [String], namedAfter name: String) -> String? {
        let folders = Set(files.map { ($0 as NSString).deletingLastPathComponent })
        guard folders.count == 1, let folder = folders.first,
              (folder as NSString).lastPathComponent == fileBase(name) else { return nil }
        return folder
    }

    /// "Title (Year)" as the rippers write it into folder and file names
    /// (`MediaRipper.plexBaseName`): characters Finder or Windows refuse become "-".
    static func fileBase(_ name: String) -> String {
        let invalid = CharacterSet(charactersIn: "/:*?\"<>|\\")
        return name.trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: invalid).joined(separator: "-")
            .trimmingCharacters(in: .whitespaces)
    }
}

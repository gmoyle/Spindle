import Foundation

/// A film rip whose title lookup wasn't sure. The rip goes ahead under the
/// best guess; the user's pick, whenever it comes (before or after the rip
/// finishes), renames the finished folder and files.
final class TitleChoice {
    let discName: String
    /// The name the rip is being made under (with the film's id, if any:
    /// "Title (Year) {imdb-tt…}").
    let guessedName: String
    /// Matches to offer, best first (empty for a generic label).
    let choices: [MovieMatch]
    /// The label says nothing about the film ("DVD_VIDEO").
    let labelIsGeneric: Bool
    /// The label was looked up and nothing matched ("FIGHTCLB").
    var notFound = false
    /// The queue job ripping the disc.
    var jobId: UUID?
    /// Set once the rip finished: the folder its files ended up in.
    var finishedFolder: String?
    /// What the user picked: a film's "Title (Year)", or the disc's own name.
    var chosenName: String?

    /// The guess as shown: "Title (Year)".
    var guessedDisplayName: String { MovieMatch.displayName(ofLibraryName: guessedName) }

    init(discName: String, guessedName: String, choices: [MovieMatch], labelIsGeneric: Bool = false) {
        self.discName = discName
        self.guessedName = guessedName
        self.choices = choices
        self.labelIsGeneric = labelIsGeneric
    }

    /// A name typed by hand, as the rip will be named: trimmed, and a trailing
    /// bare year put in brackets ("Something's Gotta Give 2003" →
    /// "Something's Gotta Give (2003)"). Nil when there's nothing usable.
    static func typedName(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        var words = trimmed.split(separator: " ").map(String.init)
        if words.count >= 2, let last = words.last, last.count == 4,
           let year = Int(last), (1890...2100).contains(year) {
            words[words.count - 1] = "(\(last))"
        }
        let name = TitleRetitler.fileBase(words.joined(separator: " "))
        return name.isEmpty ? nil : name
    }
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
                        pending: PendingRoutingQueue = .shared,
                        fileManager: FileManager = .default) throws -> String {
        let oldBase = fileBase(oldName)
        var newBase = fileBase(newName)
        guard (folder as NSString).lastPathComponent == oldBase else { throw RetitleError.notAMovieFolder(folder) }

        // The film is already filed under the same title and year, with or
        // without its id: settle on one name so it stays one folder.
        let parent = (folder as NSString).deletingLastPathComponent
        if let existing = LibraryFiles.existingFilmFolder(named: newBase, in: parent, fileManager: fileManager),
           existing != folder {
            let existingName = (existing as NSString).lastPathComponent
            if MovieMatch.idTag(inLibraryName: newBase) != nil {
                try retitle(folder: existing, from: existingName, to: newBase, history: history,
                            pending: pending, fileManager: fileManager)
            } else {
                newBase = existingName
            }
        }
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
            // The film is already there (another edition): join its folder.
            if isMovieFolder(destination, base: newBase, fileManager: fileManager) {
                try LibraryFiles.fileEdition(from: folder, into: destination, fileManager: fileManager)
                history.updateOutputLocation(from: folder, to: destination)
                pending.updateFolder(from: folder, to: destination)
                MovieNFO.refresh(in: destination, base: newBase, fileManager: fileManager)
                return destination
            }
            destination = LibraryFiles.uniqueFolderPath(destination, fileManager: fileManager)
        }
        try fileManager.moveItem(atPath: folder, toPath: destination)
        history.updateOutputLocation(from: folder, to: destination)
        pending.updateFolder(from: folder, to: destination)
        MovieNFO.refresh(in: destination, base: newBase, fileManager: fileManager)
        return destination
    }

    /// Name a finished rip that has no film name yet (a disc whose label said
    /// nothing, filed as "23604/Main_Movie_01-32-06.mkv"): its video files take
    /// the folder's name first, the longest becoming the film itself and the
    /// rest "Name - <their name>", then the whole rip is retitled to `newName`.
    @discardableResult
    static func nameRip(folder: String, to newName: String,
                        history: RipHistoryStore = .shared,
                        pending: PendingRoutingQueue = .shared,
                        fileManager: FileManager = .default) throws -> String {
        let oldBase = (folder as NSString).lastPathComponent
        let names = try fileManager.contentsOfDirectory(atPath: folder)
        let videos = names.filter { $0.lowercased().hasSuffix(".mkv") && !$0.hasPrefix(oldBase) }
        let size = { (name: String) -> Int64 in
            let path = (folder as NSString).appendingPathComponent(name)
            return (try? fileManager.attributesOfItem(atPath: path)[.size] as? Int64) ?? 0
        }
        let filmAlreadyNamed = names.contains { $0 == oldBase + ".mkv" }
        let main = filmAlreadyNamed ? nil : videos.max { size($0) < size($1) }
        for name in videos {
            let stem = (name as NSString).deletingPathExtension
            let renamed = name == main ? "\(oldBase).mkv" : "\(oldBase) - \(stem).mkv"
            var to = (folder as NSString).appendingPathComponent(renamed)
            if fileManager.fileExists(atPath: to) { to = LibraryFiles.uniqueFilePath(to, fileManager: fileManager) }
            try fileManager.moveItem(atPath: (folder as NSString).appendingPathComponent(name), toPath: to)
        }
        if !names.contains(where: { $0.hasPrefix(oldBase) && $0.hasSuffix(".nfo") }) {
            MovieNFO.write(in: folder, base: oldBase, fileManager: fileManager)
        }
        return try retitle(folder: folder, from: oldBase, to: newName, history: history,
                           pending: pending, fileManager: fileManager)
    }

    /// A folder holding a rip of the film `base` names (any edition).
    static func isMovieFolder(_ folder: String, base: String, fileManager: FileManager = .default) -> Bool {
        let names = (try? fileManager.contentsOfDirectory(atPath: folder)) ?? []
        return names.contains { $0.hasPrefix(base) && $0.hasSuffix(".mkv") }
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

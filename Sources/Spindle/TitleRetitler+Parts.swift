import Foundation

/// What one disc of a film holds, chosen in the “Which film is this?” window.
enum DiscPart: Equatable {
    /// One disc of a film split across several: Plex plays `Title - part1`,
    /// `Title - part2`… as one film.
    case part(Int)
    /// Extras only: its videos go in the film's `Featurettes` folder.
    case bonus

    static let featurettesFolder = "Featurettes"
    static let videoExtensions: Set<String> = ["mkv", "mp4", "m4v"]

    /// " - part2", the file-name suffix Plex stacks parts by.
    static func suffix(_ number: Int) -> String { " - part\(number)" }

    /// The part number of a film file named "Base - partN.ext", if it is one.
    static func partNumber(ofFile name: String, base: String) -> Int? {
        let stem = (name as NSString).deletingPathExtension
        guard stem.hasPrefix(base + " - part") else { return nil }
        return Int(stem.dropFirst((base + " - part").count))
    }

    /// "Disc 2" / "Bonus disc", for the log and the Discs list.
    var label: String {
        switch self {
        case .part(let number): return "Disc \(number)"
        case .bonus: return "Bonus disc"
        }
    }
}

extension TitleRetitler {

    /// Rename one disc's rip and file it as `part`: a part of a film split
    /// across discs, a bonus disc of extras, or (nil) the film itself. The rip
    /// may have its own folder, or share the film's folder with another disc
    /// (filed there as an edition); `volume` (the disc's label) picks out its
    /// files then. Everything moves by rename on one volume.
    /// Returns the film folder the rip ends up in.
    @discardableResult
    static func refile(folder: String, volume: String?, from oldName: String, to newName: String,
                       part: DiscPart?, history: RipHistoryStore = .shared,
                       pending: PendingRoutingQueue = .shared,
                       fileManager: FileManager = .default) throws -> String {
        let oldBase = fileBase(oldName)
        guard (folder as NSString).lastPathComponent == oldBase else { throw RetitleError.notAMovieFolder(folder) }
        let shared = volume.map { sharesFolder(folder, with: $0, fileManager: fileManager) } ?? false
        guard part != nil || shared else {
            return try retitle(folder: folder, from: oldName, to: newName, history: history,
                               pending: pending, fileManager: fileManager)
        }
        let parent = (folder as NSString).deletingLastPathComponent
        var newBase = fileBase(newName)
        if let existing = LibraryFiles.existingFilmFolder(named: newBase, in: parent, fileManager: fileManager) {
            newBase = (existing as NSString).lastPathComponent
        }
        let rip = try shared
            ? extractRip(of: volume ?? "", from: folder, base: oldBase, fileManager: fileManager)
            : folder
        try renameFiles(in: rip, from: oldBase, to: newBase, fileManager: fileManager)

        let destination = (parent as NSString).appendingPathComponent(newBase)
        let result: String
        if rip == folder, destination == folder {
            try applyInPlace(part, in: folder, base: newBase, fileManager: fileManager)
            result = folder
        } else if destination != rip, fileManager.fileExists(atPath: destination),
                  isMovieFolder(destination, base: newBase, fileManager: fileManager) || destination == folder {
            try merge(rip, into: destination, base: newBase, part: part, fileManager: fileManager)
            result = destination
        } else {
            let target = fileManager.fileExists(atPath: destination)
                ? LibraryFiles.uniqueFolderPath(destination, fileManager: fileManager) : destination
            try fileManager.moveItem(atPath: rip, toPath: target)
            try applyInPlace(part, in: target, base: newBase, fileManager: fileManager)
            result = target
        }
        if rip == folder, result != folder {
            history.updateOutputLocation(from: folder, to: result)
            pending.updateFolder(from: folder, to: result)
        } else if rip != folder, result != folder, let volume = volume {
            history.updateOutputLocation(volumeName: volume, from: folder, to: result)
        }
        MovieNFO.refresh(in: result, base: newBase, fileManager: fileManager)
        return result
    }

    /// Rename the files that start with `oldBase` so they start with `newBase`.
    static func renameFiles(in folder: String, from oldBase: String, to newBase: String,
                            fileManager: FileManager = .default) throws {
        guard oldBase != newBase else { return }
        for name in try fileManager.contentsOfDirectory(atPath: folder) where name.hasPrefix(oldBase) {
            let from = (folder as NSString).appendingPathComponent(name)
            var to = (folder as NSString).appendingPathComponent(newBase + name.dropFirst(oldBase.count))
            if fileManager.fileExists(atPath: to) { to = LibraryFiles.uniqueFilePath(to, fileManager: fileManager) }
            try fileManager.moveItem(atPath: from, toPath: to)
        }
    }

    // MARK: - A disc sharing the film's folder

    /// The folder holds another disc's rip besides `volume`'s.
    static func sharesFolder(_ folder: String, with volume: String, fileManager: FileManager = .default) -> Bool {
        let sidecars = ((try? fileManager.contentsOfDirectory(atPath: folder)) ?? [])
            .filter { $0.hasPrefix("disc_info") && $0.hasSuffix(".json") }
        return sidecars.count > 1 && edition(of: volume, in: folder, fileManager: fileManager) != nil
    }

    /// The edition tag `volume`'s rip carries in `folder`: "" when it's the
    /// untagged rip, nil when the disc's rip isn't there.
    static func edition(of volume: String, in folder: String, fileManager: FileManager = .default) -> String? {
        let names = (try? fileManager.contentsOfDirectory(atPath: folder)) ?? []
        for name in names where MovieEdition.sidecarNames.contains(where: { name.hasPrefix($0) })
            && name.hasSuffix(".json") {
            let path = (folder as NSString).appendingPathComponent(name)
            guard let data = fileManager.contents(atPath: path),
                  let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { continue }
            let labels = [json["volume_name"] as? String, json["movie_name"] as? String,
                          (json["source_path"] as? String).map { ($0 as NSString).lastPathComponent }]
            if labels.contains(volume) { return MovieEdition.edition(inFileName: name) ?? "" }
        }
        return nil
    }

    /// Move `volume`'s files out of the shared folder into a hidden folder
    /// inside it, without their edition tag, so they can be filed again.
    static func extractRip(of volume: String, from folder: String, base: String,
                           fileManager: FileManager = .default) throws -> String {
        guard let edition = edition(of: volume, in: folder, fileManager: fileManager) else {
            throw RetitleError.notAMovieFolder(folder)
        }
        let rip = (folder as NSString).appendingPathComponent(".spindle-refile-\(UUID().uuidString)")
        try fileManager.createDirectory(atPath: rip, withIntermediateDirectories: false)
        let tag = " {edition-\(edition)}"
        for name in try fileManager.contentsOfDirectory(atPath: folder) where !name.hasPrefix(".") {
            let untagged: String?
            if !edition.isEmpty {
                untagged = name.contains(tag) ? name.replacingOccurrences(of: tag, with: "") : nil
            } else {
                let sidecar = MovieEdition.sidecarNames.contains { "\($0).json" == name }
                untagged = sidecar || MovieEdition.isUntaggedFilmFile(name, base: base) ? name : nil
            }
            guard let newName = untagged else { continue }
            try fileManager.moveItem(atPath: (folder as NSString).appendingPathComponent(name),
                                     toPath: (rip as NSString).appendingPathComponent(newName))
        }
        return rip
    }

    // MARK: - Filing as a part or a bonus disc

    /// A rip alone in its folder: name its film as the part, or move its
    /// videos into Featurettes.
    static func applyInPlace(_ part: DiscPart?, in folder: String, base: String,
                             fileManager: FileManager = .default) throws {
        switch part {
        case .part(let number)?: try namePart(number, in: folder, base: base, fileManager: fileManager)
        case .bonus?: try moveToFeaturettes(in: folder, into: folder, base: base, fileManager: fileManager)
        case nil: break
        }
    }

    /// File the rip in `rip` into the film's folder `destination`.
    static func merge(_ rip: String, into destination: String, base: String, part: DiscPart?,
                      fileManager: FileManager = .default) throws {
        switch part {
        case nil:
            try LibraryFiles.fileEdition(from: rip, into: destination, fileManager: fileManager)
            return
        case .part(let number)?:
            try namePart(number, in: rip, base: base, fileManager: fileManager)
            // The film already there is another part: call it part 1.
            if number != 1 {
                for name in try fileManager.contentsOfDirectory(atPath: destination) where isMainFilm(name, base) {
                    let renamed = base + DiscPart.suffix(1) + "." + (name as NSString).pathExtension
                    try move(name, to: renamed, in: destination, fileManager: fileManager)
                }
            }
        case .bonus?:
            try moveToFeaturettes(in: rip, into: destination, base: base, fileManager: fileManager)
        }
        // One description per film: the one already there stays.
        let nfo = (rip as NSString).appendingPathComponent(base + ".nfo")
        if fileManager.fileExists(atPath: (destination as NSString).appendingPathComponent(base + ".nfo")) {
            try? fileManager.removeItem(atPath: nfo)
        }
        try LibraryFiles.mergeKeepingBoth(from: rip, into: destination, fileManager: fileManager)
        try? fileManager.removeItem(atPath: rip)
    }

    /// "Base.mkv" (or an earlier "Base - part1.mkv") → "Base - partN.mkv".
    static func namePart(_ number: Int, in folder: String, base: String,
                         fileManager: FileManager = .default) throws {
        for name in try fileManager.contentsOfDirectory(atPath: folder)
        where isMainFilm(name, base) || DiscPart.partNumber(ofFile: name, base: base) != nil {
            let renamed = base + DiscPart.suffix(number) + "." + (name as NSString).pathExtension
            guard renamed != name else { continue }
            try move(name, to: renamed, in: folder, fileManager: fileManager)
        }
    }

    /// Every video of the rip in `folder` → `destination/Featurettes/`: the
    /// main one as "Bonus Disc.mkv", the rest by their own names
    /// ("Base - Bonus_Feature_04.mkv" → "Bonus_Feature_04.mkv"). Its
    /// description and poster go: the extras belong to the film.
    static func moveToFeaturettes(in folder: String, into destination: String, base: String,
                                  fileManager: FileManager = .default) throws {
        let extras = (destination as NSString).appendingPathComponent(DiscPart.featurettesFolder)
        for name in try fileManager.contentsOfDirectory(atPath: folder) {
            let ext = (name as NSString).pathExtension.lowercased()
            if folder != destination, name == base + ".nfo" || name == MoviePoster.fileName {
                try? fileManager.removeItem(atPath: (folder as NSString).appendingPathComponent(name))
                continue
            }
            guard DiscPart.videoExtensions.contains(ext), name.hasPrefix(base) else { continue }
            var stem = String((name as NSString).deletingPathExtension.dropFirst(base.count))
            if stem.hasPrefix(" - ") { stem = String(stem.dropFirst(3)) }
            if stem.isEmpty || DiscPart.partNumber(ofFile: name, base: base) != nil { stem = "Bonus Disc" }
            try fileManager.createDirectory(atPath: extras, withIntermediateDirectories: true)
            var to = (extras as NSString).appendingPathComponent("\(stem).\(ext)")
            if fileManager.fileExists(atPath: to) { to = LibraryFiles.uniqueFilePath(to, fileManager: fileManager) }
            try fileManager.moveItem(atPath: (folder as NSString).appendingPathComponent(name), toPath: to)
        }
    }

    /// "Base.mkv": the film itself, not an extra or a part.
    private static func isMainFilm(_ name: String, _ base: String) -> Bool {
        let ext = (name as NSString).pathExtension
        return DiscPart.videoExtensions.contains(ext.lowercased()) && name == base + "." + ext
    }

    private static func move(_ name: String, to newName: String, in folder: String,
                             fileManager: FileManager) throws {
        var to = (folder as NSString).appendingPathComponent(newName)
        if fileManager.fileExists(atPath: to) { to = LibraryFiles.uniqueFilePath(to, fileManager: fileManager) }
        try fileManager.moveItem(atPath: (folder as NSString).appendingPathComponent(name), toPath: to)
    }
}

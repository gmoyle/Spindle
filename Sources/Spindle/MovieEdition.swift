import Foundation

/// Editions of one film ("Theatrical Cut", "Director's Cut"). Discs often say
/// which they are in the label (`ARMY_OF_DARKNESS_DIRECTORS_CUT`). Each disc of
/// a film files into the same library folder, one file per edition, named the
/// way Plex groups editions: `Army of Darkness (1993) {edition-Director's Cut}.mkv`.
enum MovieEdition {

    /// Label word runs (lowercased) and the edition each names. Longer runs
    /// come first so "EXTENDED_EDITION" isn't read as just "EXTENDED".
    static let phrases: [(words: [String], name: String)] = [
        (["directors", "cut"], "Director's Cut"),
        (["director", "s", "cut"], "Director's Cut"),
        (["director", "cut"], "Director's Cut"),
        (["dir", "cut"], "Director's Cut"),
        (["theatrical", "cut"], "Theatrical Cut"),
        (["theatrical", "edition"], "Theatrical Cut"),
        (["theatrical", "version"], "Theatrical Cut"),
        (["extended", "edition"], "Extended Edition"),
        (["extended", "cut"], "Extended Cut"),
        (["extended", "version"], "Extended Edition"),
        (["unrated", "cut"], "Unrated"),
        (["unrated", "edition"], "Unrated"),
        (["ultimate", "cut"], "Ultimate Cut"),
        (["ultimate", "edition"], "Ultimate Edition"),
        (["final", "cut"], "Final Cut"),
        (["international", "cut"], "International Cut"),
        (["alternate", "cut"], "Alternate Cut"),
        (["special", "edition"], "Special Edition"),
        (["collectors", "edition"], "Collector's Edition"),
        (["anniversary", "edition"], "Anniversary Edition"),
        (["theatrical"], "Theatrical Cut"),
        (["directors"], "Director's Cut"),
        (["extended"], "Extended Edition"),
        (["unrated"], "Unrated"),
        (["uncut"], "Uncut"),
        (["redux"], "Redux"),
        (["imax"], "IMAX"),
        (["remastered"], "Remastered")
    ]

    /// Abbreviations too ambiguous to look for anywhere but the end.
    static let endAbbreviations = ["dc": "Director's Cut"]

    /// The label's words with the edition taken out, and the edition. The
    /// edition must come after at least one title word that isn't "the", so a
    /// film called "The Final Cut" stays a title.
    static func split(volumeName: String) -> (titleWords: [String], edition: String?) {
        let words = volumeName
            .components(separatedBy: CharacterSet(charactersIn: "_-. "))
            .filter { !$0.isEmpty }
        let lower = words.map { $0.lowercased() }
        for phrase in phrases {
            let count = phrase.words.count
            guard lower.count > count else { continue }
            for start in 1...(lower.count - count) where Array(lower[start..<start + count]) == phrase.words {
                let remaining = Array(words[..<start]) + Array(words[(start + count)...])
                guard remaining.contains(where: { $0.lowercased() != "the" }) else { continue }
                return (remaining, phrase.name)
            }
        }
        // Short forms, only as the label's last word: "ARMY_OF_DARKNESS_DC".
        if let last = lower.last, let name = endAbbreviations[last] {
            let remaining = Array(words.dropLast())
            if remaining.contains(where: { $0.lowercased() != "the" }) { return (remaining, name) }
        }
        return (words, nil)
    }

    static func edition(inVolumeName volumeName: String) -> String? {
        split(volumeName: volumeName).edition
    }

    // MARK: - File names

    static let sidecarNames = ["disc_info", "rip_complete"]

    /// "Army of Darkness (1993)" + "Director's Cut" →
    /// "Army of Darkness (1993) {edition-Director's Cut}".
    static func taggedBase(_ base: String, edition: String) -> String {
        "\(base) {edition-\(TitleRetitler.fileBase(edition))}"
    }

    /// The edition a file name is tagged with, if any.
    static func edition(inFileName name: String) -> String? {
        guard let start = name.range(of: " {edition-"),
              let end = name.range(of: "}", range: start.upperBound..<name.endIndex) else { return nil }
        return String(name[start.upperBound..<end.lowerBound])
    }

    /// A file of the film itself (not artwork or a sidecar), untagged:
    /// "Base.mkv" or "Base - Something.mkv".
    static func isUntaggedFilmFile(_ name: String, base: String) -> Bool {
        guard name.hasPrefix(base), edition(inFileName: name) == nil else { return false }
        let rest = name.dropFirst(base.count)
        return rest.hasPrefix(".") || rest.hasPrefix(" - ")
    }

    /// "disc_info.json" (untagged) or "disc_info {edition-X}.json".
    static func sidecarName(_ sidecar: String, edition: String?) -> String {
        guard let edition = edition else { return "\(sidecar).json" }
        return "\(sidecar) {edition-\(TitleRetitler.fileBase(edition))}.json"
    }

    /// The disc label a rip folder's sidecar records, if it has one.
    static func volumeName(inSidecar path: String, fileManager: FileManager = .default) -> String? {
        guard let data = fileManager.contents(atPath: path),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        return json["movie_name"] as? String ?? json["volume_name"] as? String
    }

    /// Each edition already in a library folder, by the disc label it came
    /// from: nil for the untagged (first, unnamed) rip.
    static func editions(in folder: String, fileManager: FileManager = .default) -> [(volume: String?, edition: String?)] {
        let names = (try? fileManager.contentsOfDirectory(atPath: folder)) ?? []
        return names.filter { $0.hasPrefix("disc_info") && $0.hasSuffix(".json") }.map { name in
            (volumeName(inSidecar: (folder as NSString).appendingPathComponent(name), fileManager: fileManager),
             edition(inFileName: name))
        }
    }

    /// The disc label of the rip in `folder` (its untagged sidecars).
    static func ripVolumeName(in folder: String, fileManager: FileManager = .default) -> String? {
        for sidecar in sidecarNames {
            let path = (folder as NSString).appendingPathComponent(sidecarName(sidecar, edition: nil))
            if let name = volumeName(inSidecar: path, fileManager: fileManager) { return name }
        }
        return nil
    }
}

extension LibraryFiles {

    /// File another disc of a film into the film's existing library folder as
    /// an edition. The new rip's files are tagged with its edition (from its
    /// label, else "Version 2", "Version 3"…). If the rip already there is
    /// untagged and its label names an edition, it is tagged too, so Plex
    /// shows both by name. A re-rip of a disc already filed as an edition
    /// replaces that edition's files only. Nothing is overwritten otherwise.
    static func fileEdition(from source: String, into destination: String,
                            fileManager: FileManager = .default) throws {
        let base = (destination as NSString).lastPathComponent
        let sourceVolume = MovieEdition.ripVolumeName(in: source, fileManager: fileManager)
        let existing = MovieEdition.editions(in: destination, fileManager: fileManager)

        // A re-rip of a disc already here: replace its edition in place.
        if let volume = sourceVolume, let match = existing.first(where: { $0.volume == volume }) {
            try tagRip(in: source, base: base, edition: match.edition, fileManager: fileManager)
            try replaceFiles(from: source, into: destination, fileManager: fileManager)
            try? fileManager.removeItem(atPath: source)
            return
        }

        // Tag the untagged rip already here, when its label names its edition.
        var taken = Set(existing.compactMap { $0.edition })
        let names = try fileManager.contentsOfDirectory(atPath: destination)
        var hasUntagged = names.contains { MovieEdition.isUntaggedFilmFile($0, base: base) }
        if hasUntagged, let volume = existing.first(where: { $0.edition == nil })?.volume,
           let edition = MovieEdition.edition(inVolumeName: volume),
           !taken.contains(TitleRetitler.fileBase(edition)) {
            try tagRip(in: destination, base: base, edition: edition, fileManager: fileManager)
            taken.insert(TitleRetitler.fileBase(edition))
            hasUntagged = false
        }

        // The new rip is always tagged, so it never collides with what's here.
        let editionsHere = taken.count + (hasUntagged ? 1 : 0)
        let edition = uniqueEdition(sourceVolume.flatMap(MovieEdition.edition(inVolumeName:)),
                                    taken: taken, count: editionsHere + 1)
        try tagRip(in: source, base: base, edition: edition, fileManager: fileManager)
        try mergeKeepingBoth(from: source, into: destination, fileManager: fileManager)
        try? fileManager.removeItem(atPath: source)
    }

    /// The edition's name, made unique among those taken ("Theatrical Cut 2");
    /// "Version N" when the label didn't name one.
    static func uniqueEdition(_ wanted: String?, taken: Set<String>, count: Int) -> String {
        var name = wanted ?? "Version \(count)"
        var n = 2
        while taken.contains(TitleRetitler.fileBase(name)) {
            name = "\(wanted ?? "Version \(count)") \(n)"
            n += 1
        }
        return name
    }

    /// Rename a rip's untagged film files and sidecars in `folder` to `edition`
    /// (nil leaves them untagged). Renames in place on the same volume.
    static func tagRip(in folder: String, base: String, edition: String?,
                       fileManager: FileManager = .default) throws {
        guard let edition = edition else { return }
        let tagged = MovieEdition.taggedBase(base, edition: edition)
        for name in try fileManager.contentsOfDirectory(atPath: folder) {
            var renamed: String?
            if MovieEdition.isUntaggedFilmFile(name, base: base) {
                renamed = tagged + name.dropFirst(base.count)
            } else if let sidecar = MovieEdition.sidecarNames.first(where: { "\($0).json" == name }) {
                renamed = MovieEdition.sidecarName(sidecar, edition: edition)
            }
            guard let newName = renamed else { continue }
            let from = (folder as NSString).appendingPathComponent(name)
            let to = (folder as NSString).appendingPathComponent(newName)
            guard !fileManager.fileExists(atPath: to) else { continue }
            try fileManager.moveItem(atPath: from, toPath: to)
        }
    }

    /// Put each of `source`'s files into `destination`, never replacing one:
    /// a name already there gets " (2)". Subfolders ("Behind The Scenes") merge.
    static func mergeKeepingBoth(from source: String, into destination: String,
                                 fileManager: FileManager = .default) throws {
        for name in try fileManager.contentsOfDirectory(atPath: source) where name != ".DS_Store" {
            let from = (source as NSString).appendingPathComponent(name)
            let to = (destination as NSString).appendingPathComponent(name)
            // One poster per film folder: the one already there stays.
            if name == MoviePoster.fileName, fileManager.fileExists(atPath: to) { continue }
            var isDirectory: ObjCBool = false
            if fileManager.fileExists(atPath: from, isDirectory: &isDirectory), isDirectory.boolValue {
                try? fileManager.createDirectory(atPath: to, withIntermediateDirectories: true)
                try mergeKeepingBoth(from: from, into: to, fileManager: fileManager)
                continue
            }
            try placeFile(from, at: to, replacing: false, fileManager: fileManager)
        }
    }
}

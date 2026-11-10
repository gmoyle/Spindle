import Foundation

/// A Kodi-style `.nfo` beside a film's file ("Title (Year) {imdb-tt…}.nfo"),
/// naming the film and its IMDb or TMDB id. Kodi, Jellyfin and Emby read it to
/// match the film exactly; Plex ignores it and matches on the id in the name.
/// It's named after the film file, so each edition in a shared folder has its
/// own and edition tagging renames it with the file.
enum MovieNFO {

    /// The nfo for a library name: "Army of Darkness (1993) {imdb-tt0106308}".
    static func contents(forLibraryName name: String) -> String {
        let info = OutputOrganizer.parse(displayName: MovieMatch.displayName(ofLibraryName: name),
                                         contentType: .movie)
        var lines = ["<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>", "<movie>",
                     "  <title>\(escaped(info.title))</title>"]
        if let year = info.year { lines.append("  <year>\(year)</year>") }
        if let tag = MovieMatch.idTag(inLibraryName: name) {
            let parts = tag.split(separator: "-", maxSplits: 1).map(String.init)
            if parts.count == 2 {
                lines.append("  <uniqueid type=\"\(parts[0])\" default=\"true\">\(escaped(parts[1]))</uniqueid>")
            }
        }
        lines.append("</movie>")
        return lines.joined(separator: "\n") + "\n"
    }

    /// Write (or rewrite) `<base>.nfo` in `folder`. A failure is only logged:
    /// the nfo is a convenience, never a reason to fail a rip.
    static func write(in folder: String, base: String, fileManager: FileManager = .default) {
        let path = (folder as NSString).appendingPathComponent("\(base).nfo")
        let data = Data(contents(forLibraryName: base).utf8)
        if !fileManager.createFile(atPath: path, contents: data) {
            Logger.shared.log("Couldn't write \(path)", level: .warning, category: .general)
        }
    }

    /// After a rename, bring each nfo in `folder` named after `base` (any
    /// edition) up to date with the name's title, year and id.
    static func refresh(in folder: String, base: String, fileManager: FileManager = .default) {
        let names = (try? fileManager.contentsOfDirectory(atPath: folder)) ?? []
        for name in names where name.hasPrefix(base) && name.hasSuffix(".nfo") {
            let path = (folder as NSString).appendingPathComponent(name)
            fileManager.createFile(atPath: path, contents: Data(contents(forLibraryName: base).utf8))
        }
    }

    private static func escaped(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}

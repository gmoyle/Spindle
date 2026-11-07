import Foundation

/// One CD of an album, as a metadata provider describes it.
struct AlbumRelease: Equatable {
    struct Track: Equatable {
        let number: Int
        let title: String
        let artist: String
        var musicBrainzRecordingID: String?
    }

    let title: String
    let artist: String
    /// Release year, if known ("2004" from "2004-06-07").
    let year: String?
    /// Which CD of a multi-disc set this is (1-based), and how many there are.
    let discNumber: Int
    let discCount: Int
    let tracks: [Track]
    var musicBrainzReleaseID: String?

    var displayName: String { "\(artist) – \(title)" }

    /// Placeholder used when no provider knows the CD, so it still rips and can
    /// be renamed later. The disc ID keeps two unknown CDs apart.
    static func unknown(trackCount: Int, discID: String) -> AlbumRelease {
        AlbumRelease(title: "Unknown Album (\(discID.prefix(8)))", artist: "Unknown Artist", year: nil,
                     discNumber: 1, discCount: 1,
                     tracks: (1...max(trackCount, 1)).map {
                         Track(number: $0, title: String(format: "Track %02d", $0), artist: "Unknown Artist")
                     })
    }
}

/// Identifies an audio CD from its table of contents.
protocol AlbumMetadataProvider {
    var name: String { get }
    /// Calls back on an arbitrary queue with the album, or nil if unknown or the
    /// lookup failed.
    func lookUpAlbum(toc: AudioCDTOC, completion: @escaping (AlbumRelease?) -> Void)
    /// Front cover image URL for an album this provider returned, if it has one.
    func coverArtURL(for album: AlbumRelease) -> URL?
}

extension MetadataProviders {
    static var albums: AlbumMetadataProvider = MusicBrainzProvider()
}

/// MusicBrainz disc ID lookup (musicbrainz.org/ws/2), cover art from the Cover Art
/// Archive. No API key; MusicBrainz asks for a descriptive User-Agent and at most
/// one request a second, which one lookup per CD stays well within.
struct MusicBrainzProvider: AlbumMetadataProvider {
    let name = "MusicBrainz"
    var session: URLSession = .shared
    static let userAgent = "Spindle/2.2 ( https://github.com/gmoyle/Spindle )"

    func lookUpAlbum(toc: AudioCDTOC, completion: @escaping (AlbumRelease?) -> Void) {
        let discID = toc.musicBrainzDiscID
        // `toc` lets MusicBrainz return near matches when this exact disc ID isn't
        // in its database yet (a different pressing of the same album).
        guard let url = URL(string: "https://musicbrainz.org/ws/2/discid/\(discID)"
                            + "?toc=\(toc.musicBrainzTOCParameter)"
                            + "&inc=artist-credits+recordings&cdstubs=no&fmt=json") else {
            completion(nil)
            return
        }
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        fetch(request, retryOn503: true) { data in
            completion(data.flatMap {
                Self.parseDiscIDResponse($0, discID: discID, trackDurations: toc.trackDurations)
            })
        }
    }

    /// MusicBrainz answers 503 when requests come faster than one a second;
    /// wait and try once more.
    private func fetch(_ request: URLRequest, retryOn503: Bool, completion: @escaping (Data?) -> Void) {
        session.dataTask(with: request) { data, response, error in
            let status = (response as? HTTPURLResponse)?.statusCode
            if status == 503, retryOn503 {
                DispatchQueue.global().asyncAfter(deadline: .now() + 1.5) {
                    self.fetch(request, retryOn503: false, completion: completion)
                }
                return
            }
            completion(error == nil && status == 200 ? data : nil)
        }.resume()
    }

    func coverArtURL(for album: AlbumRelease) -> URL? {
        album.musicBrainzReleaseID.flatMap { URL(string: "https://coverartarchive.org/release/\($0)/front-500") }
    }

    // MARK: - Parsing (pure, for tests)

    /// Largest difference, in seconds, between a CD track and MusicBrainz's length
    /// for it before a near match is rejected.
    static let trackLengthTolerance = 3.0

    /// The album for this CD from a `/ws/2/discid/<id>` response. Prefers a release
    /// whose medium carries this exact disc ID, then an official release.
    ///
    /// Without an exact disc ID, MusicBrainz's answers are near matches by track
    /// layout, and an unrelated album with the same number of tracks can come back.
    /// Those are only accepted when the track count and every track's length match
    /// this CD; otherwise the CD is treated as unknown.
    static func parseDiscIDResponse(_ data: Data, discID: String, trackDurations: [Double]) -> AlbumRelease? {
        let trackCount = trackDurations.count
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let releases = json["releases"] as? [[String: Any]], !releases.isEmpty else { return nil }

        func media(_ release: [String: Any]) -> [[String: Any]] {
            release["media"] as? [[String: Any]] ?? []
        }
        func hasDisc(_ medium: [String: Any]) -> Bool {
            (medium["discs"] as? [[String: Any]] ?? []).contains { $0["id"] as? String == discID }
        }
        func lengthsMatch(_ medium: [String: Any]) -> Bool {
            let tracks = medium["tracks"] as? [[String: Any]] ?? []
            guard tracks.count == trackCount, trackCount > 0 else { return false }
            return zip(tracks, trackDurations).allSatisfy { track, seconds in
                guard let ms = track["length"] as? Double ?? (track["length"] as? Int).map(Double.init) else {
                    return false
                }
                return abs(ms / 1000 - seconds) <= trackLengthTolerance
            }
        }
        func matchingMedium(_ release: [String: Any]) -> [String: Any]? {
            media(release).first(where: hasDisc) ?? media(release).first(where: lengthsMatch)
        }

        let exact = releases.filter { media($0).contains(where: hasDisc) }
        let pool = exact.isEmpty ? releases : exact
        let ranked = pool.filter { $0["status"] as? String == "Official" } + pool
        guard let release = ranked.first(where: { matchingMedium($0) != nil }),
              let medium = matchingMedium(release),
              let title = release["title"] as? String else { return nil }

        let albumArtist = artistCredit(release["artist-credit"]) ?? "Unknown Artist"
        let tracks: [Track] = (medium["tracks"] as? [[String: Any]] ?? []).enumerated().map { index, track in
            let number = track["position"] as? Int ?? index + 1
            let recording = track["recording"] as? [String: Any]
            return Track(number: number,
                         title: track["title"] as? String ?? String(format: "Track %02d", number),
                         artist: artistCredit(track["artist-credit"]) ?? albumArtist,
                         musicBrainzRecordingID: recording?["id"] as? String)
        }
        guard !tracks.isEmpty else { return nil }
        let year = (release["date"] as? String).flatMap { $0.count >= 4 ? String($0.prefix(4)) : nil }
        return AlbumRelease(title: title, artist: albumArtist, year: year,
                            discNumber: medium["position"] as? Int ?? 1,
                            discCount: max(media(release).count, 1),
                            tracks: tracks, musicBrainzReleaseID: release["id"] as? String)
    }

    typealias Track = AlbumRelease.Track

    /// "Artist A feat. Artist B" from an artist-credit array.
    static func artistCredit(_ value: Any?) -> String? {
        guard let credits = value as? [[String: Any]], !credits.isEmpty else { return nil }
        let text = credits.map { ($0["name"] as? String ?? "") + ($0["joinphrase"] as? String ?? "") }.joined()
        return text.isEmpty ? nil : text
    }
}

/// Where a ripped track goes in the Music library, in the layout Plex, Jellyfin
/// and Emby read: `Artist/Album (Year)/01 - Title.flac`, with `Disc N/` folders
/// for a multi-disc set.
enum MusicLibraryNaming {

    static func albumFolder(for album: AlbumRelease, in root: String) -> String {
        let albumName = album.year.map { "\(album.title) (\($0))" } ?? album.title
        return (root as NSString)
            .appendingPathComponent(safe(album.artist))
            .appending("/\(safe(albumName))")
    }

    /// Folder the tracks of this CD go in: the album folder, or `Disc N` inside it.
    static func discFolder(for album: AlbumRelease, in root: String) -> String {
        let folder = albumFolder(for: album, in: root)
        return album.discCount > 1 ? folder.appending("/Disc \(album.discNumber)") : folder
    }

    static func trackFileName(_ track: AlbumRelease.Track, of album: AlbumRelease) -> String {
        let artist = track.artist != album.artist ? "\(track.artist) - " : ""
        return safe(String(format: "%02d - ", track.number) + artist + track.title) + ".flac"
    }

    /// File-name safe on macOS, SMB shares and Windows: no path separators or
    /// characters Windows rejects, no trailing dots or spaces.
    static func safe(_ name: String) -> String {
        let banned = CharacterSet(charactersIn: "/\\:*?\"<>|").union(.controlCharacters)
        var cleaned = String(name.unicodeScalars.map { banned.contains($0) ? "_" : Character($0) })
        while cleaned.hasSuffix(".") || cleaned.hasSuffix(" ") { cleaned.removeLast() }
        cleaned = cleaned.trimmingCharacters(in: .whitespaces)
        return cleaned.isEmpty ? "_" : cleaned
    }
}

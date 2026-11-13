import Foundation

/// Music CDs. macOS mounts an audio CD with one AIFF file per track (cddafs reads
/// the audio as it's copied), so phase 1 copies each track to local staging and
/// the disc can eject; phase 2 encodes each to FLAC, tagged, with the cover
/// embedded, straight into `Music/Artist/Album (Year)/`.
extension MediaRipper {

    enum AudioCDError: LocalizedError {
        case noTableOfContents
        case noTracks

        var errorDescription: String? {
            switch self {
            case .noTableOfContents: return "Couldn't read this CD's track list (.TOC.plist)."
            case .noTracks: return "No audio tracks were found on this CD."
            }
        }
    }

    func performAudioCDRipping(cdPath: String, configuration: RippingConfiguration) throws {
        guard let toc = AudioCDTOC.read(fromVolumeAt: cdPath) else { throw AudioCDError.noTableOfContents }
        let trackFiles = Self.audioTrackFiles(inVolumeAt: cdPath)
        guard !trackFiles.isEmpty else { throw AudioCDError.noTracks }

        let discID = toc.musicBrainzDiscID
        let album = configuration.album
            ?? Self.lookUpAlbumSynchronously(toc: toc)
            ?? AlbumRelease.unknown(trackCount: trackFiles.count, discID: discID)
        Logger.shared.log("Audio CD \(discID): \(album.displayName), \(trackFiles.count) tracks",
                          level: .info, category: .general)
        delegate?.mediaRipperDidUpdateStatus("Ripping \(album.displayName)")

        let ffmpeg = try getFFmpegPath()
        let discFolder = MusicLibraryNaming.discFolder(for: album, in: configuration.outputDirectory)
        try FileManager.default.createDirectory(atPath: discFolder, withIntermediateDirectories: true)

        // Inside this rip's own folder: two rips of one CD (a disc macOS renamed
        // mid-read looks like a second disc) mustn't share, or one's cleanup
        // deletes the other's tracks.
        let staging = URL(fileURLWithPath: stagingFolder)
            .appendingPathComponent("cd-\(MusicLibraryNaming.safe(discID))", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)

        let cover = downloadCover(for: album, into: staging)
        if let cover = cover {
            Self.placeFile(cover, at: (MusicLibraryNaming.albumFolder(for: album, in: configuration.outputDirectory)
                                       as NSString).appendingPathComponent("cover.jpg"))
        }

        let durations = toc.trackDurations
        for (index, file) in trackFiles.enumerated() {
            if shouldCancel { throw MediaRipperError.cancelled }
            delegate?.mediaRipperDidUpdateStatus("Reading track \(file.number) of \(trackFiles.count)...")
            delegate?.mediaRipperDidUpdateProgress(Double(index) / Double(trackFiles.count),
                                                   currentItem: nil, totalItems: trackFiles.count)

            let source = staging.appendingPathComponent(String(format: "%02d.aiff", file.number))
            try FileManager.default.copyItem(atPath: file.path, toPath: source.path)

            let track = album.tracks.first { $0.number == file.number }
                ?? AlbumRelease.Track(number: file.number, title: String(format: "Track %02d", file.number),
                                      artist: album.artist)
            let output = (discFolder as NSString)
                .appendingPathComponent(MusicLibraryNaming.trackFileName(track, of: album))
            let encoded = staging.appendingPathComponent(String(format: "%02d.flac", file.number))
            let duration = file.number - toc.firstTrack < durations.count && file.number >= toc.firstTrack
                ? durations[file.number - toc.firstTrack] : 0
            pendingEncodes.append(PendingEncode(
                ffmpegPath: ffmpeg,
                arguments: Self.flacEncodeArguments(input: source.path, cover: cover?.path,
                                                    output: encoded.path, track: track, album: album),
                sourcePath: source.path, outputPath: output, stagingPath: encoded.path,
                titleNumber: file.number, mediaItem: .audioTrack(duration: duration),
                itemIndex: index, totalItems: trackFiles.count))
        }
        delegate?.mediaRipperDidUpdateProgress(1, currentItem: nil, totalItems: trackFiles.count)
    }

    // MARK: - Pieces (static and pure where possible, for tests)

    /// The CD's AIFF track files ("1 Audio Track.aiff"), by track number.
    static func audioTrackFiles(inVolumeAt path: String,
                                fileManager: FileManager = .default) -> [(number: Int, path: String)] {
        let names = (try? fileManager.contentsOfDirectory(atPath: path)) ?? []
        return names.compactMap { name -> (Int, String)? in
            let ext = (name as NSString).pathExtension.lowercased()
            guard ext == "aiff" || ext == "aif",
                  let number = Int(name.prefix { $0.isNumber }) else { return nil }
            return (number, (path as NSString).appendingPathComponent(name))
        }.sorted { $0.0 < $1.0 }.map { (number: $0.0, path: $0.1) }
    }

    /// ffmpeg arguments for one FLAC track with tags and, if there is one, the
    /// cover as an embedded picture.
    static func flacEncodeArguments(input: String, cover: String?, output: String,
                                    track: AlbumRelease.Track, album: AlbumRelease) -> [String] {
        var args = ["-hide_banner", "-y", "-i", input]
        if let cover = cover {
            args += ["-i", cover, "-map", "0:a", "-map", "1:v", "-c:v", "copy",
                     "-disposition:v", "attached_pic",
                     "-metadata:s:v", "title=Album cover", "-metadata:s:v", "comment=Cover (front)"]
        } else {
            args += ["-map", "0:a"]
        }
        args += ["-c:a", "flac", "-compression_level", "8"]

        var tags: [(String, String)] = [
            ("TITLE", track.title), ("ARTIST", track.artist), ("ALBUM", album.title),
            ("ALBUMARTIST", album.artist), ("TRACKNUMBER", String(track.number)),
            ("TRACKTOTAL", String(album.tracks.count)),
            ("DISCNUMBER", String(album.discNumber)), ("DISCTOTAL", String(album.discCount))
        ]
        if let year = album.year { tags.append(("DATE", year)) }
        if let id = album.musicBrainzReleaseID { tags.append(("MUSICBRAINZ_ALBUMID", id)) }
        if let id = track.musicBrainzRecordingID { tags.append(("MUSICBRAINZ_TRACKID", id)) }
        for (key, value) in tags { args += ["-metadata", "\(key)=\(value)"] }
        return args + ["-f", "flac", output]
    }

    /// Look the CD up while the disc is being read (the main window normally did
    /// this already, before queueing). Waits up to 25 seconds.
    static func lookUpAlbumSynchronously(toc: AudioCDTOC) -> AlbumRelease? {
        let done = DispatchSemaphore(value: 0)
        var album: AlbumRelease?
        MetadataProviders.albums.lookUpAlbum(toc: toc) { album = $0; done.signal() }
        _ = done.wait(timeout: .now() + 25)
        return album
    }

    /// Download the album's front cover into `folder`; nil if there isn't one.
    private func downloadCover(for album: AlbumRelease, into folder: URL) -> URL? {
        guard let url = MetadataProviders.albums.coverArtURL(for: album) else { return nil }
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.setValue(MusicBrainzProvider.userAgent, forHTTPHeaderField: "User-Agent")
        let done = DispatchSemaphore(value: 0)
        var image: Data?
        URLSession.shared.dataTask(with: request) { data, response, _ in
            if (response as? HTTPURLResponse)?.statusCode == 200, let data = data, data.count > 1000 {
                image = data
            }
            done.signal()
        }.resume()
        _ = done.wait(timeout: .now() + 25)
        guard let data = image else { return nil }
        let file = folder.appendingPathComponent("cover.jpg")
        return (try? data.write(to: file)) != nil ? file : nil
    }

    /// Copy a small file into the library under a hidden name, then rename it, so
    /// a media server never reads half of it.
    static func placeFile(_ source: URL, at destination: String) {
        let fm = FileManager.default
        let partial = ((destination as NSString).deletingLastPathComponent as NSString)
            .appendingPathComponent(".\((destination as NSString).lastPathComponent).partial")
        try? fm.removeItem(atPath: partial)
        guard (try? fm.copyItem(atPath: source.path, toPath: partial)) != nil else { return }
        try? fm.removeItem(atPath: destination)
        if (try? fm.moveItem(atPath: partial, toPath: destination)) == nil { try? fm.removeItem(atPath: partial) }
    }
}

import Foundation

extension MainViewController {

    /// Looks up an audio CD on MusicBrainz from its track layout. Calls back on
    /// the main thread with the album, or nil if the CD isn't known.
    func lookupAlbum(forCDAt mountPoint: String, completion: @escaping (AlbumRelease?) -> Void) {
        guard let toc = AudioCDTOC.read(fromVolumeAt: mountPoint) else {
            appendToLog("Couldn't read the CD's track list.")
            DispatchQueue.main.async { completion(nil) }
            return
        }
        let provider = MetadataProviders.albums
        appendToLog("Looking up CD (\(toc.trackCount) tracks) on \(provider.name)...")
        provider.lookUpAlbum(toc: toc) { album in
            DispatchQueue.main.async { completion(album) }
        }
    }

    /// The rip settings for a disc of this kind, from Settings and the main
    /// window. Music, photo, data and home-video discs go straight into their
    /// library; other video discs go to the output folder and are routed to
    /// Movies or TV Shows afterwards.
    func ripConfiguration(for mediaType: MediaRipper.MediaType,
                          mountPoint: String? = nil) -> MediaRipper.RippingConfiguration {
        let homeVideo = homeVideoInfo(for: mediaType, mountPoint: mountPoint)
        return MediaRipper.RippingConfiguration(
            outputDirectory: outputDirectory(for: mediaType, homeVideo: homeVideo),
            selectedTitles: [], // Rip all titles
            videoCodec: settingsManager.videoCodec == "h265" ? .h265 : .h264,
            audioCodec: settingsManager.audioCodec == "ac3" ? .ac3 : .aac,
            quality: {
                switch settingsManager.quality {
                case "low": return .low
                case "medium": return .medium
                case "high": return .high
                default: return .medium
                }
            }(),
            includeSubtitles: true,
            includeChapters: true,
            mediaType: mediaType,
            autoDeinterlace: settingsManager.autoDeinterlace,
            plexName: mediaType.isVideo && homeVideo == nil ? libraryNameForRip : nil,
            hardwareAcceleration: settingsManager.hardwareAcceleration,
            ripBonusFeatures: settingsManager.ripBonusFeatures,
            album: mediaType == .audioCD ? resolvedAlbum : nil,
            photoDestination: mediaType == .photoDisc ? settingsManager.photoDestination : nil,
            homeVideo: homeVideo
        )
    }
}

extension MainViewController {
    /// The name a video rip is filed under: the looked-up film with its id
    /// ("Title (Year) {imdb-tt…}") when that's still the disc's title, else the
    /// title as it stands (typed by hand, a placeholder, or the label).
    var libraryNameForRip: String? {
        guard let title = resolvedDiscTitle else { return nil }
        if let library = resolvedLibraryName, MovieMatch.displayName(ofLibraryName: library) == title {
            return library
        }
        return title
    }
}

import Foundation

extension MainViewController {

    /// Looks up the movie on a disc from its volume label, trying each search
    /// term from `DiscTitleQuery` in turn. Calls back on the main thread with
    /// "Title (Year)", or nil if nothing was found.
    func lookupDiscTitle(volumeName: String, completion: @escaping (String?) -> Void) {
        tryLookup(candidates: DiscTitleQuery.candidates(fromVolumeName: volumeName),
                  provider: MetadataProviders.movies, completion: completion)
    }

    private func tryLookup(candidates: [String], provider: MovieMetadataProvider,
                           completion: @escaping (String?) -> Void) {
        guard let query = candidates.first else {
            DispatchQueue.main.async { completion(nil) }
            return
        }
        appendToLog("Looking up '\(query)' on \(provider.name)...")
        provider.searchMovies(query: query) { [weak self] matches in
            if let match = DiscTitleQuery.bestMatch(for: query, in: matches) {
                DispatchQueue.main.async { completion(match.displayName) }
            } else {
                self?.tryLookup(candidates: Array(candidates.dropFirst()), provider: provider,
                                completion: completion)
            }
        }
    }
}

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
            plexName: mediaType.isVideo && homeVideo == nil ? resolvedDiscTitle : nil,
            hardwareAcceleration: settingsManager.hardwareAcceleration,
            ripBonusFeatures: settingsManager.ripBonusFeatures,
            album: mediaType == .audioCD ? resolvedAlbum : nil,
            photoDestination: mediaType == .photoDisc ? settingsManager.photoDestination : nil,
            homeVideo: homeVideo
        )
    }
}

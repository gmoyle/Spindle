import Foundation

/// Remembers, per show, which series it is and which episodes each disc held,
/// so disc 2 continues where disc 1 ended and every disc of a show files under
/// the same series. Stored as JSON in Application Support.
final class TVSeriesMemory {

    struct Show: Codable, Equatable {
        var series: SeriesMatch
        var discs: [TVEpisodePlanner.DiscRecord]
    }

    static let shared = TVSeriesMemory(fileURL: TestingUtilities.shared.isRunningInTestEnvironment
        ? FileManager.default.temporaryDirectory.appendingPathComponent("spindle-tv-series-\(UUID().uuidString).json")
        : AppIdentity.supportDirectory.appendingPathComponent("tv-series.json"))

    private let fileURL: URL
    private let lock = NSLock()
    private var shows: [String: Show]

    init(fileURL: URL) {
        self.fileURL = fileURL
        shows = (try? Data(contentsOf: fileURL)).flatMap { try? JSONDecoder().decode([String: Show].self, from: $0) }
            ?? [:]
    }

    func show(forKey key: String) -> Show? {
        lock.lock(); defer { lock.unlock() }
        return shows[key]
    }

    /// Record a filed disc, replacing an earlier record of the same disc.
    func remember(series: SeriesMatch, disc: TVEpisodePlanner.DiscRecord, forKey key: String) {
        lock.lock(); defer { lock.unlock() }
        var show = shows[key] ?? Show(series: series, discs: [])
        show.series = series
        show.discs.removeAll { old in
            if let identity = disc.identity, old.identity == identity { return true }
            return old.season == disc.season && old.disc != nil && old.disc == disc.disc && old.identity == nil
        }
        show.discs.append(disc)
        shows[key] = show
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(shows) { try? data.write(to: fileURL, options: .atomic) }
    }
}

/// Files a ripped TV disc into the TV library: finds the series and season,
/// works out which episodes the disc holds, and moves each episode to
/// `TV Shows/Show (Year)/Season NN/Show (Year) - SNNEMM - Title.mkv`. Extras go
/// to the show's `Featurettes` folder. When it can't be sure, nothing moves and
/// the reason comes back so the rip can wait for review.
enum TVLibraryFiler {

    enum Outcome: Equatable {
        case filed(summary: String, seasonFolder: String)
        case unsure(String)
    }

    /// Network lookups are synchronous here (this runs after a rip, off the main
    /// thread) and give up after this long.
    static let lookupTimeout: TimeInterval = 20

    /// `file` with its defaults, as `ContentRouter` calls it.
    static let defaultFiler: TVFiling = {
        file(folderPath: $0, discName: $1, discIdentity: $2, titles: $3, strict: $4)
    }

    static func file(folderPath: String,
                     discName: String,
                     discIdentity: String?,
                     titles: [RippedTitle],
                     strict: Bool = true,
                     settings: SettingsManager = .shared,
                     provider: TVMetadataProvider = MetadataProviders.tv,
                     memory: TVSeriesMemory = .shared,
                     history: RipHistoryStore = .shared,
                     fileManager: FileManager = .default) -> Outcome {
        let episodes = titles.filter { $0.isEpisode && fileManager.fileExists(atPath: $0.path) }
        let extras = titles.filter { !$0.isEpisode && fileManager.fileExists(atPath: $0.path) }
        guard !episodes.isEmpty else { return .unsure("No episode files were found in the rip.") }

        let root = settings.libraryRoot(.tvShows)
        guard !root.isEmpty else { return .unsure("No TV Shows folder is set.") }

        let label = TVDiscLabel(volumeName: discName)
        let remembered = memory.show(forKey: label.showKey)
        guard let series = remembered?.series ?? findSeries(label.query, provider: provider) else {
            return .unsure("No TV series called “\(label.query)” was found.")
        }

        // Season: from the label, else the season this show's last disc was in.
        let lastSeason = remembered?.discs.last?.season
        let season = label.season ?? lastSeason ?? 1
        guard let listing = fetchSeason(season, of: series, provider: provider) else {
            return .unsure("Couldn't get the episode list for \(series.displayName) season \(season).")
        }
        if strict, label.season == nil, lastSeason == nil, (listing.seasonCount ?? 1) > 1 {
            return .unsure("\(series.displayName) has \(listing.seasonCount ?? 0) seasons and the disc label "
                           + "doesn't say which one this is.")
        }

        let plan = TVEpisodePlanner.firstEpisode(
            season: season, disc: label.disc, identity: discIdentity, episodeCount: episodes.count,
            seasonEpisodeTotal: listing.episodes.map(\.number).max(),
            previous: remembered?.discs ?? [], strict: strict)
        let first: Int
        switch plan {
        case .unsure(let reason): return .unsure(reason)
        case .start(let start): first = start
        }

        let seasonFolder = TVLibraryNaming.seasonFolder(for: series, season: season, in: root)
        // A re-rip of a disc filed before replaces its episodes; anything else
        // never overwrites an episode file that's already there.
        let isReRip = discIdentity.map { identity in
            remembered?.discs.contains { $0.identity == identity } ?? false
        } ?? false
        do {
            try fileManager.createDirectory(atPath: seasonFolder, withIntermediateDirectories: true)
            for (offset, title) in episodes.enumerated() {
                let number = first + offset
                let name = TVLibraryNaming.episodeFileName(series: series, season: season, episode: number,
                                                           title: listing.episode(number)?.title)
                let destination = (seasonFolder as NSString).appendingPathComponent(name)
                try place(title.path, at: destination, replacing: isReRip, fileManager: fileManager)
            }
            if !extras.isEmpty {
                let featurettes = (TVLibraryNaming.showFolder(for: series, in: root) as NSString)
                    .appendingPathComponent("Featurettes")
                try fileManager.createDirectory(atPath: featurettes, withIntermediateDirectories: true)
                for extra in extras {
                    let name = MusicLibraryNaming.safe("\(discName) - "
                        + ((extra.path as NSString).lastPathComponent as NSString).deletingPathExtension) + ".mkv"
                    try place(extra.path, at: (featurettes as NSString).appendingPathComponent(name),
                              replacing: isReRip, fileManager: fileManager)
                }
            }
        } catch {
            return .unsure("Couldn't move the episodes into \(seasonFolder): \(error.localizedDescription)")
        }

        memory.remember(series: series,
                        disc: TVEpisodePlanner.DiscRecord(identity: discIdentity, season: season, disc: label.disc,
                                                          firstEpisode: first, episodeCount: episodes.count),
                        forKey: label.showKey)
        ContentRouter.recordFolderMove(from: folderPath, to: seasonFolder)
        history.updateOutputLocation(from: folderPath, to: seasonFolder)
        removeIfOnlyMetadata(folderPath, fileManager: fileManager)

        let last = first + episodes.count - 1
        let range = first == last ? String(format: "E%02d", first) : String(format: "E%02d–E%02d", first, last)
        return .filed(summary: "Filed \(discName) as \(series.displayName) "
                      + String(format: "S%02d", season) + range + " in \(seasonFolder)",
                      seasonFolder: seasonFolder)
    }

    // MARK: - Pieces

    private static func findSeries(_ query: String, provider: TVMetadataProvider) -> SeriesMatch? {
        let candidates = [query] + DiscTitleQuery.candidates(fromVolumeName: query).filter { $0 != query }
        for candidate in candidates {
            let matches = wait { done in provider.searchSeries(query: candidate, completion: done) } ?? []
            if let match = matches.first(where: { $0.name.caseInsensitiveCompare(candidate) == .orderedSame })
                ?? matches.first {
                return match
            }
        }
        return nil
    }

    private static func fetchSeason(_ number: Int, of series: SeriesMatch,
                                    provider: TVMetadataProvider) -> SeasonListing? {
        wait { done in provider.season(number, of: series, completion: done) }.flatMap { $0 }
    }

    private static func wait<T>(_ call: (@escaping (T) -> Void) -> Void) -> T? {
        let done = DispatchSemaphore(value: 0)
        var result: T?
        let lock = NSLock()
        call { value in lock.lock(); result = value; lock.unlock(); done.signal() }
        guard done.wait(timeout: .now() + lookupTimeout) == .success else { return nil }
        lock.lock(); defer { lock.unlock() }
        return result
    }

    /// Move a finished file into the library so a media server never sees part
    /// of it: a rename on the same volume, otherwise a copy under a hidden name,
    /// a rename, and then the source is removed. An existing file of the same
    /// name is replaced only when `replacing`; otherwise this one gets " (2)".
    static func place(_ source: String, at requested: String, replacing: Bool,
                      fileManager: FileManager = .default) throws {
        let destination = try LibraryFiles.placeFile(source, at: requested, replacing: replacing,
                                                     fileManager: fileManager)
        ContentRouter.recordFileMove(from: source, to: destination)
    }

    /// The rip folder once its videos have moved out holds only Spindle's own
    /// notes (disc_info.json); remove it then.
    private static func removeIfOnlyMetadata(_ folder: String, fileManager: FileManager) {
        let leftovers: Set<String> = ["disc_info.json", "rip_complete.json", ".DS_Store"]
        guard let names = try? fileManager.contentsOfDirectory(atPath: folder),
              names.allSatisfy(leftovers.contains) else { return }
        try? fileManager.removeItem(atPath: folder)
    }
}

import Foundation

/// One title a rip produced, in disc order, so a TV disc's files can be matched
/// to episodes after the rip.
struct RippedTitle: Codable, Equatable {
    /// Where the finished file is (before any routing).
    let path: String
    let durationSeconds: Double
    /// True for an episode; false for an extra (featurette, recap…).
    let isEpisode: Bool
}

/// What a TV disc's volume label says: the show, and often the season and disc
/// ("THE_OFFICE_S2_D3", "SEINFELD_SEASON_3_DISC_1", "FIREFLY_D1").
struct TVDiscLabel: Equatable {
    /// Search terms for the show.
    let query: String
    let season: Int?
    let disc: Int?

    /// Key for remembering a show across its discs.
    var showKey: String { query.lowercased() }

    init(query: String, season: Int?, disc: Int?) {
        self.query = query
        self.season = season
        self.disc = disc
    }

    init(volumeName: String) {
        let tokens = volumeName
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: ".", with: " ")
            .split(separator: " ").map { String($0) }
        var season: Int?
        var disc: Int?
        var words: [String] = []
        let seasonWords: Set<String> = ["SEASON", "SERIES", "S"]
        let discWords: Set<String> = ["DISC", "DISK", "D", "DVD", "BD", "VOL", "VOLUME"]

        var index = 0
        while index < tokens.count {
            let token = tokens[index]
            let upper = token.uppercased()
            let next = index + 1 < tokens.count ? Int(tokens[index + 1]) : nil
            if let (s, d) = Self.match(upper, #"^S(\d{1,2})D(\d{1,2})$"#) {
                season = s; disc = d
            } else if let s = Self.number(upper, prefixes: ["SEASON", "SERIES", "S"]) {
                season = s
            } else if let d = Self.number(upper, prefixes: ["DISC", "DISK", "D", "VOL"]) {
                disc = d
            } else if seasonWords.contains(upper), let n = next {
                season = n; index += 1
            } else if discWords.contains(upper), let n = next {
                disc = n; index += 1
            } else if !DiscTitleQuery.volumeLabelJunk.contains(upper.lowercased()) {
                words.append(token)
            }
            index += 1
        }
        let query = words.joined(separator: " ")
        self.init(query: query.isEmpty ? volumeName : query, season: season, disc: disc)
    }

    private static func match(_ text: String, _ pattern: String) -> (Int, Int)? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let found = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let a = Range(found.range(at: 1), in: text), let b = Range(found.range(at: 2), in: text),
              let first = Int(text[a]), let second = Int(text[b]) else { return nil }
        return (first, second)
    }

    /// "SEASON3", "S03", "DISC2", "D2" → the number.
    private static func number(_ text: String, prefixes: [String]) -> Int? {
        for prefix in prefixes where text.hasPrefix(prefix) {
            let rest = text.dropFirst(prefix.count)
            if !rest.isEmpty, rest.count <= 2, let value = Int(rest) { return value }
        }
        return nil
    }
}

/// Which of a TV disc's titles are episodes. A season disc holds several titles
/// of about the same length (the episodes), often a "play all" title that is
/// all of them joined, and shorter extras.
struct TVEpisodeSelection: Equatable {
    let episodes: [Int]
    let playAll: [Int]
    let extras: [Int]

    /// An extra shorter than this isn't worth ripping.
    static let minExtraSeconds: Double = 300

    /// Indices into `durationsSeconds` (disc order). Nil unless the disc looks
    /// like a TV season. A zero duration marks a title to ignore (a duplicate).
    static func select(durationsSeconds: [Double]) -> TVEpisodeSelection? {
        let classification = ContentTypeClassifier.classify(titleDurationsSeconds: durationsSeconds.map { Int($0) })
        guard classification.type == .tvShow else { return nil }

        let minutes = durationsSeconds.map { $0 / 60 }
        let band = minutes.filter {
            $0 >= ContentTypeClassifier.episodeMinMinutes && $0 <= ContentTypeClassifier.episodeMaxMinutes
        }.sorted()
        let cluster = ContentTypeClassifier.largestSimilarCluster(
            band, tolerance: ContentTypeClassifier.clusterTolerance)
        guard !cluster.isEmpty else { return nil }
        let typical = cluster[cluster.count / 2]

        // Up to 2.5× a typical episode can still be one (a double-length pilot).
        var episodes = minutes.indices.filter { minutes[$0] >= typical * 0.7 && minutes[$0] <= typical * 2.5 }
        var playAll = minutes.indices.filter { minutes[$0] > typical * 2.5 }
        // A long title as long as the other episodes together is "play all".
        for index in episodes where minutes[index] >= typical * 1.8 {
            let others = episodes.filter { $0 != index && minutes[$0] < typical * 1.8 }
            let total = others.reduce(0) { $0 + minutes[$1] }
            if others.count >= 2, abs(minutes[index] - total) <= max(total * 0.03, 2) {
                playAll.append(index)
            }
        }
        episodes.removeAll { playAll.contains($0) }
        let extras = minutes.indices.filter {
            !episodes.contains($0) && !playAll.contains($0) && durationsSeconds[$0] >= minExtraSeconds
        }
        return TVEpisodeSelection(episodes: episodes, playAll: playAll.sorted(), extras: extras)
    }
}

/// Deciding which episode a disc starts at.
enum TVEpisodePlanner {

    /// A disc already filed: its season and the episodes it held.
    struct DiscRecord: Codable, Equatable {
        var identity: String?
        var season: Int
        var disc: Int?
        var firstEpisode: Int
        var episodeCount: Int
        var nextEpisode: Int { firstEpisode + episodeCount }
    }

    enum Plan: Equatable {
        case start(Int)
        /// Not sure enough to name the files; the reason is shown to the user.
        case unsure(String)
    }

    /// - Parameters:
    ///   - previous: discs of this season already filed.
    ///   - strict: false when the user has said this is TV and wants a best guess.
    static func firstEpisode(season: Int, disc: Int?, identity: String?, episodeCount: Int,
                             seasonEpisodeTotal: Int?, previous: [DiscRecord], strict: Bool) -> Plan {
        let others = previous.filter { $0.season == season && ($0.identity == nil || $0.identity != identity) }
        let start: Int
        if let identity = identity,
           let earlier = previous.first(where: { $0.identity == identity && $0.season == season }) {
            start = earlier.firstEpisode                               // re-rip of the same disc
        } else if let disc = disc {
            if strict, others.contains(where: { $0.disc == disc }) {
                return .unsure("Disc \(disc) of season \(season) was already imported from another disc.")
            }
            if disc == 1 {
                start = 1
            } else if let before = others.first(where: { $0.disc == disc - 1 }) {
                start = before.nextEpisode
            } else if !strict {
                start = others.map(\.nextEpisode).max() ?? (disc - 1) * episodeCount + 1
            } else {
                return .unsure("This is disc \(disc) of season \(season), but disc \(disc - 1) hasn't been imported, "
                               + "so the first episode on it isn't known.")
            }
        } else {
            // No disc number: discs are assumed to be inserted in order.
            start = others.map(\.nextEpisode).max() ?? 1
        }
        if strict, let total = seasonEpisodeTotal, start + episodeCount - 1 > total {
            return .unsure("Season \(season) has \(total) episodes, but this disc would be episodes "
                           + "\(start)–\(start + episodeCount - 1).")
        }
        return .start(start)
    }
}

/// TV library layout Plex, Jellyfin and Emby read:
/// `TV Shows/Show (Year)/Season 01/Show (Year) - S01E05 - Title.mkv`.
enum TVLibraryNaming {

    static func showFolder(for series: SeriesMatch, in root: String) -> String {
        (root as NSString).appendingPathComponent(MusicLibraryNaming.safe(series.displayName))
    }

    static func seasonFolder(for series: SeriesMatch, season: Int, in root: String) -> String {
        (showFolder(for: series, in: root) as NSString).appendingPathComponent(String(format: "Season %02d", season))
    }

    static func episodeFileName(series: SeriesMatch, season: Int, episode: Int, title: String?) -> String {
        var name = "\(series.displayName) - " + String(format: "S%02dE%02d", season, episode)
        if let title = title, !title.isEmpty, title != "Episode \(episode)" { name += " - \(title)" }
        return MusicLibraryNaming.safe(name) + ".mkv"
    }
}

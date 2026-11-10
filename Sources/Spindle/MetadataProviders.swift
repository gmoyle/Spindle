import Foundation

/// A movie a metadata provider found for a disc.
struct MovieMatch: Equatable {
    let title: String
    /// As the provider gives it: "1985", or a range like "2008–2013".
    let year: String?
    /// Poster image, for the "Which film is this?" chooser.
    var posterURL: URL?
    /// "tt0106308", when the provider gives one (OMDb does).
    var imdbID: String?
    /// TMDB's movie id, when the match came from TMDB.
    var tmdbID: String?

    /// Plex-style "Title (Year)".
    var displayName: String {
        guard let year = year, !year.isEmpty else { return title }
        return "\(title) (\(year))"
    }

    /// The id Plex matches on when it's in a folder or file name:
    /// "imdb-tt0106308", else "tmdb-764".
    var libraryIDTag: String? {
        if let imdb = imdbID, imdb.hasPrefix("tt") { return "imdb-\(imdb)" }
        return tmdbID.map { "tmdb-\($0)" }
    }

    /// The name a rip of this film is filed under:
    /// "Army of Darkness (1993) {imdb-tt0106308}". With the id in the name,
    /// Plex matches exactly this film instead of searching by title.
    var libraryName: String {
        libraryIDTag.map { "\(displayName) {\($0)}" } ?? displayName
    }

    /// "Army of Darkness (1993) {imdb-tt0106308}" → "Army of Darkness (1993)":
    /// a library name without its id and edition tags, for showing.
    static func displayName(ofLibraryName name: String) -> String {
        name.replacingOccurrences(of: #"\s*\{[a-z]+-[^}]*\}"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }

    /// The id tag in a library name ("imdb-tt0106308"), if it has one.
    static func idTag(inLibraryName name: String) -> String? {
        guard let range = name.range(of: #"\{(imdb-tt\d+|tmdb-\d+)\}"#, options: .regularExpression) else {
            return nil
        }
        return String(name[range].dropFirst().dropLast())
    }
}

/// Looks up movies by title (TMDB when a key is set, else OMDb).
protocol MovieMetadataProvider {
    var name: String { get }
    /// Calls back on an arbitrary queue with the provider's matches, best first.
    /// An empty array means no match or a failed lookup.
    func searchMovies(query: String, completion: @escaping ([MovieMatch]) -> Void)
}

/// The providers the app uses. Kept in one place so a provider can be swapped
/// (or faked in tests) without touching the callers.
enum MetadataProviders {
    static var movies: MovieMetadataProvider = PreferredMovieProvider()
}

/// Turning a disc's volume label into search terms, and picking a result.
enum DiscTitleQuery {

    /// Tokens that appear in disc volume labels but are not part of the movie
    /// title (screener marks, disc numbers, format/region tags).
    static let volumeLabelJunk: Set<String> = [
        "scn", "screener", "promo", "disc", "disc1", "disc2", "d1", "d2",
        "ws", "fs", "se", "ce", "r1", "r2", "r4", "ntsc", "pal", "dvd",
        "bluray", "bd", "video", "widescreen", "fullscreen", "extended",
        "unrated", "theatrical", "special", "edition", "collectors", "anamorphic"
    ]

    /// Search terms to try in order: the label without junk tokens and numbers;
    /// then spellings a label can't hold (labels have no apostrophes, and some
    /// put "THE" last): "OCEANS ELEVEN" → "OCEAN'S ELEVEN", "MATRIX THE" → "THE
    /// MATRIX"; then the whole label if that differs.
    static func candidates(fromVolumeName volumeName: String) -> [String] {
        let words = volumeName
            .replacingOccurrences(of: "_", with: " ")
            .split(separator: " ").map(String.init)
        // "ARMY_OF_DARKNESS_DIRECTORS_CUT" searches for "ARMY OF DARKNESS".
        let titleWords = MovieEdition.split(volumeName: volumeName).titleWords
        let cleanedWords = titleWords.filter { !volumeLabelJunk.contains($0.lowercased()) && Int($0) == nil }

        let raw = words.joined(separator: " ").trimmingCharacters(in: .whitespaces)
        let cleaned = cleanedWords.joined(separator: " ").trimmingCharacters(in: .whitespaces)

        var candidates: [String] = []
        func add(_ candidate: String) {
            guard !candidate.isEmpty,
                  !candidates.contains(where: { $0.caseInsensitiveCompare(candidate) == .orderedSame }) else { return }
            candidates.append(candidate)
        }
        add(cleaned)
        for variant in spellingVariants(of: cleanedWords) { add(variant) }
        add(raw)
        return candidates
    }

    /// At most a few, so a long label doesn't send a dozen lookups.
    static let maxSpellingVariants = 3

    private static func spellingVariants(of words: [String]) -> [String] {
        var variants: [String] = []
        var words = words
        // "MATRIX THE" → "THE MATRIX"
        if words.count >= 2, words.last?.lowercased() == "the" {
            words = ["THE"] + words.dropLast()
            variants.append(words.joined(separator: " "))
        }
        // "OCEANS" → "OCEAN'S", one word at a time. Not the last word: a title
        // rarely ends in a possessive, and "GOONIES" is just a plural.
        for (index, word) in words.enumerated().dropLast() where variants.count < maxSpellingVariants {
            let lower = word.lowercased()
            guard lower.count >= 4, lower.hasSuffix("s"), !lower.hasSuffix("ss"), !lower.hasSuffix("us"),
                  !word.contains("'") else { continue }
            var possessive = words
            possessive[index] = String(word.dropLast()) + (word.last == "S" ? "'S" : "'s")
            variants.append(possessive.joined(separator: " "))
        }
        return variants
    }

    /// Labels that name the format, not the film ("DVD_VIDEO", "VIDEO_TS"):
    /// searching them only finds unrelated titles, so they aren't looked up.
    static func isGenericLabel(_ label: String) -> Bool {
        let key = label.trimmingCharacters(in: .whitespaces).uppercased()
            .replacingOccurrences(of: " ", with: "_")
        return key.isEmpty || HomeVideoDetector.genericLabels.contains(key)
            || HomeVideoDetector.genericLabels.contains(key.replacingOccurrences(of: "_", with: " "))
            || genericLabels.contains(key)
    }

    /// More labels authoring tools leave on pressed discs.
    static let genericLabels: Set<String> = [
        "DVD_VIDEO_DISC", "DVDVOLUME", "DVD_VOLUME", "VOLUME", "VOLUME_1", "BDROM", "BD_ROM", "BLURAY",
        "BLU-RAY", "BD", "BDMV", "DISC1", "DISC_1", "MOVIE", "FEATURE", "MAIN", "TITLE", "CDROM"
    ]

    /// What a disc with a generic label is called until someone names it:
    /// unique, so two such discs don't share a folder.
    static func placeholderName(at date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH-mm"
        return "Untitled Disc \(formatter.string(from: date))"
    }

    /// The release year a label carries ("OCEANS_ELEVEN_2001" → "2001").
    static func year(inVolumeName volumeName: String) -> String? {
        let thisYear = Calendar.current.component(.year, from: Date())
        return volumeName.replacingOccurrences(of: "_", with: " ").split(separator: " ")
            .compactMap { Int($0) }.last { (1920...thisYear + 1).contains($0) }.map(String.init)
    }

    /// The match to use. A title equal to the query (ignoring case and
    /// punctuation, so "Ocean's Eleven" equals "OCEANS ELEVEN") beats the
    /// provider's first hit, which is often an older film with a similar name;
    /// with the label's year, a match from that year beats a remake or original.
    static func bestMatch(for query: String, in matches: [MovieMatch], year: String? = nil) -> MovieMatch? {
        let wanted = normalized(query)
        let sameTitle = matches.filter { normalized($0.title) == wanted }
        let fromYear: (MovieMatch) -> Bool = { match in
            guard let year = year, let matchYear = match.year else { return false }
            return matchYear.hasPrefix(year)
        }
        return sameTitle.first(where: fromYear) ?? sameTitle.first ?? matches.first(where: fromYear) ?? matches.first
    }

    /// A lookup's answer and how sure it is.
    struct Resolution: Equatable {
        /// What the disc is named after unless the user picks another.
        let best: MovieMatch
        /// Up to `maxChoices` matches to offer, `best` first.
        let choices: [MovieMatch]
        /// True when exactly one film has the label's title (and year, when the
        /// label has one). Otherwise the user is asked to pick.
        let isConfident: Bool
    }

    static let maxChoices = 8

    static func resolve(query: String, matches: [MovieMatch], year: String? = nil) -> Resolution? {
        guard let best = bestMatch(for: query, in: matches, year: year) else { return nil }
        let wanted = normalized(query)
        let sameTitle = matches.filter { normalized($0.title) == wanted }
        let fromYear = sameTitle.filter { match in year.map { match.year?.hasPrefix($0) ?? false } ?? true }
        let confident = year == nil ? sameTitle.count == 1 : fromYear.count == 1
        var choices = [best]
        for match in matches where choices.count < maxChoices && !choices.contains(match) { choices.append(match) }
        return Resolution(best: best, choices: choices, isConfident: confident)
    }

    /// Lowercased, apostrophes dropped, "&" as "and", other punctuation as spaces.
    static func normalized(_ title: String) -> String {
        let lowered = title.lowercased()
            .replacingOccurrences(of: "'", with: "").replacingOccurrences(of: "\u{2019}", with: "")
            .replacingOccurrences(of: "&", with: " and ")
        return lowered.map { $0.isLetter || $0.isNumber ? String($0) : " " }.joined()
            .split(separator: " ").joined(separator: " ")
    }
}

/// OMDb (omdbapi.com) movie search.
struct OMDbProvider: MovieMetadataProvider {
    let name = "OMDb"
    var apiKey = "6132cfef"
    var session: URLSession = .shared

    func searchMovies(query: String, completion: @escaping ([MovieMatch]) -> Void) {
        guard let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "https://www.omdbapi.com/?s=\(encoded)&type=movie&apikey=\(apiKey)") else {
            completion([])
            return
        }
        session.dataTask(with: url) { data, _, error in
            guard error == nil, let data = data else { completion([]); return }
            completion(Self.parseSearchResponse(data))
        }.resume()
    }

    /// Matches from an OMDb `?s=` search response. Pure, for tests.
    static func parseSearchResponse(_ data: Data) -> [MovieMatch] {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              json["Response"] as? String == "True",
              let results = json["Search"] as? [[String: Any]] else { return [] }
        return results.compactMap { result in
            guard let title = result["Title"] as? String else { return nil }
            let poster = (result["Poster"] as? String).flatMap { $0.hasPrefix("http") ? URL(string: $0) : nil }
            return MovieMatch(title: title, year: result["Year"] as? String, posterURL: poster,
                              imdbID: result["imdbID"] as? String)
        }
    }
}

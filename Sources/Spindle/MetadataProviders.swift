import Foundation

/// A movie a metadata provider found for a disc.
struct MovieMatch: Equatable {
    let title: String
    /// As the provider gives it: "1985", or a range like "2008–2013".
    let year: String?

    /// Plex-style "Title (Year)".
    var displayName: String {
        guard let year = year, !year.isEmpty else { return title }
        return "\(title) (\(year))"
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

    /// Search terms to try in order: the label without junk tokens and numbers,
    /// then the whole label if that differs.
    static func candidates(fromVolumeName volumeName: String) -> [String] {
        let words = volumeName
            .replacingOccurrences(of: "_", with: " ")
            .split(separator: " ").map(String.init)
        let cleanedWords = words.filter { !volumeLabelJunk.contains($0.lowercased()) && Int($0) == nil }

        let raw = words.joined(separator: " ").trimmingCharacters(in: .whitespaces)
        let cleaned = cleanedWords.joined(separator: " ").trimmingCharacters(in: .whitespaces)

        var candidates: [String] = []
        if !cleaned.isEmpty { candidates.append(cleaned) }
        if !raw.isEmpty, raw.caseInsensitiveCompare(cleaned) != .orderedSame { candidates.append(raw) }
        return candidates
    }

    /// An exact (case-insensitive) title match beats the provider's first hit,
    /// which is often an older film with a similar name.
    static func bestMatch(for query: String, in matches: [MovieMatch]) -> MovieMatch? {
        matches.first { $0.title.caseInsensitiveCompare(query) == .orderedSame } ?? matches.first
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
            return MovieMatch(title: title, year: result["Year"] as? String)
        }
    }
}

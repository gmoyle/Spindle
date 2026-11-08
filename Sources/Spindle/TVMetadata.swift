import Foundation

/// A TV series a metadata provider found.
struct SeriesMatch: Codable, Equatable {
    /// The provider's own ID (a TMDB number, or an IMDb "tt…" ID from OMDb).
    let id: String
    let name: String
    /// First-air year, e.g. "2002".
    let year: String?
    /// Which provider `id` belongs to ("TMDB" or "OMDb").
    let provider: String

    /// Plex-style "Name (Year)".
    var displayName: String {
        guard let year = year, !year.isEmpty else { return name }
        return "\(name) (\(year))"
    }
}

/// The episodes of one season.
struct SeasonListing: Equatable {
    struct Episode: Equatable {
        let number: Int
        let title: String
        /// Runtime in minutes, when the provider knows it (TMDB does, OMDb doesn't).
        let runtimeMinutes: Int?
    }

    let season: Int
    /// How many seasons the series has, if known.
    let seasonCount: Int?
    let episodes: [Episode]

    func episode(_ number: Int) -> Episode? { episodes.first { $0.number == number } }
}

/// Looks up TV series and their episode lists.
protocol TVMetadataProvider {
    var name: String { get }
    /// Calls back on an arbitrary queue with matches, best first; empty if none.
    func searchSeries(query: String, completion: @escaping ([SeriesMatch]) -> Void)
    /// Calls back with the season's episodes, or nil if unknown or the lookup failed.
    func season(_ number: Int, of series: SeriesMatch, completion: @escaping (SeasonListing?) -> Void)
}

extension MetadataProviders {
    /// TMDB when a TMDB key is set (it has episode runtimes), OMDb otherwise or
    /// when TMDB finds nothing.
    static var tv: TVMetadataProvider = PreferredTVProvider()
}

/// The first provider that answers: TMDB if a key is configured, then OMDb.
struct PreferredTVProvider: TVMetadataProvider {
    let name = "TMDB/OMDb"

    private var chain: [TVMetadataProvider] {
        let key = SettingsManager.shared.tmdbAPIKey
        return (key.isEmpty ? [] : [TMDBProvider(apiKey: key)]) + [OMDbProvider()]
    }

    func searchSeries(query: String, completion: @escaping ([SeriesMatch]) -> Void) {
        func attempt(_ providers: ArraySlice<TVMetadataProvider>) {
            guard let provider = providers.first else { completion([]); return }
            provider.searchSeries(query: query) { matches in
                matches.isEmpty ? attempt(providers.dropFirst()) : completion(matches)
            }
        }
        attempt(chain[...])
    }

    func season(_ number: Int, of series: SeriesMatch, completion: @escaping (SeasonListing?) -> Void) {
        guard let provider = chain.first(where: { $0.name == series.provider }) else {
            completion(nil)
            return
        }
        provider.season(number, of: series, completion: completion)
    }
}

/// Movies: TMDB if a key is configured, falling back to OMDb.
struct PreferredMovieProvider: MovieMetadataProvider {
    let name = "TMDB/OMDb"

    func searchMovies(query: String, completion: @escaping ([MovieMatch]) -> Void) {
        let key = SettingsManager.shared.tmdbAPIKey
        let omdb = OMDbProvider()
        guard !key.isEmpty else { omdb.searchMovies(query: query, completion: completion); return }
        TMDBProvider(apiKey: key).searchMovies(query: query) { matches in
            matches.isEmpty ? omdb.searchMovies(query: query, completion: completion) : completion(matches)
        }
    }
}

// MARK: - TMDB

/// The Movie Database (themoviedb.org) API v3. Needs the user's own free API
/// key: either the short "API key" or the long "read access token" works.
struct TMDBProvider: TVMetadataProvider, MovieMetadataProvider {
    let name = "TMDB"
    let apiKey: String
    var session: URLSession = .shared

    /// A v4 read access token is a JWT ("eyJ…") sent as a bearer token; a v3
    /// API key goes in the query string.
    private var usesBearerToken: Bool { apiKey.hasPrefix("eyJ") }

    func request(_ path: String, _ query: [String: String]) -> URLRequest? {
        var components = URLComponents(string: "https://api.themoviedb.org/3\(path)")
        var items = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        if !usesBearerToken { items.append(URLQueryItem(name: "api_key", value: apiKey)) }
        components?.queryItems = items
        guard let url = components?.url else { return nil }
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if usesBearerToken { request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization") }
        return request
    }

    private func get(_ request: URLRequest?, completion: @escaping (Data?) -> Void) {
        guard let request = request else { completion(nil); return }
        session.dataTask(with: request) { data, response, error in
            let ok = error == nil && (response as? HTTPURLResponse)?.statusCode == 200
            completion(ok ? data : nil)
        }.resume()
    }

    func searchSeries(query: String, completion: @escaping ([SeriesMatch]) -> Void) {
        get(request("/search/tv", ["query": query])) { data in
            completion(data.map(Self.parseSeriesSearch) ?? [])
        }
    }

    func season(_ number: Int, of series: SeriesMatch, completion: @escaping (SeasonListing?) -> Void) {
        // One call: the series (for its season count) with the season appended.
        get(request("/tv/\(series.id)", ["append_to_response": "season/\(number)"])) { data in
            completion(data.flatMap { Self.parseSeason($0, number: number) })
        }
    }

    func searchMovies(query: String, completion: @escaping ([MovieMatch]) -> Void) {
        get(request("/search/movie", ["query": query])) { data in
            completion(data.map(Self.parseMovieSearch) ?? [])
        }
    }

    // MARK: Parsing (pure, for tests)

    static func parseSeriesSearch(_ data: Data) -> [SeriesMatch] {
        results(in: data).compactMap { result in
            guard let id = result["id"] as? Int, let name = result["name"] as? String else { return nil }
            return SeriesMatch(id: String(id), name: name, year: year(result["first_air_date"]), provider: "TMDB")
        }
    }

    static func parseMovieSearch(_ data: Data) -> [MovieMatch] {
        results(in: data).compactMap { result in
            guard let title = result["title"] as? String else { return nil }
            return MovieMatch(title: title, year: year(result["release_date"]))
        }
    }

    static func parseSeason(_ data: Data, number: Int) -> SeasonListing? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let season = json["season/\(number)"] as? [String: Any],
              let episodes = season["episodes"] as? [[String: Any]] else { return nil }
        let list: [SeasonListing.Episode] = episodes.compactMap { episode in
            guard let number = episode["episode_number"] as? Int else { return nil }
            return SeasonListing.Episode(number: number,
                                         title: episode["name"] as? String ?? "Episode \(number)",
                                         runtimeMinutes: episode["runtime"] as? Int)
        }
        guard !list.isEmpty else { return nil }
        return SeasonListing(season: number, seasonCount: json["number_of_seasons"] as? Int, episodes: list)
    }

    private static func results(in data: Data) -> [[String: Any]] {
        let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        return json?["results"] as? [[String: Any]] ?? []
    }

    private static func year(_ value: Any?) -> String? {
        guard let date = value as? String, date.count >= 4 else { return nil }
        return String(date.prefix(4))
    }
}

// MARK: - OMDb series

extension OMDbProvider: TVMetadataProvider {

    func searchSeries(query: String, completion: @escaping ([SeriesMatch]) -> Void) {
        guard let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "https://www.omdbapi.com/?s=\(encoded)&type=series&apikey=\(apiKey)") else {
            completion([])
            return
        }
        session.dataTask(with: url) { data, _, error in
            completion(error == nil ? data.map(Self.parseSeriesSearch) ?? [] : [])
        }.resume()
    }

    func season(_ number: Int, of series: SeriesMatch, completion: @escaping (SeasonListing?) -> Void) {
        guard let url = URL(string: "https://www.omdbapi.com/?i=\(series.id)&Season=\(number)&apikey=\(apiKey)") else {
            completion(nil)
            return
        }
        session.dataTask(with: url) { data, _, error in
            completion(error == nil ? data.flatMap { Self.parseSeason($0, number: number) } : nil)
        }.resume()
    }

    static func parseSeriesSearch(_ data: Data) -> [SeriesMatch] {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              json["Response"] as? String == "True",
              let results = json["Search"] as? [[String: Any]] else { return [] }
        return results.compactMap { result in
            guard let id = result["imdbID"] as? String, let title = result["Title"] as? String else { return nil }
            // "2002–2003" → "2002"
            let year = (result["Year"] as? String).map { String($0.prefix(4)) }
            return SeriesMatch(id: id, name: title, year: year, provider: "OMDb")
        }
    }

    static func parseSeason(_ data: Data, number: Int) -> SeasonListing? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              json["Response"] as? String == "True",
              let episodes = json["Episodes"] as? [[String: Any]] else { return nil }
        let list: [SeasonListing.Episode] = episodes.compactMap { episode in
            guard let number = (episode["Episode"] as? String).flatMap({ Int($0) }) else { return nil }
            return SeasonListing.Episode(number: number, title: episode["Title"] as? String ?? "Episode \(number)",
                                         runtimeMinutes: nil)
        }
        guard !list.isEmpty else { return nil }
        let count = (json["totalSeasons"] as? String).flatMap { Int($0) }
        return SeasonListing(season: number, seasonCount: count, episodes: list.sorted { $0.number < $1.number })
    }
}

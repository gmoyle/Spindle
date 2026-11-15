import Foundation

/// `poster.jpg` beside a film, for a media server that uses local artwork
/// (Plex with "Use local assets" / "Prefer local metadata", Jellyfin, Kodi).
/// The poster comes from OMDb by the film's IMDb id. Fetched in the
/// background; a missing poster never fails a rip.
enum MoviePoster {

    static let fileName = "poster.jpg"

    /// The IMDb id in a library name: "Die Hard (1988) {imdb-tt0095016}" → "tt0095016".
    static func imdbID(inLibraryName name: String) -> String? {
        guard let tag = MovieMatch.idTag(inLibraryName: name), tag.hasPrefix("imdb-") else { return nil }
        return String(tag.dropFirst("imdb-".count))
    }

    /// The poster URL in an OMDb `?i=` response, if it has one. Pure, for tests.
    static func posterURL(inOMDbResponse data: Data) -> URL? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              json["Response"] as? String == "True",
              let poster = json["Poster"] as? String, poster.hasPrefix("http") else { return nil }
        return URL(string: poster)
    }

    /// Fetch the poster for `libraryName` and save it as `folder/poster.jpg`,
    /// replacing any earlier one. A name without an IMDb id removes a stale
    /// poster (the rip was renamed to a film Spindle can't look up).
    static func save(in folder: String, libraryName: String, apiKey: String = OMDbProvider().apiKey,
                     session: URLSession = .shared, fileManager: FileManager = .default,
                     completion: ((Bool) -> Void)? = nil) {
        let destination = (folder as NSString).appendingPathComponent(fileName)
        guard let id = imdbID(inLibraryName: libraryName),
              let lookup = URL(string: "https://www.omdbapi.com/?i=\(id)&apikey=\(apiKey)") else {
            try? fileManager.removeItem(atPath: destination)
            completion?(false)
            return
        }
        session.dataTask(with: lookup) { data, _, _ in
            guard let data = data, let poster = posterURL(inOMDbResponse: data) else {
                completion?(false)
                return
            }
            session.dataTask(with: poster) { image, response, _ in
                let ok = (response as? HTTPURLResponse)?.statusCode == 200
                guard ok, let image = image, !image.isEmpty else {
                    completion?(false)
                    return
                }
                completion?(write(image, to: destination, fileManager: fileManager))
            }.resume()
        }.resume()
    }

    /// Write under a hidden name, then rename into place, so a media server
    /// watching the folder (often on a NAS) never reads half a picture.
    static func write(_ image: Data, to destination: String, fileManager: FileManager = .default) -> Bool {
        let folder = (destination as NSString).deletingLastPathComponent
        guard fileManager.fileExists(atPath: folder) else { return false }  // moved meanwhile
        let temporary = (folder as NSString).appendingPathComponent(".\(fileName).\(UUID().uuidString)")
        guard fileManager.createFile(atPath: temporary, contents: image) else { return false }
        do {
            if fileManager.fileExists(atPath: destination) {
                _ = try fileManager.replaceItemAt(URL(fileURLWithPath: destination),
                                                  withItemAt: URL(fileURLWithPath: temporary))
            } else {
                try fileManager.moveItem(atPath: temporary, toPath: destination)
            }
            return true
        } catch {
            try? fileManager.removeItem(atPath: temporary)
            Logger.shared.log("Couldn't save \(destination): \(error.localizedDescription)",
                              level: .warning, category: .general)
            return false
        }
    }
}

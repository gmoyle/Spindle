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

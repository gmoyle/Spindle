import Foundation

/// Routes a completed rip folder into the correct Plex library root (Movies or
/// TV Shows) based on its content type.
///
/// Two paths:
///  - **Auto**: after a rip, if content routing is on and the classifier is
///    confident (and auto-route is enabled), the folder moves straight to the
///    right root. Otherwise the rip is enqueued for the user to confirm later.
///    Either way the rip itself never blocks.
///  - **Manual**: the review UI calls `route(folder:to:)` when the user confirms
///    a queued item's Movie/TV choice.
/// Files a TV rip's episodes: folder, disc name, disc identity, titles, strict.
typealias TVFiling = (String, String, String?, [RippedTitle], Bool) -> TVLibraryFiler.Outcome

enum ContentRouter {

    /// Confidence at or above this is considered safe to auto-route without asking.
    static let autoRouteConfidenceThreshold: Double = 0.8

    enum RouteError: LocalizedError {
        case rootNotConfigured(ContentType)
        case moveFailed(String)

        var errorDescription: String? {
            switch self {
            case .rootNotConfigured(let type):
                return "No destination folder is set for \(type.displayName)s."
            case .moveFailed(let msg):
                return "Couldn't move the ripped folder: \(msg)"
            }
        }
    }

    /// Decide what to do with a just-completed rip. Returns a short status string
    /// for the log. Never throws for the "needs review" case — it enqueues.
    ///
    /// - Parameters:
    ///   - folderPath: the organized rip folder to route.
    ///   - discName: volume label for display in the review queue.
    ///   - discIdentity: stable disc identity (see [[DiscIdentity]]); stored on any
    ///     queued item so the skip-already-ripped check recognizes a disc that's
    ///     still awaiting review and doesn't re-rip it on re-insert.
    ///   - titleDurationsSeconds: enumerated title durations for classification.
    @discardableResult
    static func handleCompletedRip(folderPath: String,
                                   discName: String,
                                   discIdentity: String? = nil,
                                   titleDurationsSeconds: [Int],
                                   rippedTitles: [RippedTitle] = [],
                                   settings: SettingsManager = .shared,
                                   queue: PendingRoutingQueue = .shared,
                                   tvFiler: TVFiling = TVLibraryFiler.defaultFiler) -> String {
        guard settings.contentRoutingEnabled else {
            return "Content routing is off — leaving rip in place."
        }

        let classification = ContentTypeClassifier.classify(titleDurationsSeconds: titleDurationsSeconds)

        // A TV season: name and file each episode. Its own checks (the series is
        // found, the episode numbers are known) decide; if it isn't sure, the
        // rip waits for review with the reason.
        if settings.autoRouteHighConfidence, classification.type == .tvShow,
           rippedTitles.contains(where: \.isEpisode) {
            switch tvFiler(folderPath, discName, discIdentity, rippedTitles, true) {
            case .filed(let summary, _):
                return summary
            case .unsure(let reason):
                queue.enqueue(PendingRouting(
                    discName: discName, discIdentity: discIdentity, folderPath: folderPath,
                    guessedType: .tvShow, confidence: classification.confidence,
                    rippedTitles: rippedTitles, note: reason))
                return "Queued \(discName) for review: \(reason)"
            }
        }

        // High-confidence, known type, auto-route enabled → move now.
        if settings.autoRouteHighConfidence,
           classification.type != .unknown,
           classification.confidence >= autoRouteConfidenceThreshold {
            do {
                let dest = try route(folderPath: folderPath, to: classification.type,
                                     discIdentity: discIdentity, settings: settings)
                return "Auto-routed \(discName) to \(classification.type.displayName)s: \(dest)"
            } catch {
                // Fall through to queueing so a misconfigured root doesn't lose the rip.
                queue.enqueue(PendingRouting(
                    discName: discName, discIdentity: discIdentity, folderPath: folderPath,
                    guessedType: classification.type, confidence: classification.confidence,
                    rippedTitles: rippedTitles))
                return "Couldn't auto-route \(discName) (\(error.localizedDescription)) — queued for review."
            }
        }

        // Ambiguous or auto-route disabled → defer to the user's review queue.
        queue.enqueue(PendingRouting(
            discName: discName, discIdentity: discIdentity, folderPath: folderPath,
            guessedType: classification.type, confidence: classification.confidence,
            rippedTitles: rippedTitles))
        return "Queued \(discName) for Movie/TV review (guess: \(classification.type.displayName), "
            + "confidence \(Int(classification.confidence * 100))%)."
    }

    /// Move `folderPath` into the configured root for `type`. Returns the
    /// destination path. Library clients (Plex, the NAS indexer, Windows) never
    /// see a half-copied file: a cross-volume move copies under a hidden name
    /// and renames into place.
    ///
    /// A re-rip of the same disc (the library folder's recorded rip has the
    /// same `discIdentity`) replaces that rip's files in place rather than
    /// creating a "(2)" duplicate; anything else in the folder (artwork, NAS
    /// thumbnails) is left alone. A different disc with the same folder name
    /// still gets a " (2)" suffix.
    @discardableResult
    static func route(folderPath: String,
                      to type: ContentType,
                      discIdentity: String? = nil,
                      settings: SettingsManager = .shared,
                      fileManager: FileManager = .default,
                      history: RipHistoryStore = .shared) throws -> String {
        guard type != .unknown else { throw RouteError.rootNotConfigured(.unknown) }
        let root = settings.libraryRoot(LibraryKind(contentType: type))
        guard !root.isEmpty else { throw RouteError.rootNotConfigured(type) }

        let destination: String
        do {
            destination = try LibraryFiles.fileFolder(folderPath, into: root, discIdentity: discIdentity,
                                                      history: history, fileManager: fileManager)
        } catch {
            throw RouteError.moveFailed(error.localizedDescription)
        }

        // Record where this folder went. The rip registry may be written before
        // OR after routing depending on the path (for Blu-ray, routing runs first),
        // so we both update any existing entry now and remember the move so a
        // later registry write can resolve the staging path to its final home.
        recordMove(from: folderPath, to: destination)
        history.updateOutputLocation(from: folderPath, to: destination)

        return destination
    }

    /// The user chose a type in the review window. Choosing TV Show for a rip
    /// with episodes names them as best it can; otherwise (or if that fails) the
    /// folder moves into the library root as it is.
    static func applyReviewChoice(_ item: PendingRouting, as type: ContentType,
                                  tvFiler: TVFiling = TVLibraryFiler.defaultFiler) throws -> String {
        if type == .tvShow, let titles = item.rippedTitles, titles.contains(where: \.isEpisode) {
            switch tvFiler(item.folderPath, item.discName, item.discIdentity, titles, false) {
            case .filed(let summary, _):
                return summary
            case .unsure(let reason):
                Logger.shared.log("Couldn't name \(item.discName)'s episodes (\(reason)); moving the folder as is.",
                                  level: .warning, category: .general)
            }
        }
        let destination = try route(folderPath: item.folderPath, to: type, discIdentity: item.discIdentity)
        return "Routed \(item.discName) to \(type.displayName)s: \(destination)"
    }

    /// Maps a just-routed staging folder path → its final library location, so a
    /// registry write that happens after the move can record the real path.
    private static var recentMoves: [String: String] = [:]
    private static let recentMovesLock = NSLock()

    private static func recordMove(from source: String, to destination: String) {
        recentMovesLock.lock(); defer { recentMovesLock.unlock() }
        recentMoves[source] = destination
    }

    /// For filers that move a rip's files themselves (TV episodes): where the
    /// rip folder's contents went.
    static func recordFolderMove(from source: String, to destination: String) {
        recordMove(from: source, to: destination)
    }

    /// Individual files that were moved and renamed (TV episodes), so the queue
    /// records their final paths.
    private static var recentFileMoves: [String: String] = [:]

    static func recordFileMove(from source: String, to destination: String) {
        recentMovesLock.lock(); defer { recentMovesLock.unlock() }
        recentFileMoves[source] = destination
    }

    /// Final path of a file a filer moved, if one did. Consumed on read.
    static func finalFileLocation(for path: String) -> String? {
        recentMovesLock.lock(); defer { recentMovesLock.unlock() }
        return recentFileMoves.removeValue(forKey: path)
    }

    /// Final location a staging path was routed to, if routing moved it. Consumed
    /// (removed) on read so the map doesn't grow unbounded.
    static func finalLocation(forStagingPath path: String) -> String? {
        recentMovesLock.lock(); defer { recentMovesLock.unlock() }
        return recentMoves.removeValue(forKey: path)
    }
}

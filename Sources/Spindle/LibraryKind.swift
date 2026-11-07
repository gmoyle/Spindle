import Foundation

/// A library folder Spindle files imports into. Each has its own root, set in
/// Settings → Output & Routing.
enum LibraryKind: String, CaseIterable {
    case movies
    case tvShows
    case music
    case photos
    case homeVideos
    case importedDiscs

    var displayName: String {
        switch self {
        case .movies: return "Movies"
        case .tvShows: return "TV Shows"
        case .music: return "Music"
        case .photos: return "Photos"
        case .homeVideos: return "Home Videos"
        case .importedDiscs: return "Imported Discs"
        }
    }

    /// UserDefaults key for the root. Movies and TV keep their original keys.
    var settingsKey: String {
        switch self {
        case .movies: return "moviesRootDirectory"
        case .tvShows: return "tvShowsRootDirectory"
        case .music: return "musicRootDirectory"
        case .photos: return "photosRootDirectory"
        case .homeVideos: return "homeVideosRootDirectory"
        case .importedDiscs: return "importedDiscsRootDirectory"
        }
    }

    /// Folder name used for the default root, next to the Movies root.
    var defaultFolderName: String {
        switch self {
        case .movies: return "Movies"
        case .tvShows: return "TVShows"
        case .music: return "Music"
        case .photos: return "Photos"
        case .homeVideos: return "Home Videos"
        case .importedDiscs: return "Imported Discs"
        }
    }

    /// The library for a finished video rip's Movie/TV classification.
    init(contentType: ContentType) {
        self = contentType == .tvShow ? .tvShows : .movies
    }
}

extension SettingsManager {

    /// Root folder for a library. The newer libraries default to a folder next
    /// to the Movies root, so a NAS share with Movies on it (`/Volumes/Media/Movies`)
    /// gets `/Volumes/Media/Music` and so on without any setup.
    func libraryRoot(_ kind: LibraryKind) -> String {
        switch kind {
        case .movies: return moviesRootDirectory
        case .tvShows: return tvShowsRootDirectory
        default:
            if let value = UserDefaults.standard.string(forKey: kind.settingsKey), !value.isEmpty {
                return value
            }
            return Self.defaultLibraryRoot(kind, moviesRoot: moviesRootDirectory)
        }
    }

    func setLibraryRoot(_ path: String, for kind: LibraryKind) {
        switch kind {
        case .movies: moviesRootDirectory = path
        case .tvShows: tvShowsRootDirectory = path
        default: UserDefaults.standard.set(path, forKey: kind.settingsKey)
        }
    }

    /// Whether the user has chosen this library's root (rather than the default).
    func hasChosenLibraryRoot(_ kind: LibraryKind) -> Bool {
        UserDefaults.standard.string(forKey: kind.settingsKey)?.isEmpty == false
    }

    static func defaultLibraryRoot(_ kind: LibraryKind, moviesRoot: String) -> String {
        let parent = (moviesRoot as NSString).deletingLastPathComponent
        return (parent as NSString).appendingPathComponent(kind.defaultFolderName)
    }
}

import Foundation
import ImageIO
import Photos

/// Where photos from a photo disc go, chosen the first time one is inserted.
enum PhotoDestination: String, CaseIterable {
    /// The Photos library folder: `Photos/2004/2004-07-14/`.
    case folder
    /// The Apple Photos app's library.
    case applePhotos
    case both

    var displayName: String {
        switch self {
        case .folder: return "Photos folder"
        case .applePhotos: return "Apple Photos"
        case .both: return "Photos folder and Apple Photos"
        }
    }

    var includesFolder: Bool { self != .applePhotos }
    var includesApplePhotos: Bool { self != .folder }
}

extension SettingsManager {
    /// Nil until the user has chosen (Spindle asks on the first photo disc).
    var photoDestination: PhotoDestination? {
        get { UserDefaults.standard.string(forKey: "photoDestination").flatMap(PhotoDestination.init) }
        set { UserDefaults.standard.set(newValue?.rawValue, forKey: "photoDestination") }
    }
}

/// The files on a photo disc worth importing, and when each was taken.
enum PhotoMedia {

    /// Camera and phone video clips that sit next to the photos (DCIM/100CANON/MVI_0001.MOV).
    static let videoExtensions: Set<String> = ["mov", "mp4", "m4v", "avi", "mts", "m2ts", "3gp", "mpg"]

    static func isPhoto(_ path: String) -> Bool {
        DiscClassifier.photoExtensions.contains((path as NSString).pathExtension.lowercased())
    }

    static func isImportable(_ path: String) -> Bool {
        isPhoto(path) || videoExtensions.contains((path as NSString).pathExtension.lowercased())
    }

    /// Every importable file under `root`, sorted by path; hidden files and
    /// thumbnails caches are skipped. Also returns the files left alone.
    static func files(under root: String, fileManager: FileManager = .default)
        -> (media: [String], skipped: [String]) {
        guard let walker = fileManager.enumerator(
            at: URL(fileURLWithPath: root), includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return ([], []) }
        var media: [String] = []
        var skipped: [String] = []
        for case let url as URL in walker {
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { continue }
            // Kodak Picture CD keeps low-resolution copies in its own folders.
            let components = url.pathComponents.map { $0.uppercased() }
            if components.contains("THUMBS") || components.contains(".THUMBNAILS") { continue }
            if isImportable(url.path) { media.append(url.path) } else { skipped.append(url.path) }
        }
        return (media.sorted(), skipped.sorted())
    }

    /// When the photo was taken: EXIF DateTimeOriginal, then the TIFF date, then
    /// the file's own date. Nil only if none can be read.
    static func captureDate(of path: String, fileManager: FileManager = .default) -> Date? {
        if isPhoto(path), let date = metadataDate(of: path) { return date }
        let attributes = try? fileManager.attributesOfItem(atPath: path)
        return attributes?[.modificationDate] as? Date ?? attributes?[.creationDate] as? Date
    }

    static func metadataDate(of path: String) -> Date? {
        guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else {
            return nil
        }
        let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any]
        let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
        let candidates = [exif?[kCGImagePropertyExifDateTimeOriginal], exif?[kCGImagePropertyExifDateTimeDigitized],
                          tiff?[kCGImagePropertyTIFFDateTime]]
        return candidates.compactMap { $0 as? String }.lazy.compactMap(parseEXIFDate).first
    }

    /// "2004:07:14 15:32:10" (EXIF's format, in the camera's local time).
    static func parseEXIFDate(_ text: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(19)
        guard let date = formatter.date(from: String(trimmed)),
              Calendar.current.component(.year, from: date) > 1900 else { return nil }
        return date
    }
}

/// `Photos/2004/2004-07-14/IMG_0001.JPG`; photos with no date go in `Photos/Undated/`.
enum PhotoLibraryNaming {
    static func folder(for date: Date?, in root: String) -> String {
        guard let date = date else { return (root as NSString).appendingPathComponent("Undated") }
        let parts = Calendar.current.dateComponents([.year, .month, .day], from: date)
        let year = String(format: "%04d", parts.year ?? 0)
        let day = String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
        return ((root as NSString).appendingPathComponent(year) as NSString).appendingPathComponent(day)
    }
}

/// Which photos have been imported, by content hash, so the same photo from
/// another disc (or the same disc again) isn't imported twice. Stored as JSON
/// in Application Support.
final class PhotoIndex {

    struct Entry: Codable, Equatable {
        /// Where it was filed in the Photos folder, if it was.
        var path: String?
        var inApplePhotos: Bool
    }

    static let shared = PhotoIndex(fileURL: TestingUtilities.shared.isRunningInTestEnvironment
        ? FileManager.default.temporaryDirectory.appendingPathComponent("spindle-photo-index-\(UUID().uuidString).json")
        : AppIdentity.supportDirectory.appendingPathComponent("photo-index.json"))

    private let fileURL: URL
    private let lock = NSLock()
    private var entries: [String: Entry]

    init(fileURL: URL) {
        self.fileURL = fileURL
        entries = (try? Data(contentsOf: fileURL)).flatMap { try? JSONDecoder().decode([String: Entry].self, from: $0) }
            ?? [:]
    }

    func entry(forHash hash: String) -> Entry? {
        lock.lock(); defer { lock.unlock() }
        return entries[hash]
    }

    /// Already in the Photos folder (and the file is still there).
    func isInFolder(_ hash: String, fileManager: FileManager = .default) -> Bool {
        guard let path = entry(forHash: hash)?.path else { return false }
        return fileManager.fileExists(atPath: path)
    }

    func isInApplePhotos(_ hash: String) -> Bool { entry(forHash: hash)?.inApplePhotos ?? false }

    func record(hash: String, path: String? = nil, inApplePhotos: Bool = false) {
        lock.lock(); defer { lock.unlock() }
        var entry = entries[hash] ?? Entry(path: nil, inApplePhotos: false)
        if let path = path { entry.path = path }
        if inApplePhotos { entry.inApplePhotos = true }
        entries[hash] = entry
    }

    func save() {
        lock.lock(); defer { lock.unlock() }
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(entries) { try? data.write(to: fileURL, options: .atomic) }
    }
}

/// Adds files to the Apple Photos library (add-only access; Spindle never reads
/// or changes what's already there).
enum ApplePhotosImporter {

    enum ImportError: LocalizedError {
        case notAllowed

        var errorDescription: String? {
            "Spindle isn't allowed to add to Apple Photos. Allow it in System Settings → Privacy & Security → Photos."
        }
    }

    /// Ask for add-only access if it hasn't been decided yet. Blocks; call off
    /// the main thread.
    static func requestAccess() -> Bool {
        switch PHPhotoLibrary.authorizationStatus(for: .addOnly) {
        case .authorized, .limited: return true
        case .denied, .restricted: return false
        case .notDetermined:
            let done = DispatchSemaphore(value: 0)
            var granted = false
            PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
                granted = status == .authorized || status == .limited
                done.signal()
            }
            done.wait()
            return granted
        @unknown default: return false
        }
    }

    /// Import `files` in one change, so a failure adds none of them. Photos
    /// copies each file into its library.
    static func importFiles(_ files: [String]) throws {
        guard !files.isEmpty else { return }
        guard requestAccess() else { throw ImportError.notAllowed }
        try PHPhotoLibrary.shared().performChangesAndWait {
            for file in files {
                let request = PHAssetCreationRequest.forAsset()
                let options = PHAssetResourceCreationOptions()
                options.originalFilename = (file as NSString).lastPathComponent
                request.addResource(with: PhotoMedia.isPhoto(file) ? .photo : .video,
                                    fileURL: URL(fileURLWithPath: file), options: options)
            }
        }
    }
}

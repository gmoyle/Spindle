import Foundation

/// Decides what kind of disc a mounted volume holds from its contents.
///
/// Video and audio discs are recognized from their fixed structure, which only
/// discs have. Photo and data discs are just files, which any USB drive also
/// has, so those kinds are only reported when the volume is optical media.
enum DiscClassifier {

    static let photoExtensions: Set<String> = [
        "jpg", "jpeg", "heic", "heif", "png", "tif", "tiff", "gif", "bmp",
        "dng", "cr2", "cr3", "crw", "nef", "nrw", "arw", "srf", "sr2", "orf",
        "rw2", "raf", "pef", "srw", "x3f", "3fr", "erf", "kdc", "mrw"
    ]

    /// Folders that mark a photo disc on their own: a camera card layout, and
    /// Kodak Picture CD / Photo CD.
    static let photoFolderNames: Set<String> = ["DCIM", "PICTURES", "PHOTO_CD"]

    /// A data disc is a photo disc when at least this share of its files are photos.
    static let photoShareThreshold = 0.5

    /// Upper bound on files examined, so a huge data disc doesn't stall detection.
    static let maxFilesScanned = 5000

    static func classify(volumeAt path: String,
                         isOpticalMedia: (String) -> Bool = DriveDetector.isOpticalMedia,
                         fileManager: FileManager = .default) -> DiscKind {
        func has(_ name: String) -> Bool {
            fileManager.fileExists(atPath: (path as NSString).appendingPathComponent(name))
        }

        if has("BDMV") || has("CERTIFICATE") {
            return MediaRipper.isUHDIndex(atPath: (path as NSString).appendingPathComponent("BDMV/index.bdmv"))
                ? .bluray4K : .bluray
        }
        if has("HVDVD_TS") || has("ADV_OBJ") { return .hddvd }
        if has("VIDEO_TS") || has("AUDIO_TS") { return .dvd }

        let topLevel = ((try? fileManager.contentsOfDirectory(atPath: path)) ?? [])
            .filter { !$0.hasPrefix(".") || $0 == ".TOC.plist" }
        if isAudioCD(topLevel: topLevel) { return .audioCD }

        let visible = topLevel.filter { !$0.hasPrefix(".") }
        guard !visible.isEmpty, isOpticalMedia(path) else { return .unknown }

        if visible.contains(where: { photoFolderNames.contains($0.uppercased()) }) { return .photoDisc }
        let (files, photos) = countFiles(under: path, fileManager: fileManager)
        guard files > 0 else { return .dataDisc }
        return Double(photos) / Double(files) >= photoShareThreshold ? .photoDisc : .dataDisc
    }

    /// macOS mounts an audio CD (cddafs) as one AIFF file per track plus a
    /// hidden `.TOC.plist` with the track layout.
    static func isAudioCD(topLevel names: [String]) -> Bool {
        if names.contains(".TOC.plist") { return true }
        let visible = names.filter { !$0.hasPrefix(".") }
        return !visible.isEmpty && visible.allSatisfy {
            let ext = ($0 as NSString).pathExtension.lowercased()
            return ext == "aiff" || ext == "aif"
        }
    }

    /// Regular files under `path` (skipping hidden ones), and how many are photos.
    static func countFiles(under path: String, fileManager: FileManager = .default) -> (files: Int, photos: Int) {
        guard let walker = fileManager.enumerator(
            at: URL(fileURLWithPath: path),
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return (0, 0) }
        var files = 0, photos = 0
        for case let url as URL in walker {
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { continue }
            files += 1
            if photoExtensions.contains(url.pathExtension.lowercased()) { photos += 1 }
            if files >= maxFilesScanned { break }
        }
        return (files, photos)
    }
}

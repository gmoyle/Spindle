import Foundation

/// Where a photo goes in the Photos folder. Spindle follows the layout that's
/// already there:
/// - decade folders (`2000-2009/2004/July/2004-07-Wed-153210.jpg`, with the
///   oldest years in a folder like `~ To 1979/1975/`), named by the time the
///   photo was taken; two from the same second become `…(1).jpg`;
/// - otherwise `2004/2004-07-14/IMG_0001.JPG`, keeping the disc's names.
/// Photos with no date go in `Undated/` either way.
enum PhotoLibraryNaming {

    struct Layout: Equatable {
        /// Decade, year and month folders, with files named by date and time.
        var decades: Bool
        /// A folder for the oldest photos ("~ To 1979") and the last year it holds.
        var earlyFolder: String?
        var earlyFolderLastYear: Int?

        static let byDay = Layout(decades: false, earlyFolder: nil, earlyFolderLastYear: nil)
    }

    static let undatedFolder = "Undated"

    /// The layout of the Photos folder at `root`: decade folders if it has any.
    static func layout(of root: String, fileManager: FileManager = .default) -> Layout {
        let names = (try? fileManager.contentsOfDirectory(atPath: root)) ?? []
        guard names.contains(where: { decadeStart(ofFolder: $0) != nil }) else { return .byDay }
        var layout = Layout(decades: true, earlyFolder: nil, earlyFolderLastYear: nil)
        for name in names {
            if let year = earlyFolderLastYear(name), year >= (layout.earlyFolderLastYear ?? year) {
                layout.earlyFolder = name
                layout.earlyFolderLastYear = year
            }
        }
        return layout
    }

    /// 2000 for "2000-2009".
    static func decadeStart(ofFolder name: String) -> Int? {
        let parts = name.split(separator: "-")
        guard parts.count == 2, parts.allSatisfy({ $0.count == 4 }),
              let first = Int(parts[0]), let last = Int(parts[1]), last == first + 9 else { return nil }
        return first
    }

    /// 1979 for "~ To 1979" (or "To 1979", "Up To 1979").
    static func earlyFolderLastYear(_ name: String) -> Int? {
        let words = name.split(separator: " ")
        guard words.count >= 2, words[words.count - 2].lowercased() == "to",
              let last = words.last, last.count == 4 else { return nil }
        return Int(last)
    }

    /// The folder a photo taken on `date` belongs in.
    static func folder(for date: Date?, in root: String, layout: Layout = .byDay) -> String {
        guard let date = date else { return (root as NSString).appendingPathComponent(undatedFolder) }
        let parts = Calendar.current.dateComponents([.year, .month, .day], from: date)
        let year = parts.year ?? 0
        guard layout.decades else {
            let day = String(format: "%04d-%02d-%02d", year, parts.month ?? 0, parts.day ?? 0)
            return [String(format: "%04d", year), day].reduce(root) { ($0 as NSString).appendingPathComponent($1) }
        }
        let top: String
        if let early = layout.earlyFolder, let last = layout.earlyFolderLastYear, year <= last {
            top = early
        } else {
            let start = year - year % 10
            top = "\(start)-\(start + 9)"
        }
        return [top, String(year), formatter("MMMM").string(from: date)]
            .reduce(root) { ($0 as NSString).appendingPathComponent($1) }
    }

    /// The photo's file name: "2004-07-Wed-153210.jpg" in a decade library,
    /// otherwise the disc's own name.
    static func fileName(for original: String, date: Date?, layout: Layout) -> String {
        let name = (original as NSString).lastPathComponent
        guard layout.decades, let date = date else { return name }
        let ext = (name as NSString).pathExtension.lowercased()
        let base = formatter("yyyy-MM-EEE-HHmmss").string(from: date)
        return ext.isEmpty ? base : "\(base).\(ext)"
    }

    /// The full path for a photo, before checking whether the name is free.
    static func path(for original: String, date: Date?, in root: String, layout: Layout) -> String {
        (folder(for: date, in: root, layout: layout) as NSString)
            .appendingPathComponent(fileName(for: original, date: date, layout: layout))
    }

    /// The first free path: "name(1).jpg", "name(2).jpg"… in a decade library
    /// (as its own duplicates are named), "name (2).jpg"… otherwise.
    static func freePath(_ path: String, layout: Layout, fileManager: FileManager = .default) -> String {
        guard fileManager.fileExists(atPath: path) else { return path }
        guard layout.decades else { return LibraryFiles.uniqueFilePath(path, fileManager: fileManager) }
        let base = (path as NSString).deletingPathExtension
        let ext = (path as NSString).pathExtension
        var n = 1
        var candidate: String
        repeat {
            candidate = ext.isEmpty ? "\(base)(\(n))" : "\(base)(\(n)).\(ext)"
            n += 1
        } while fileManager.fileExists(atPath: candidate)
        return candidate
    }

    private static func formatter(_ format: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = format
        return formatter
    }
}

/// The photos and clips already in a Photos folder, so an import skips a photo
/// that's there under another name or in another folder (a library filed
/// before Spindle). Files are grouped by size and only a file the same size as
/// a new photo is ever read, so a big library on a NAS stays quick to check.
final class PhotoLibraryContents {

    /// Folders a NAS or another app keeps its own things in.
    static let ignoredFolders: Set<String> = ["@recycle", "#recycle", "@eadir", ".trash", "$recycle.bin"]

    private let fileManager: FileManager
    private var bySize: [UInt64: [String]] = [:]
    private var hashes: [String: String] = [:]
    private(set) var fileCount = 0

    init(root: String, fileManager: FileManager = .default) {
        self.fileManager = fileManager
        // Sizes come with the directory listing (bulk reads): asking for each
        // file's attributes one by one takes hours on a NAS of 80,000 photos.
        let keys: [URLResourceKey] = [.isRegularFileKey, .isDirectoryKey, .fileSizeKey]
        guard let walker = fileManager.enumerator(at: URL(fileURLWithPath: root), includingPropertiesForKeys: keys,
                                                  options: [.skipsHiddenFiles, .skipsPackageDescendants]) else {
            return
        }
        // Paths keep the root as given (the listing may say /private/var for /var).
        let resolvedRoot = realpath(root, nil).map { pointer in
            defer { free(pointer) }
            return String(cString: pointer)
        } ?? root
        for case let url as URL in walker {
            let values = try? url.resourceValues(forKeys: Set(keys))
            let name = url.lastPathComponent
            if values?.isDirectory == true {
                if Self.ignoredFolders.contains(name.lowercased()) { walker.skipDescendants() }
                continue
            }
            guard values?.isRegularFile == true, PhotoMedia.isImportable(name),
                  let size = values?.fileSize else { continue }
            var path = url.path
            if !path.hasPrefix(root + "/"), path.hasPrefix(resolvedRoot + "/") {
                path = root + path.dropFirst(resolvedRoot.count)
            }
            bySize[UInt64(size), default: []].append(path)
            fileCount += 1
        }
    }

    /// A file in the library with the same contents as `file`, if there is one.
    func copy(of file: String, hash: String) -> String? {
        guard let size = Self.size(of: file, fileManager: fileManager) else { return nil }
        for candidate in bySize[size] ?? [] {
            if hashes[candidate] == nil { hashes[candidate] = try? VerifiedCopy.sha256(of: candidate) }
            if hashes[candidate] == hash { return candidate }
        }
        return nil
    }

    /// Note a photo just filed, so a second copy later in the import is caught.
    func add(_ path: String, hash: String) {
        guard let size = Self.size(of: path, fileManager: fileManager) else { return }
        bySize[size, default: []].append(path)
        hashes[path] = hash
        fileCount += 1
    }

    private static func size(of path: String, fileManager: FileManager) -> UInt64? {
        ((try? fileManager.attributesOfItem(atPath: path))?[.size] as? NSNumber)?.uint64Value
    }
}

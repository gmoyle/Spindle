import Foundation

// MARK: - Import Media: folders and disc images ripped like discs

/// One thing found by Import Media, imported as if it were a disc.
enum ImportUnit: Equatable {
    /// A copied disc: a folder holding VIDEO_TS, BDMV or an HD DVD structure.
    case disc(path: String, kind: DiscKind)
    /// A disc image (.iso), mounted read-only and ripped like the disc.
    case image(path: String)
    /// A folder of plain files: photos (and camera clips), or anything else.
    case files(path: String, kind: DiscKind)

    var path: String {
        switch self {
        case .disc(let path, _), .image(let path), .files(let path, _): return path
        }
    }

    /// "DVD", "Disc image", "Photos", "Files".
    var kindName: String {
        switch self {
        case .disc(_, let kind): return kind.displayName
        case .image: return "Disc image"
        case .files(_, let kind): return kind == .photoDisc ? "Photos" : "Files"
        }
    }
}

/// Finds what to import under a folder the user picked.
enum MediaImportScanner {

    /// What a scan found, and the files it left alone.
    struct Result: Equatable {
        var units: [ImportUnit] = []
        /// Files beside disc folders or images, which aren't imported (pick
        /// their folder on its own to import them).
        var looseFiles = 0
    }

    static let imageExtensions: Set<String> = ["iso", "img", "cdr", "udf"]
    /// Folders that make their parent a disc.
    static let discFolderNames: Set<String> = ["VIDEO_TS", "BDMV", "HVDVD_TS"]

    static func scan(_ path: String, fileManager: FileManager = .default) -> Result {
        var isDir: ObjCBool = false
        guard fileManager.fileExists(atPath: path, isDirectory: &isDir) else { return Result() }
        if !isDir.boolValue {
            return isImage(path) ? Result(units: [.image(path: path)]) : Result()
        }
        // Picked the VIDEO_TS (or BDMV) folder itself: the disc is its parent.
        if discFolderNames.contains((path as NSString).lastPathComponent.uppercased()) {
            return scan((path as NSString).deletingLastPathComponent, fileManager: fileManager)
        }
        return scanFolder(path, fileManager: fileManager)
    }

    private static func scanFolder(_ folder: String, fileManager: FileManager) -> Result {
        if let kind = discKind(of: folder, fileManager: fileManager) {
            return Result(units: [.disc(path: folder, kind: kind)])
        }
        guard containsDiscs(folder, fileManager: fileManager) else {
            return filesUnit(folder, fileManager: fileManager).map { Result(units: [$0]) } ?? Result()
        }
        var result = Result()
        for name in children(of: folder, fileManager: fileManager) {
            let path = (folder as NSString).appendingPathComponent(name)
            var isDir: ObjCBool = false
            fileManager.fileExists(atPath: path, isDirectory: &isDir)
            if isDir.boolValue {
                let inner = scanFolder(path, fileManager: fileManager)
                result.units += inner.units
                result.looseFiles += inner.looseFiles
            } else if isImage(path) {
                result.units.append(.image(path: path))
            } else {
                result.looseFiles += 1
            }
        }
        return result
    }

    /// The kind of disc a folder holds, if it's a copied video disc.
    static func discKind(of folder: String, fileManager: FileManager = .default) -> DiscKind? {
        let kind = DiscClassifier.classify(volumeAt: folder, isOpticalMedia: { _ in false }, fileManager: fileManager)
        switch kind {
        case .dvd, .bluray, .bluray4K, .hddvd: return kind
        default: return nil
        }
    }

    /// A folder of plain files: photos if most of them are, else data.
    static func filesUnit(_ folder: String, fileManager: FileManager = .default) -> ImportUnit? {
        let (files, photos) = DiscClassifier.countFiles(under: folder, fileManager: fileManager)
        guard files > 0 else { return nil }
        let kind: DiscKind = Double(photos) / Double(files) >= DiscClassifier.photoShareThreshold
            ? .photoDisc : .dataDisc
        return .files(path: folder, kind: kind)
    }

    /// Whether any disc folder or disc image is somewhere under `folder`.
    static func containsDiscs(_ folder: String, fileManager: FileManager = .default) -> Bool {
        guard let walker = fileManager.enumerator(
            at: URL(fileURLWithPath: folder), includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return false }
        for case let url as URL in walker {
            if discFolderNames.contains(url.lastPathComponent.uppercased()) || isImage(url.path) { return true }
        }
        return false
    }

    static func isImage(_ path: String) -> Bool {
        imageExtensions.contains((path as NSString).pathExtension.lowercased())
    }

    private static func children(of folder: String, fileManager: FileManager) -> [String] {
        ((try? fileManager.contentsOfDirectory(atPath: folder)) ?? [])
            .filter { !$0.hasPrefix(".") && !MediaRipper.systemFolderNames.contains($0) }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    /// "2 DVDs, 1 disc image and 1 folder of photos".
    static func summary(of units: [ImportUnit]) -> String {
        var counts: [(String, Int)] = []
        for unit in units {
            let noun: String
            switch unit {
            case .disc(_, let kind): noun = kind.displayName
            case .image: noun = "disc image"
            case .files(_, let kind): noun = kind == .photoDisc ? "folder of photos" : "folder of other files"
            }
            if let index = counts.firstIndex(where: { $0.0 == noun }) {
                counts[index].1 += 1
            } else {
                counts.append((noun, 1))
            }
        }
        let parts = counts.map { noun, count -> String in
            guard count != 1 else { return "1 \(noun)" }
            if noun.hasPrefix("folder of") { return "\(count) folders of" + noun.dropFirst("folder of".count) }
            return "\(count) \(noun)s"
        }
        guard parts.count > 1 else { return parts.first ?? "nothing" }
        return parts.dropLast().joined(separator: ", ") + " and " + parts[parts.count - 1]
    }
}

/// The folders and mounted images being imported. Spindle treats each like a
/// disc in a drive, but nothing may touch a device for them: MakeMKV opens
/// them as files, libdvdcss only ever reads a mounted image's own device, and
/// "ejecting" one ends its import.
final class ImportSources {

    static let shared = ImportSources()

    struct Source: Equatable {
        /// Where it's read from: the folder, or the image's mount point.
        let mountPoint: String
        /// The mounted image's device (/dev/diskN); a placeholder for a folder.
        let devicePath: String
        /// The image file, when it is one.
        let imagePath: String?
    }

    /// Placeholder devices start with this, so they never name a real disk.
    static let folderDevicePrefix = "import:"

    /// Disc images are mounted under here (local, never synced), which also
    /// keeps the drive detector from taking them for inserted discs.
    static var mountRoot: String {
        AppIdentity.cachesDirectory.appendingPathComponent("import-mounts", isDirectory: true).path
    }

    private var sources: [String: Source] = [:]
    private let lock = NSLock()

    func add(_ source: Source) {
        lock.lock()
        sources[source.mountPoint] = source
        lock.unlock()
    }

    func remove(_ mountPoint: String) {
        lock.lock()
        sources[mountPoint] = nil
        lock.unlock()
    }

    func source(at mountPoint: String) -> Source? {
        lock.lock()
        defer { lock.unlock() }
        return sources[mountPoint]
    }

    func source(forDevice devicePath: String) -> Source? {
        lock.lock()
        defer { lock.unlock() }
        return sources.values.first { $0.devicePath == devicePath }
    }

    func contains(_ mountPoint: String) -> Bool { source(at: mountPoint) != nil }

    /// A folder (not a mounted image): there's no device to read at all.
    func isFolder(_ mountPoint: String) -> Bool {
        source(at: mountPoint).map { $0.imagePath == nil } ?? false
    }

    /// How makemkvcon opens an import: as files, never through a drive.
    func makeMKVSpec(for path: String) -> String? {
        contains(path) ? "file:\(path)" : nil
    }

    /// Paths under the import mount root are Spindle's own image mounts.
    static func isImportMount(_ path: String) -> Bool {
        path.hasPrefix(mountRoot + "/")
    }
}

/// Mounting a disc image read-only, out of the Finder's sight.
enum DiskImageMount {

    struct Mounted: Equatable {
        let mountPoint: String
        /// The whole image's device, to detach it by.
        let devicePath: String
    }

    enum MountError: LocalizedError {
        case failed(String)
        var errorDescription: String? {
            switch self {
            case .failed(let detail): return "Couldn't open the disc image: \(detail)"
            }
        }
    }

    /// Mount `image` at `<mountRoot>/<uuid>/<image name>`, so the rip is named
    /// after the image ("HEAT.iso" → HEAT).
    static func attach(_ image: String) throws -> Mounted {
        let label = ((image as NSString).lastPathComponent as NSString).deletingPathExtension
        let mountPoint = (ImportSources.mountRoot as NSString)
            .appendingPathComponent(UUID().uuidString + "/" + label)
        try FileManager.default.createDirectory(atPath: (mountPoint as NSString).deletingLastPathComponent,
                                                withIntermediateDirectories: true)
        let (status, output) = run(["attach", "-readonly", "-nobrowse", "-noautoopen", "-noverify",
                                    "-mountpoint", mountPoint, "-plist", image])
        guard status == 0, let mounted = parseAttach(output) else {
            try? FileManager.default.removeItem(atPath: (mountPoint as NSString).deletingLastPathComponent)
            throw MountError.failed("hdiutil couldn't mount \((image as NSString).lastPathComponent)")
        }
        return mounted
    }

    /// The mount point and whole-disk device from `hdiutil attach -plist`.
    static func parseAttach(_ data: Data) -> Mounted? {
        guard let plist = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any],
              let entities = plist["system-entities"] as? [[String: Any]] else { return nil }
        guard let mountPoint = entities.compactMap({ $0["mount-point"] as? String }).first,
              let device = entities.compactMap({ $0["dev-entry"] as? String })
                .min(by: { $0.count < $1.count }) else { return nil }
        return Mounted(mountPoint: mountPoint, devicePath: device)
    }

    /// Detach the image and remove its mount folder.
    static func detach(_ mounted: Mounted) {
        if run(["detach", mounted.devicePath]).status != 0 {
            _ = run(["detach", mounted.devicePath, "-force"])
        }
        try? FileManager.default.removeItem(atPath: (mounted.mountPoint as NSString).deletingLastPathComponent)
    }

    private static func run(_ arguments: [String]) -> (status: Int32, output: Data) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice  // warnings there would break the plist
        process.standardInput = FileHandle.nullDevice
        do { try process.run() } catch { return (-1, Data()) }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()  // drain before waiting
        process.waitUntilExit()
        return (process.terminationStatus, data)
    }
}

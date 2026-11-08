import Foundation

/// Any other data disc: copied as it is into `Imported Discs/<disc name>/`.
/// Phase 1 copies every file to local staging, checking each copy against the
/// disc; files that can't be read are listed in "Unreadable files.txt". Phase 2
/// moves the folder into the library after eject.
extension MediaRipper {

    enum DataDiscError: LocalizedError {
        case empty
        case unreadable

        var errorDescription: String? {
            switch self {
            case .empty: return "This disc has no files to import."
            case .unreadable: return "None of the files on this disc could be read."
            }
        }
    }

    /// Folders macOS and Windows put on a disc for themselves.
    static let systemFolderNames: Set<String> = [
        ".Spotlight-V100", ".fseventsd", ".Trashes", ".TemporaryItems", "System Volume Information",
        "$RECYCLE.BIN", "RECYCLER"
    ]

    /// Regular files to copy, as paths relative to `root`, with their total size.
    static func dataDiscFiles(under root: String,
                              fileManager: FileManager = .default) -> (files: [String], bytes: Int64) {
        guard let walker = fileManager.enumerator(
            at: URL(fileURLWithPath: root), includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles]) else { return ([], 0) }
        var files: [String] = []
        var bytes: Int64 = 0
        let base = URL(fileURLWithPath: root).standardizedFileURL.path
        for case let url as URL in walker {
            if systemFolderNames.contains(url.lastPathComponent) {
                walker.skipDescendants()
                continue
            }
            guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                  values.isRegularFile == true else { continue }
            let path = url.standardizedFileURL.path
            files.append(String(path.dropFirst(base.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/")))
            bytes += Int64(values.fileSize ?? 0)
        }
        return (files.sorted(), bytes)
    }

    func performDataDiscImport(discPath: String, configuration: RippingConfiguration) throws {
        let label = (discPath as NSString).lastPathComponent
        let (files, totalBytes) = Self.dataDiscFiles(under: discPath)
        guard !files.isEmpty else { throw DataDiscError.empty }
        delegate?.mediaRipperDidUpdateStatus("Copying \(files.count) files from \(label)...")

        let stagingRoot = AppIdentity.cachesDirectory
            .appendingPathComponent("encoding/disc-\(UUID().uuidString.prefix(8))", isDirectory: true).path
        stagingDirectoriesToRemove.append(stagingRoot)
        let folder = (stagingRoot as NSString).appendingPathComponent(MusicLibraryNaming.safe(label))
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)

        var copiedBytes: Int64 = 0
        var unreadable: [String] = []
        for relative in files {
            if shouldCancel { throw MediaRipperError.cancelled }
            let source = (discPath as NSString).appendingPathComponent(relative)
            let size = ((try? FileManager.default.attributesOfItem(atPath: source))?[.size] as? Int64) ?? 0
            do {
                try VerifiedCopy.copy(source, to: (folder as NSString).appendingPathComponent(relative))
            } catch {
                Logger.shared.log("Couldn't copy \(relative): \(error.localizedDescription)",
                                  level: .warning, category: .general)
                unreadable.append(relative)
            }
            copiedBytes += size
            delegate?.mediaRipperDidUpdateProgress(totalBytes > 0 ? Double(copiedBytes) / Double(totalBytes) : 0,
                                                   currentItem: nil, totalItems: files.count)
        }
        if unreadable.count == files.count { throw DataDiscError.unreadable }
        if !unreadable.isEmpty {
            let list = "These files on \(label) couldn't be read (the disc may be scratched):\n\n"
                + unreadable.joined(separator: "\n") + "\n"
            try? list.write(toFile: (folder as NSString).appendingPathComponent("Unreadable files.txt"),
                            atomically: true, encoding: .utf8)
        }
        let readSummary = "Data disc \(label): copied \(files.count - unreadable.count) of \(files.count) files"
        Logger.shared.log(readSummary, level: .info, category: .general)
        delegate?.mediaRipperDidUpdateStatus(readSummary)

        let root = configuration.outputDirectory
        let identity = DiscIdentity.compute(forDiscAt: discPath)
        postEjectWork = {
            guard !root.isEmpty else { throw ContentRouter.RouteError.moveFailed("No Imported Discs folder is set.") }
            let destination = try LibraryFiles.fileFolder(folder, into: root, discIdentity: identity)
            return PostEjectResult(files: [destination], location: destination,
                                   summary: "Imported \(label) into \(destination)")
        }
    }
}

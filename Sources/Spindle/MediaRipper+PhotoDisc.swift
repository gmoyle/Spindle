import Foundation

/// Photo discs (a camera card burned to CD, Kodak Picture CD, a "photos" DVD-R).
/// Phase 1 copies each photo and camera clip to local staging, checking each
/// copy against the disc, and drops duplicates of photos already imported; the
/// disc can then eject. Phase 2 files the copies by the date each was taken,
/// into the Photos folder as it's already laid out (`PhotoLibraryNaming`),
/// skipping photos already in it, and/or into Apple Photos.
extension MediaRipper {

    enum PhotoDiscError: LocalizedError {
        case noPhotos
        case unreadable(Int)

        var errorDescription: String? {
            switch self {
            case .noPhotos: return "No photos were found on this disc."
            case .unreadable(let count): return "None of the disc's \(count) photos could be read."
            }
        }
    }

    /// A photo copied off the disc, waiting to be filed.
    struct StagedPhoto: Equatable {
        let path: String
        let hash: String
        let date: Date?
    }

    func performPhotoDiscImport(discPath: String, configuration: RippingConfiguration) throws {
        let destination = configuration.photoDestination ?? .folder
        let index = PhotoIndex.shared
        let (media, skipped) = PhotoMedia.files(under: discPath)
        guard !media.isEmpty else { throw PhotoDiscError.noPhotos }
        let label = (discPath as NSString).lastPathComponent
        delegate?.mediaRipperDidUpdateStatus("Copying \(media.count) photos from \(label)...")

        let staging = AppIdentity.cachesDirectory
            .appendingPathComponent("encoding/photos-\(UUID().uuidString.prefix(8))", isDirectory: true).path
        stagingDirectoriesToRemove.append(staging)

        var staged: [StagedPhoto] = []
        var seen = Set<String>()
        var duplicates = 0
        var unreadable: [String] = []
        for (position, file) in media.enumerated() {
            if shouldCancel { throw MediaRipperError.cancelled }
            delegate?.mediaRipperDidUpdateProgress(Double(position) / Double(media.count),
                                                   currentItem: nil, totalItems: media.count)
            // Keep the disc's folders, so two IMG_0001.JPG don't collide in staging.
            let relative = file.hasPrefix(discPath)
                ? String(file.dropFirst(discPath.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                : "\(position)/" + (file as NSString).lastPathComponent
            let target = (staging as NSString).appendingPathComponent(relative)
            let hash: String
            do {
                hash = try VerifiedCopy.copy(file, to: target)
            } catch {
                Logger.shared.log("Couldn't copy \(relative): \(error.localizedDescription)",
                                  level: .warning, category: .general)
                unreadable.append(relative)
                continue
            }
            if seen.contains(hash) || Self.isAlreadyImported(hash, destination: destination, index: index) {
                duplicates += 1
                try? FileManager.default.removeItem(atPath: target)
                continue
            }
            seen.insert(hash)
            staged.append(StagedPhoto(path: target, hash: hash, date: PhotoMedia.captureDate(of: target)))
        }
        delegate?.mediaRipperDidUpdateProgress(1, currentItem: nil, totalItems: media.count)
        if staged.isEmpty, duplicates == 0, !unreadable.isEmpty { throw PhotoDiscError.unreadable(media.count) }

        let readSummary = "Photo disc \(label): \(media.count) photos and clips ("
            + Self.readNotes(new: staged.count, duplicates: duplicates, unreadable: unreadable.count,
                             skipped: skipped.count) + ")"
        Logger.shared.log(readSummary, level: .info, category: .general)
        delegate?.mediaRipperDidUpdateStatus(readSummary)

        let root = configuration.outputDirectory
        postEjectWork = {
            try Self.filePhotos(staged, destination: destination, root: root, index: index)
        }
    }

    static func readNotes(new: Int, duplicates: Int, unreadable: Int, skipped: Int) -> String {
        var notes = ["\(new) new"]
        if duplicates > 0 { notes.append("\(duplicates) already imported") }
        if unreadable > 0 { notes.append("\(unreadable) unreadable") }
        if skipped > 0 { notes.append("\(skipped) other files left on the disc") }
        return notes.joined(separator: ", ")
    }

    static func isAlreadyImported(_ hash: String, destination: PhotoDestination, index: PhotoIndex) -> Bool {
        (!destination.includesFolder || index.isInFolder(hash))
            && (!destination.includesApplePhotos || index.isInApplePhotos(hash))
    }

    /// File staged photos into the Photos folder by date and/or Apple Photos.
    /// If Apple Photos refuses (access denied) and it was the only destination,
    /// the photos go to the Photos folder instead so none are lost.
    static func filePhotos(_ photos: [StagedPhoto], destination: PhotoDestination, root: String,
                           index: PhotoIndex,
                           importToApplePhotos: ([String]) throws -> Void = ApplePhotosImporter.importFiles,
                           library: PhotoLibraryContents? = nil,
                           fileManager: FileManager = .default) throws -> PostEjectResult {
        var useFolder = destination.includesFolder
        var notes: [String] = []
        var addedToPhotos = 0

        if destination.includesApplePhotos {
            let toAdd = photos.filter { !index.isInApplePhotos($0.hash) }
            do {
                // In batches, so one huge change doesn't stall Photos.
                for start in stride(from: 0, to: toAdd.count, by: 100) {
                    let batch = Array(toAdd[start..<min(start + 100, toAdd.count)])
                    try importToApplePhotos(batch.map(\.path))
                    batch.forEach { index.record(hash: $0.hash, inApplePhotos: true) }
                    addedToPhotos += batch.count
                }
                if addedToPhotos > 0 { notes.append("\(addedToPhotos) added to Apple Photos") }
            } catch {
                index.save()
                notes.append("Apple Photos: \(error.localizedDescription)")
                if !useFolder {
                    useFolder = true
                    notes.append("filed in the Photos folder instead")
                }
            }
        }

        var filed: [String] = []
        if useFolder {
            guard !root.isEmpty else { throw ContentRouter.RouteError.moveFailed("No Photos folder is set.") }
            let toFile = photos.filter { !index.isInFolder($0.hash, fileManager: fileManager) }
            let (placed, alreadyThere) = try fileInFolder(toFile, root: root, index: index,
                                                         library: library, fileManager: fileManager)
            filed = placed
            notes.insert("\(filed.count) filed in \(root)", at: 0)
            if alreadyThere > 0 { notes.insert("\(alreadyThere) already in the library", at: 1) }
        }
        index.save()
        return PostEjectResult(files: filed, location: useFolder ? root : "Apple Photos",
                               summary: "Photos: " + notes.joined(separator: "; "))
    }

    /// File photos into the Photos folder the way it's already laid out,
    /// skipping any already in it under another name or date. Returns the
    /// files placed and how many were already there.
    static func fileInFolder(_ photos: [StagedPhoto], root: String, index: PhotoIndex,
                             library: PhotoLibraryContents?, fileManager: FileManager)
        throws -> (placed: [String], alreadyThere: Int) {
        guard !photos.isEmpty else { return ([], 0) }
        let layout = PhotoLibraryNaming.layout(of: root, fileManager: fileManager)
        let contents = library ?? PhotoLibraryContents(root: root, fileManager: fileManager)
        var placed: [String] = []
        var alreadyThere = 0
        for photo in photos {
            if let existing = contents.copy(of: photo.path, hash: photo.hash) {
                index.record(hash: photo.hash, path: existing)
                alreadyThere += 1
                continue
            }
            let wanted = PhotoLibraryNaming.path(for: photo.path, date: photo.date, in: root, layout: layout)
            try fileManager.createDirectory(atPath: (wanted as NSString).deletingLastPathComponent,
                                            withIntermediateDirectories: true)
            let target = PhotoLibraryNaming.freePath(wanted, layout: layout, fileManager: fileManager)
            let path = try LibraryFiles.placeFile(photo.path, at: target, replacing: false, fileManager: fileManager)
            index.record(hash: photo.hash, path: path)
            contents.add(path, hash: photo.hash)
            placed.append(path)
        }
        return (placed, alreadyThere)
    }
}

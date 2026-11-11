import Cocoa

/// What a disc's lookup found: the film (or album) it's ripped under.
struct DiscLookup {
    var title: String?
    var libraryName: String?
    var album: AlbumRelease?
}

/// Two drives read two discs at once. Each disc keeps its own lookup, and the
/// window shows every disc being read.
extension MainViewController {

    // MARK: - Lookups per disc

    /// Keep what the lookup for `drive`'s disc found.
    func rememberLookup(for drive: OpticalDrive) {
        discLookups[drive.mountPoint] = DiscLookup(
            title: resolvedDiscTitle, libraryName: resolvedLibraryName, album: resolvedAlbum)
    }

    /// Make `drive`'s disc the one the rip settings are built for, so a rip
    /// never takes the title of a disc in the other drive.
    func recallLookup(forDiscAt mountPoint: String) {
        guard let lookup = discLookups[mountPoint] else { return }
        resolvedDiscTitle = lookup.title
        resolvedLibraryName = lookup.libraryName
        resolvedAlbum = lookup.album
    }

    // MARK: - Reading progress

    /// A disc's size from a reader's status line: "Reading N sectors for title
    /// X via libdvdcss...".
    static func discBytes(inStatus status: String) -> Int64? {
        guard status.contains("sectors for title"), status.contains("via libdvdcss") else { return nil }
        let parts = status.components(separatedBy: " ")
        guard let idx = parts.firstIndex(of: "Reading"), idx + 1 < parts.count,
              let sectors = Int64(parts[idx + 1]) else { return nil }
        return sectors * 2048
    }

    /// The progress line for the discs being read: sizes for one disc,
    /// "A 40% · B 12%" for several.
    static func readingLine(titles: [String], progress: [Double], sizes: [Int64?],
                            formatBytes: (Int64) -> String) -> String {
        if titles.count == 1, let pct = progress.first {
            if let first = sizes.first, let size = first, size > 0 {
                return "\(formatBytes(Int64(Double(size) * pct))) / \(formatBytes(size))  (\(Int(pct * 100))%)"
            }
            return pct > 0 ? "\(Int(pct * 100))%" : "Reading disc..."
        }
        return zip(titles, progress).map { "\($0) \(Int($1 * 100))%" }.joined(separator: " · ")
    }

    /// Show the reading discs' progress: the bar is their average.
    func showReadingProgress() {
        guard !readingJobIds.isEmpty else { return }
        let progress = readingJobIds.map { min(max(readProgress[$0] ?? 0, 0), 1) }
        let titles = readingJobIds.map { conversionQueue.getJob(id: $0)?.discTitle ?? "Disc" }
        progressIndicator.isHidden = false
        progressStatusLabel.isHidden = false
        progressIndicator.doubleValue = progress.reduce(0, +) / Double(progress.count) * 100
        progressStatusLabel.stringValue = Self.readingLine(
            titles: titles, progress: progress, sizes: readingJobIds.map { readSizes[$0] },
            formatBytes: formatBytes)
    }

    /// A status line for the log, named after its disc while several are read.
    func logLine(_ status: String, forJob jobId: UUID) -> String {
        guard readingJobIds.count > 1 || (!readingJobIds.isEmpty && !readingJobIds.contains(jobId)),
              let title = conversionQueue.getJob(id: jobId)?.discTitle else { return status }
        return "[\(title)] \(status)"
    }

    // MARK: - Cancelling

    /// Cancel Rip: with one disc being read, cancel it; with several, ask
    /// which with a menu under the button.
    func cancelReading() {
        guard readingJobIds.count > 1 else {
            cancelReadingJobs(readingJobIds)
            return
        }
        let menu = NSMenu()
        for id in readingJobIds {
            let item = NSMenuItem(title: "Cancel \(conversionQueue.getJob(id: id)?.discTitle ?? "Disc")",
                                  action: #selector(cancelReadingFromMenu(_:)), keyEquivalent: "")
            item.representedObject = [id]
            item.target = self
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let all = NSMenuItem(title: "Cancel All", action: #selector(cancelReadingFromMenu(_:)), keyEquivalent: "")
        all.representedObject = readingJobIds
        all.target = self
        menu.addItem(all)
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: ripButton.bounds.height + 4), in: ripButton)
    }

    @objc private func cancelReadingFromMenu(_ sender: NSMenuItem) {
        cancelReadingJobs(sender.representedObject as? [UUID] ?? [])
    }

    func cancelReadingJobs(_ ids: [UUID]) {
        guard !ids.isEmpty else {
            appendToLog("No active rip to cancel.")
            resetRipUI()
            return
        }
        for id in ids {
            appendToLog("Cancelling \(conversionQueue.getJob(id: id)?.discTitle ?? "rip")...")
            conversionQueue.cancelJob(id: id)
        }
    }
}

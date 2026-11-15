import Cocoa

/// One line at the top of the window for each disc in a drive:
/// "Better Off Dead (DVD) - Reading disc… 40%", with a Cancel beside it while
/// that disc has a rip under way.
struct DiscStatusLine: Equatable {
    let mountPoint: String
    let text: String
    /// The disc's rip, while it can be cancelled.
    let jobId: UUID?

    /// A line per drive, in drive order. `titles` are the looked-up titles by
    /// mount point, `names` the films picked for a rip (which win);
    /// `idleStatus` is shown for a disc with no rip under way.
    static func lines(drives: [OpticalDrive], jobs: [ConversionQueue.ConversionJob],
                      titles: [String: String], names: [UUID: String] = [:], readProgress: [UUID: Double],
                      idleStatus: String) -> [DiscStatusLine] {
        drives.map { drive in
            let job = jobs.last { $0.sourcePath == drive.mountPoint && DiscListRow.isActive($0.status) }
            let title = job.flatMap { names[$0.id] } ?? titles[drive.mountPoint] ?? job?.discTitle ?? drive.name
            let status = job.map { phase(of: $0, progress: readProgress[$0.id]) } ?? idleStatus
            return DiscStatusLine(mountPoint: drive.mountPoint,
                                  text: "\(title) (\(drive.type.displayName)) - \(status)",
                                  jobId: job?.id)
        }
    }

    private static func phase(of job: ConversionQueue.ConversionJob, progress: Double?) -> String {
        switch job.status {
        case .pending:
            return "Waiting to rip"
        case .extracting:
            let pct = Int(min(max(progress ?? job.progress, 0), 1) * 100)
            return pct > 0 ? "Reading disc… \(pct)%" : "Reading disc…"
        default:
            return job.mediaType == .photoDisc || job.mediaType == .dataDisc ? "Filing…" : "Encoding…"
        }
    }
}

extension MainViewController {

    /// The lines at the top: "No disc detected" when the drives are empty,
    /// otherwise one per disc.
    func setupDiscLines() {
        discLinesStack = NSStackView(views: [sourceLabel])
        discLinesStack.orientation = .vertical
        discLinesStack.alignment = .leading
        discLinesStack.spacing = 4
        discLinesStack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(discLinesStack)
    }

    /// Show a line per disc in a drive, each with its own Cancel while it rips.
    func reloadDiscLines() {
        guard let stack = discLinesStack else { return }
        var titles = discLookups.compactMapValues { $0.title }
        if detectedDrives.count == 1, let drive = detectedDrives.first, titles[drive.mountPoint] == nil {
            titles[drive.mountPoint] = resolvedDiscTitle
        }
        let lines = DiscStatusLine.lines(drives: detectedDrives, jobs: queueJobs, titles: titles,
                                         names: chosenFilmNames, readProgress: readProgress,
                                         idleStatus: idleDiscStatus)
        sourceLabel.isHidden = !lines.isEmpty
        let rows = stack.arrangedSubviews.filter { $0 !== sourceLabel }
        let sameShape = lines.map { [$0.mountPoint, $0.jobId?.uuidString ?? ""] }
            == shownDiscLines.map { [$0.mountPoint, $0.jobId?.uuidString ?? ""] }
        if sameShape, rows.count == lines.count {
            for (row, line) in zip(rows, lines) {
                ((row as? NSStackView)?.arrangedSubviews.first as? NSTextField)?.stringValue = line.text
            }
        } else {
            rows.forEach { $0.removeFromSuperview() }
            for (index, line) in lines.enumerated() { stack.addArrangedSubview(discLineRow(line, index: index)) }
        }
        shownDiscLines = lines
    }

    private func discLineRow(_ line: DiscStatusLine, index: Int) -> NSView {
        let label = NSTextField(labelWithString: line.text)
        label.lineBreakMode = .byTruncatingTail
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        var views: [NSView] = [label]
        if line.jobId != nil {
            let button = NSButton(title: "Cancel", target: self, action: #selector(cancelDiscLine(_:)))
            button.bezelStyle = .rounded
            button.controlSize = .small
            button.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
            button.tag = index
            views.append(button)
        }
        let row = NSStackView(views: views)
        row.orientation = .horizontal
        row.alignment = .firstBaseline
        row.spacing = 8
        return row
    }

    @objc func cancelDiscLine(_ sender: NSButton) {
        guard sender.tag >= 0, sender.tag < shownDiscLines.count,
              let id = shownDiscLines[sender.tag].jobId else { return }
        cancelReadingJobs([id])
    }
}

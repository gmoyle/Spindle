import Cocoa

// MARK: - Embedded Queue Table

/// One row of the Discs list: a disc in a drive that isn't being ripped, or a
/// rip (reading, queued, encoding, finished) with its Cancel button.
struct DiscListRow: Equatable {
    /// The disc's volume label ("BOFFDEAD").
    let disc: String
    /// What it's ripped as ("Better Off Dead (1985)").
    let title: String
    let status: String
    let progress: String
    let duration: String
    /// The rip, if there is one.
    let jobId: UUID?
    let canCancel: Bool
    let failed: Bool

    /// Discs in a drive with no rip under way first, then every rip, newest first.
    static func rows(drives: [OpticalDrive], jobs: [ConversionQueue.ConversionJob]) -> [DiscListRow] {
        let ordered = MainViewController.newestFirst(jobs)
        let ripping = Set(ordered.filter { isActive($0.status) }.map(\.sourcePath))
        let idle = drives.filter { !ripping.contains($0.mountPoint) }.map { drive in
            DiscListRow(disc: label(drive.mountPoint), title: drive.name,
                        status: "In drive (\(drive.type.displayName))", progress: "—", duration: "",
                        jobId: nil, canCancel: false, failed: false)
        }
        return idle + ordered.map { job in
            DiscListRow(disc: label(job.sourcePath), title: job.discTitle, status: job.statusDescription,
                        progress: progressText(job), duration: job.formattedDuration, jobId: job.id,
                        canCancel: isActive(job.status), failed: isFailed(job.status))
        }
    }

    static func isActive(_ status: ConversionQueue.JobStatus) -> Bool {
        switch status {
        case .pending, .extracting, .extracted, .converting: return true
        default: return false
        }
    }

    private static func isFailed(_ status: ConversionQueue.JobStatus) -> Bool {
        if case .failed = status { return true }
        return false
    }

    private static func label(_ path: String) -> String { (path as NSString).lastPathComponent }

    private static func progressText(_ job: ConversionQueue.ConversionJob) -> String {
        switch job.status {
        case .extracting, .converting: return "\(Int(job.progress * 100))%"
        case .completed: return "100%"
        default: return "—"
        }
    }
}

// MARK: - Discs list

extension MainViewController: NSTableViewDataSource, NSTableViewDelegate {

    /// Rebuild the Discs list from the drives and the queue.
    func reloadDiscList() {
        discRows = DiscListRow.rows(drives: detectedDrives, jobs: queueJobs)
        queueTableView?.reloadData()
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        return discRows.count
    }

    func tableView(_ tableView: NSTableView,
                   viewFor tableColumn: NSTableColumn?,
                   row: Int) -> NSView? {
        guard row < discRows.count, let columnId = tableColumn?.identifier.rawValue else { return nil }
        let item = discRows[row]
        if columnId == "cancel" { return cancelButton(for: item, row: row) }

        let text: String
        switch columnId {
        case "disc": text = item.disc
        case "title": text = item.title
        case "status": text = item.status
        case "progress": text = item.progress
        case "duration": text = item.duration
        default: text = ""
        }

        let cellId = NSUserInterfaceItemIdentifier("queueCell_\(columnId)")
        let cell: NSTableCellView
        if let reused = tableView.makeView(withIdentifier: cellId, owner: nil) as? NSTableCellView {
            cell = reused
        } else {
            cell = NSTableCellView()
            cell.identifier = cellId
            let field = NSTextField(labelWithString: "")
            field.font = NSFont.systemFont(ofSize: 12)
            field.lineBreakMode = .byTruncatingTail
            field.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(field)
            cell.textField = field
            NSLayoutConstraint.activate([
                field.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
                field.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -2),
                field.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
            ])
        }
        cell.textField?.stringValue = text
        cell.textField?.toolTip = text
        cell.textField?.textColor = item.failed && columnId == "status" ? .systemRed : .labelColor
        return cell
    }

    /// The row's Cancel button: only a rip that's queued, reading or encoding
    /// has one.
    private func cancelButton(for item: DiscListRow, row: Int) -> NSView? {
        guard item.canCancel else { return nil }
        let button = NSButton(title: "Cancel", target: self, action: #selector(cancelDiscRow(_:)))
        button.bezelStyle = .rounded
        button.controlSize = .small
        button.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        button.tag = row
        button.toolTip = "Stop ripping \(item.title)"
        return button
    }

    @objc func cancelDiscRow(_ sender: NSButton) {
        guard sender.tag >= 0, sender.tag < discRows.count, let id = discRows[sender.tag].jobId,
              let job = conversionQueue.getJob(id: id), DiscListRow.isActive(job.status) else { return }
        appendToLog("Cancelling \(job.discTitle)...")
        conversionQueue.cancelJob(id: id)
    }

    // MARK: Context menu

    internal func makeQueueContextMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Cancel Job", action: #selector(queueCancelJob(_:)), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Retry Job", action: #selector(queueRetryJob(_:)), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Reveal in Finder", action: #selector(queueRevealInFinder(_:)), keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Remove from List", action: #selector(queueRemoveJob(_:)), keyEquivalent: ""))
        for item in menu.items { item.target = self }
        menu.delegate = self
        return menu
    }

    private var clickedQueueJob: ConversionQueue.ConversionJob? {
        let row = queueTableView.clickedRow
        guard row >= 0, row < discRows.count, let id = discRows[row].jobId else { return nil }
        return queueJobs.first { $0.id == id }
    }

    @objc private func queueCancelJob(_ sender: Any) {
        guard let job = clickedQueueJob else { return }
        conversionQueue.cancelJob(id: job.id)
        appendToLog("Cancelled job: \(job.discTitle)")
    }

    @objc private func queueRetryJob(_ sender: Any) {
        guard let job = clickedQueueJob else { return }
        conversionQueue.retryJob(id: job.id)
        appendToLog("Retrying job: \(job.discTitle)")
    }

    @objc private func queueRevealInFinder(_ sender: Any) {
        guard let job = clickedQueueJob else { return }
        if let file = job.outputFiles.first {
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: file)])
        } else {
            NSWorkspace.shared.activateFileViewerSelecting(
                [URL(fileURLWithPath: job.outputDirectory)]
            )
        }
    }

    @objc private func queueRemoveJob(_ sender: Any) {
        guard let job = clickedQueueJob else { return }
        conversionQueue.removeJob(id: job.id)
    }
}

extension MainViewController: NSMenuDelegate {

    // Enable only the actions that make sense for the clicked job's state.
    func menuNeedsUpdate(_ menu: NSMenu) {
        guard let job = clickedQueueJob else {
            for item in menu.items { item.isEnabled = false }
            return
        }
        menu.autoenablesItems = false
        for item in menu.items {
            switch item.action {
            case #selector(queueCancelJob(_:)):
                switch job.status {
                case .pending, .extracting, .extracted, .converting: item.isEnabled = true
                default: item.isEnabled = false
                }
            case #selector(queueRetryJob(_:)):
                switch job.status {
                case .failed, .cancelled: item.isEnabled = true
                default: item.isEnabled = false
                }
            case #selector(queueRemoveJob(_:)):
                switch job.status {
                case .extracting, .extracted, .converting: item.isEnabled = false
                default: item.isEnabled = true
                }
            case #selector(queueRevealInFinder(_:)):
                item.isEnabled = true
            default:
                break
            }
        }
    }
}

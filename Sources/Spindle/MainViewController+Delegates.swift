import Cocoa

// MARK: - DVDRipperDelegate

extension MainViewController: DVDRipperDelegate {

    func ripperDidStart() {
        DispatchQueue.main.async {
            self.appendToLog("DVD ripper started")
        }
    }

    func ripperDidUpdateStatus(_ status: String) {
        DispatchQueue.main.async {
            self.appendToLog(status)
        }
    }

    func ripperDidUpdateProgress(_ progress: Double, currentTitle: DVDTitle?, totalTitles: Int) {
        DispatchQueue.main.async {
            self.progressIndicator.doubleValue = progress * 100.0

            if let title = currentTitle {
                self.appendToLog("Processing title \(title.number) - \(Int(progress * 100))% complete")
            }
        }
    }

    func ripperDidComplete() {
        DispatchQueue.main.async {
            self.appendToLog("DVD ripping completed successfully!")
            self.activeMediaRipper = nil
            self.resetRipUI()

            // Show completion notification
            self.showCompletionNotification()

            // Automatically eject if enabled
            if self.settingsManager.autoEjectEnabled {
                self.appendToLog("Auto-ejecting disc...")
                self.ejectCurrentDisk()
            } else {
                self.appendToLog("Ripping complete. Disc ready for manual ejection.")
            }
        }
    }

    func ripperDidFail(with error: Error) {
        DispatchQueue.main.async {
            self.appendToLog("Error: \(error.localizedDescription)")
            self.activeMediaRipper = nil
            self.resetRipUI()

            // Show error notification
            self.showErrorNotification("Ripping failed: \(error.localizedDescription)")

            self.showAlert(title: "Ripping Failed", message: error.localizedDescription)
        }
    }
}

// MARK: - MediaRipperDelegate

extension MainViewController: MediaRipperDelegate {

    func mediaRipperDidStart() {
        DispatchQueue.main.async {
            self.appendToLog("Media ripper started")
        }
    }
    
    func mediaRipperDidUpdateStatus(_ status: String) {
        DispatchQueue.main.async {
            self.appendToLog(status)
            // Capture total size from extraction status: "Reading N sectors for title X via libdvdcss..."
            if status.contains("sectors for title") && status.contains("via libdvdcss") {
                let parts = status.components(separatedBy: " ")
                if let idx = parts.firstIndex(of: "Reading"), idx + 1 < parts.count,
                   let sectors = Int64(parts[idx + 1]) {
                    self.totalRipSizeBytes = sectors * 2048
                }
            }
        }
    }

    func mediaRipperDidUpdateProgress(_ progress: Double, currentItem: MediaRipper.MediaItem?, totalItems: Int) {
        DispatchQueue.main.async {
            let pct = min(max(progress, 0), 1)
            self.progressIndicator.doubleValue = pct * 100.0

            if self.totalRipSizeBytes > 0 {
                let done = Int64(Double(self.totalRipSizeBytes) * pct)
                let doneStr = self.formatBytes(done)
                let totalStr = self.formatBytes(self.totalRipSizeBytes)
                self.progressStatusLabel.stringValue = "\(doneStr) / \(totalStr)  (\(Int(pct * 100))%)"
            } else if pct > 0 {
                self.progressStatusLabel.stringValue = "\(Int(pct * 100))%"
            }
        }
    }

    internal func formatBytes(_ bytes: Int64) -> String {
        let gb = Double(bytes) / 1_073_741_824
        if gb >= 1 { return String(format: "%.2f GB", gb) }
        let mb = Double(bytes) / 1_048_576
        return String(format: "%.1f MB", mb)
    }

    func mediaRipperDidComplete() {
        DispatchQueue.main.async {
            self.appendToLog("Media ripping completed successfully!")
            self.activeMediaRipper = nil
            self.resetRipUI()
            
            // Show completion notification
            self.showCompletionNotification()
            
            // Automatically eject if enabled
            if self.settingsManager.autoEjectEnabled {
                self.appendToLog("Auto-ejecting disc...")
                self.ejectCurrentDisk()
            } else {
                self.appendToLog("Ripping complete. Disc ready for manual ejection.")
            }
        }
    }
    
    func mediaRipperDidFail(with error: Error) {
        DispatchQueue.main.async {
            self.appendToLog("Error: \(error.localizedDescription)")
            self.activeMediaRipper = nil
            self.resetRipUI()

            // Show error notification
            self.showErrorNotification("Ripping failed: \(error.localizedDescription)")

            // A licensing refusal is recoverable — walk the user through getting
            // a key instead of showing a dead-end error alert.
            if case MakeMKVBackend.MakeMKVError.registrationRequired(let detail) = error {
                self.presentMakeMKVRegistrationOptions(detail: detail)
                return
            }

            self.showAlert(title: "Ripping Failed", message: error.localizedDescription)
        }
    }
}

// MARK: - ConversionQueueDelegate (main-window live status for queue-driven rips)

extension MainViewController: ConversionQueueDelegate {

    func queueDidUpdateJobs(_ jobs: [ConversionQueue.ConversionJob]) {
        queueJobs = Self.newestFirst(jobs)
        queueTableView.reloadData()
    }

    /// The queue table lists the most recently added job first. Ties (jobs added
    /// in the same instant) keep the queue's order, reversed.
    static func newestFirst(_ jobs: [ConversionQueue.ConversionJob]) -> [ConversionQueue.ConversionJob] {
        jobs.enumerated()
            .sorted { lhs, rhs in
                lhs.element.addedTime != rhs.element.addedTime
                    ? lhs.element.addedTime > rhs.element.addedTime
                    : lhs.offset > rhs.offset
            }
            .map(\.element)
    }

    func queueDidStartExtraction(jobId: UUID) {
        if !readingJobIds.contains(jobId) { readingJobIds.append(jobId) }
        readProgress[jobId] = 0
        queueEncodePhase = false
        totalRipSizeBytes = 0
        showReadingProgress()
        // Keep the button live as a Cancel control so the user can stop a rip in
        // progress (queue-driven rips, i.e. all Blu-ray, had no cancel before).
        ripButton.isEnabled = true
        ripButton.title = "Cancel Rip"
        queueRipInProgress = true
        setDiscStatus(readingJobIds.count > 1 ? "Reading \(readingJobIds.count) discs…" : "Reading disc…")
    }

    /// `jobId` no longer reads a disc. Returns true when another disc still is,
    /// so the window keeps showing that read.
    private func stopReading(_ jobId: UUID) -> Bool {
        readingJobIds.removeAll { $0 == jobId }
        readProgress[jobId] = nil
        readSizes[jobId] = nil
        guard !readingJobIds.isEmpty else { return false }
        showReadingProgress()
        setDiscStatus(readingJobIds.count > 1 ? "Reading \(readingJobIds.count) discs…" : "Reading disc…")
        return true
    }

    func queueDidCompleteExtraction(jobId: UUID) {
        // The disc read (the cancellable part) is done; encoding is background and
        // safe to eject. Clear the cancel state and reset the button label,
        // unless the other drive is still reading.
        appendToLog(logLine("Disc read complete — safe to eject. Encoding continues in background.", forJob: jobId))
        if stopReading(jobId) { return }
        queueRipInProgress = false
        progressStatusLabel.isHidden = false
        progressStatusLabel.stringValue = "Disc read complete — encoding in background..."
        setDiscStatus("Encoding…")
        ripButton.title = "Start Ripping"
    }

    func queueDidFailExtraction(jobId: UUID, error: Error) {
        dropTitleChoice(forJob: jobId)
        appendToLog(logLine("Rip failed: \(error.localizedDescription)", forJob: jobId))
        showErrorNotification("Ripping failed: \(error.localizedDescription)")
        if !stopReading(jobId) {
            queueRipInProgress = false
            resetRipUI()
        }
        if case MakeMKVBackend.MakeMKVError.registrationRequired(let detail) = error {
            presentMakeMKVRegistrationOptions(detail: detail)
        }
    }

    func queueDidStartConversion(jobId: UUID) {
        // Another disc is being read: its progress owns the UI until it finishes.
        guard extractingJobId == nil else { return }
        queueEncodePhase = true
        progressIndicator.doubleValue = 0
        progressStatusLabel.isHidden = false
        progressStatusLabel.stringValue = phase2Label(forJob: jobId) + "..."
        setDiscStatus(isCopyOnly(jobId) ? "Filing…" : "Encoding…")
    }

    /// "Encoding to FLAC" for a music CD, "Encoding to MKV" for video,
    /// "Filing into the library" for photo and data discs (nothing to encode).
    private func phase2Label(forJob jobId: UUID) -> String {
        if isCopyOnly(jobId) { return "Filing into the library" }
        return conversionQueue.getJob(id: jobId)?.mediaType == .audioCD ? "Encoding to FLAC" : "Encoding to MKV"
    }

    private func isCopyOnly(_ jobId: UUID) -> Bool {
        let kind = conversionQueue.getJob(id: jobId)?.mediaType
        return kind == .photoDisc || kind == .dataDisc
    }

    func queueDidCompleteConversion(jobId: UUID, outputFiles: [String]) {
        noteFinishedJobForTitleChoice(jobId: jobId, outputFiles: outputFiles)
        // A photo disc can bring hundreds of files; list a few.
        let shown = outputFiles.count > 12 ? Array(outputFiles.prefix(5)) : outputFiles
        for file in shown {
            appendToLog("Finished: \(file)")
        }
        if shown.count < outputFiles.count {
            appendToLog("…and \(outputFiles.count - shown.count) more.")
        }
        showCompletionNotification()
        if extractingJobId == nil { resetRipUI() }
    }

    func queueDidFailConversion(jobId: UUID, error: Error) {
        dropTitleChoice(forJob: jobId)
        appendToLog("Encoding failed: \(error.localizedDescription)")
        showErrorNotification("Encoding failed: \(error.localizedDescription)")
        if extractingJobId == nil { resetRipUI() }
    }

    func queueDidUpdateConversionStatus(jobId: UUID, status: String) {
        if let bytes = Self.discBytes(inStatus: status) { readSizes[jobId] = bytes }
        appendToLog(logLine(status, forJob: jobId))
    }

    func queueDidUpdateConversionProgress(jobId: UUID, progress: Double) {
        // While discs are being read, show only their progress (not other jobs' encodes).
        if readingJobIds.contains(jobId) {
            readProgress[jobId] = progress
            showReadingProgress()
            return
        }
        guard readingJobIds.isEmpty else { return }
        if progressIndicator.isHidden {
            progressIndicator.isHidden = false
            progressStatusLabel.isHidden = false
        }
        // Encode progress: a percentage of the title's runtime, not disc bytes
        let pct = min(max(progress, 0), 1)
        progressIndicator.doubleValue = pct * 100.0
        progressStatusLabel.stringValue = phase2Label(forJob: jobId) + "... \(Int(pct * 100))%"
    }
}

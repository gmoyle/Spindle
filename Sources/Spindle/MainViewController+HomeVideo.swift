import AppKit

/// Home videos on pressed discs, and naming a video disc as a film.
extension MainViewController {

    /// Check a pressed DVD for the signs of a home-made disc (no copy
    /// protection, no region lock), off the main thread. Calls back on the main
    /// thread. Recordable discs never get here: they're home videos already.
    func checkForHomeMadeDisc(_ drive: OpticalDrive, completion: @escaping (Bool) -> Void) {
        guard !testingUtils.isRunningInTestEnvironment else {
            completion(false)
            return
        }
        DispatchQueue.global(qos: .userInitiated).async {
            let signs = HomeMadeDiscCheck.signs(mountPoint: drive.mountPoint, devicePath: drive.devicePath)
            let protection = signs.scrambled.map { $0 ? "yes" : "no" } ?? "unknown"
            let region = signs.regionMask.map { String(format: "0x%02X", $0) } ?? "unknown"
            Logger.shared.log("\(drive.name): copy protection \(protection), region mask \(region)",
                              level: .info, category: .general)
            DispatchQueue.main.async { completion(signs.looksHomeMade) }
        }
    }

    /// Import the disc in `drive` as a home video: every recording, filed by
    /// date in Home Videos, with no film lookup.
    func importAsHomeVideo(_ drive: OpticalDrive, reason: String) {
        homeVideoMounts.insert(drive.mountPoint)
        appendToLog(reason)
        autoStartRipping(for: drive)
    }

    /// Name a video disc as a film: a generic label rips under a placeholder,
    /// any other is looked up. A home-made disc (`homeVideoIfUnfound`) whose
    /// label names no film for sure is a home video instead: "4TH2015" only
    /// half-matches a concert film.
    func identifyFilm(on drive: OpticalDrive, homeVideoIfUnfound: Bool) {
        // A label like DVD_VIDEO names the format, not the film: searching it
        // only finds unrelated titles. Rip under a placeholder and ask.
        let rawLabel = (drive.mountPoint as NSString).lastPathComponent
        if DiscTitleQuery.isGenericLabel(rawLabel) {
            if homeVideoIfUnfound {
                importAsHomeVideo(drive, reason: "\(drive.name) has no copy protection or region lock and its label "
                                  + "names no film: importing it as a home video.")
                return
            }
            let placeholder = DiscTitleQuery.placeholderName()
            resolvedDiscTitle = placeholder
            rememberLookup(for: drive)
            updateDriveDropdown()
            autoStartRipping(for: drive)
            askWhichFilm(forGenericLabelDisc: drive, placeholder: placeholder)
            return
        }
        lookupDiscTitle(volumeName: drive.name) { resolution in
            if homeVideoIfUnfound, resolution?.isConfident != true {
                self.importAsHomeVideo(drive, reason: "No film called \(drive.name) was found for sure, and the disc "
                                       + "has no copy protection or region lock: importing it as a home video.")
                return
            }
            // Nothing found for a film's label: rip under the label as a film
            // name and ask. A TV disc keeps its label ("FIREFLY_D1"), so its
            // discs don't share a folder.
            let unfoundName = Self.unfoundRipName(forLabel: drive.name)
            let title = resolution?.best.displayName ?? unfoundName
            self.resolvedDiscTitle = title
            self.resolvedLibraryName = resolution?.best.libraryName
            self.rememberLookup(for: drive)
            self.updateDriveDropdown()
            if let resolution = resolution, let t = title {
                self.appendToLog(resolution.isConfident ? "Disc identified: \(t)" : "Disc might be \(t) (not sure)")
            }
            self.autoStartRipping(for: drive)
            if let resolution = resolution {
                self.askWhichFilm(for: drive, resolution: resolution)
            } else if let name = unfoundName {
                self.askWhichFilm(forUnfoundDisc: drive, ripName: name)
            }
        }
    }

    /// "It's a Home Video" in the "Which film is this?" window. While the disc
    /// is still being read, the film rip (one title) is cancelled and the disc
    /// is ripped again as a home video (every recording). Once it's read, the
    /// finished rip is moved into Home Videos instead.
    func fileAsHomeVideo(_ choice: TitleChoice) {
        guard let jobId = choice.jobId, let job = conversionQueue.getJob(id: jobId) else { return }
        let reading = job.status == .pending || job.status == .extracting
        if reading, let drive = detectedDrives.first(where: { $0.mountPoint == job.sourcePath }) {
            dropTitleChoice(choice)
            conversionQueue.cancelJob(id: jobId)
            importAsHomeVideo(drive, reason: "Ripping \(choice.discName) again as a home video, "
                              + "with every recording on it.")
            return
        }
        choice.homeVideo = true
        appendToLog("\(choice.discName) will be filed in Home Videos when its rip finishes.")
        applyTitleChoiceIfReady(choice)
    }

    /// Move a finished rip into Home Videos, off the main thread.
    func fileFinishedRipAsHomeVideo(folder: String, discName: String) {
        let root = settingsManager.libraryRoot(.homeVideos)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let info = HomeVideoFiler.info(forRipIn: folder, label: discName)
            let result = Result { try HomeVideoFiler.file(folder: folder, as: info, into: root) }
            DispatchQueue.main.async {
                switch result {
                case .success(let destination):
                    self?.appendToLog("Filed \(discName) in Home Videos: \(destination)")
                case .failure(let error):
                    self?.appendToLog("Couldn't file \(discName) in Home Videos: \(error.localizedDescription)")
                    Logger.shared.logError(error, context: "Filing \(folder) as a home video")
                }
            }
        }
    }
}

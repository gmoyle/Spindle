import Cocoa

/// "Import Media…": pick a drive or folder (or disc images) and Spindle imports
/// what it finds as if each were a disc in a drive: copied DVD, Blu-ray and HD
/// DVD folders and disc images are ripped, looked up and filed; folders of
/// photos are filed by date; other files are copied into Imported Discs.
/// One import is read at a time, beside any real discs.
extension MainViewController {

    @objc func importMedia() {
        guard !ripsFolder.isEmpty else {
            showAlert(title: "Choose a Rips Folder First",
                      message: "Set a Rips Folder in Settings, then import again.")
            return
        }
        guard !testingUtils.isRunningInTestEnvironment, let window = view.window else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = true
        panel.prompt = "Import"
        panel.message = "Choose a drive or folder (or disc images). Spindle imports copied DVDs and Blu-rays, "
            + "disc images, photos and other files as if each were a disc."
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK else { return }
            self?.scanForImport(panel.urls.map(\.path))
        }
    }

    /// Look for things to import under `paths` (off the main thread: a big
    /// drive takes a while), then ask before importing them.
    func scanForImport(_ paths: [String]) {
        let names = paths.map { ($0 as NSString).lastPathComponent }.joined(separator: ", ")
        appendToLog("Looking for discs, disc images and photos in \(names)...")
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var found = MediaImportScanner.Result()
            for path in paths {
                let result = MediaImportScanner.scan(path)
                found.units += result.units
                found.looseFiles += result.looseFiles
            }
            DispatchQueue.main.async { self?.confirmImport(found) }
        }
    }

    func confirmImport(_ found: MediaImportScanner.Result) {
        guard !found.units.isEmpty else {
            showAlert(title: "Nothing to Import",
                      message: "No copied discs, disc images, photos or other files were found there.")
            return
        }
        let summary = MediaImportScanner.summary(of: found.units)
        let alert = NSAlert()
        alert.messageText = "Import \(summary)?"
        alert.informativeText = Self.importDetails(found)
        alert.addButton(withTitle: "Import")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        enqueueImports(found.units)
    }

    /// The list of what was found, and what happens to it.
    static func importDetails(_ found: MediaImportScanner.Result) -> String {
        let shown = 12
        var lines = found.units.prefix(shown).map { "• \(($0.path as NSString).lastPathComponent) (\($0.kindName))" }
        if found.units.count > shown { lines.append("• and \(found.units.count - shown) more") }
        var text = lines.joined(separator: "\n")
        text += "\n\nEach is imported like a disc: films and TV are looked up and filed, photos are filed by "
            + "date, and other files are copied into Imported Discs. Anything imported before is skipped."
        if found.looseFiles > 0 {
            text += "\n\n\(found.looseFiles) other file\(found.looseFiles == 1 ? "" : "s") beside them "
                + "won't be imported; choose their folder on its own to import them."
        }
        return text
    }

    func enqueueImports(_ units: [ImportUnit]) {
        pendingImports += units
        appendToLog("Importing \(MediaImportScanner.summary(of: units)), one at a time.")
        Logger.shared.log("Import Media: \(units.map(\.path).joined(separator: ", "))",
                          level: .info, category: .general)
        startNextImport()
    }

    /// Start the next import, unless one is being read.
    func startNextImport() {
        guard activeImport == nil, !pendingImports.isEmpty else { return }
        let unit = pendingImports.removeFirst()
        switch unit {
        case .disc(let path, let kind), .files(let path, let kind):
            beginImport(ImportSources.Source(mountPoint: path,
                                             devicePath: ImportSources.folderDevicePrefix + UUID().uuidString,
                                             imagePath: nil), kind: kind)
        case .image(let path):
            activeImport = path
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                let mounted = Result { try DiskImageMount.attach(path) }
                DispatchQueue.main.async {
                    guard let self = self else { return }
                    self.activeImport = nil
                    switch mounted {
                    case .success(let image):
                        let source = ImportSources.Source(mountPoint: image.mountPoint, devicePath: image.devicePath,
                                                          imagePath: path)
                        ImportSources.shared.add(source)
                        let kind = DiscClassifier.classify(volumeAt: image.mountPoint)
                        self.beginImport(source, kind: kind)
                    case .failure(let error):
                        self.appendToLog(error.localizedDescription)
                        Logger.shared.logError(error, context: "Import Media: \(path)")
                        self.startNextImport()
                    }
                }
            }
        }
    }

    /// Present an import as a disc in a drive: the usual lookup, skip check
    /// and rip follow.
    private func beginImport(_ source: ImportSources.Source, kind: DiscKind) {
        ImportSources.shared.add(source)
        activeImport = source.mountPoint
        let name = ((source.imagePath ?? source.mountPoint) as NSString).lastPathComponent
        guard kind.isImportSupported, kind != .unknown else {
            appendToLog("\(name) isn't something Spindle can import; skipping it.")
            finishImport(at: source.mountPoint)
            return
        }
        appendToLog("Importing \(name) (\(kind.displayName))...")
        let drive = OpticalDrive(mountPoint: source.mountPoint, name: (source.mountPoint as NSString).lastPathComponent,
                                 type: kind, devicePath: source.devicePath)
        driveDetector(DriveDetector.shared, didDetectNewDisc: drive)
    }

    /// The import at `mountPoint` is read (or skipped, or failed): forget it,
    /// unmount its image, and start the next. False if it isn't an import.
    @discardableResult
    func finishImport(at mountPoint: String) -> Bool {
        guard let source = ImportSources.shared.source(at: mountPoint) else { return false }
        ImportSources.shared.remove(mountPoint)
        detectedDrives.removeAll { $0.mountPoint == mountPoint }
        discLookups[mountPoint] = nil
        homeVideoMounts.remove(mountPoint)
        mountDevices[mountPoint] = nil
        updateDriveDropdown()
        if source.imagePath != nil {
            let image = DiskImageMount.Mounted(mountPoint: source.mountPoint, devicePath: source.devicePath)
            DispatchQueue.global(qos: .utility).async { DiskImageMount.detach(image) }
        }
        if activeImport == mountPoint { activeImport = nil }
        if pendingImports.isEmpty, activeImport == nil { appendToLog("Import Media: nothing left to read.") }
        DispatchQueue.main.async { self.startNextImport() }
        return true
    }

    /// An "eject" of an import ends it instead. True if `devicePath` was one.
    func finishImport(device devicePath: String) -> Bool {
        guard let source = ImportSources.shared.source(forDevice: devicePath) else { return false }
        return finishImport(at: source.mountPoint)
    }
}

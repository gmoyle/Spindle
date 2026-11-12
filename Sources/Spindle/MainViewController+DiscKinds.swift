import AppKit

/// Photo, home-video and data discs: what the main window asks and decides
/// before queueing them.
extension MainViewController {

    /// The first photo disc asks where photos go (the Photos folder, Apple
    /// Photos, or both), and for the Photos folder if one hasn't been chosen.
    /// Calls back on the main thread with false if the user chose "Not Now".
    func askPhotoDestinationIfNeeded(completion: @escaping (Bool) -> Void) {
        if settingsManager.photoDestination != nil || testingUtils.isRunningInTestEnvironment {
            completion(true)
            return
        }
        let alert = NSAlert()
        alert.messageText = "Where should photos from photo discs go?"
        alert.informativeText = "Spindle files each photo by the date it was taken and skips photos it has "
            + "already imported. You can change this later in Settings → Output & Routing."
        alert.addButton(withTitle: "Photos Folder")
        alert.addButton(withTitle: "Apple Photos")
        alert.addButton(withTitle: "Both")
        alert.addButton(withTitle: "Not Now")
        let choice: PhotoDestination
        switch alert.runModal() {
        case .alertFirstButtonReturn: choice = .folder
        case .alertSecondButtonReturn: choice = .applePhotos
        case .alertThirdButtonReturn: choice = .both
        default:
            completion(false)
            return
        }
        if choice.includesFolder, !settingsManager.hasChosenLibraryRoot(.photos) {
            let panel = NSOpenPanel()
            panel.message = "Choose the folder for your photo library"
            panel.prompt = "Use This Folder"
            panel.canChooseDirectories = true
            panel.canChooseFiles = false
            panel.canCreateDirectories = true
            panel.directoryURL = URL(fileURLWithPath:
                (settingsManager.libraryRoot(.photos) as NSString).deletingLastPathComponent)
            guard let url = testingUtils.showFilePanel(panel) else {
                completion(false)
                return
            }
            settingsManager.setLibraryRoot(url.path, for: .photos)
        }
        settingsManager.photoDestination = choice
        appendToLog("Photos from photo discs will go to: \(choice.displayName).")
        completion(true)
    }

    /// A video DVD on recordable media (camcorder, DVD recorder): ripped into
    /// Home Videos and named by date, with no title lookup or Movie/TV routing.
    func homeVideoInfo(for mediaType: DiscKind, mountPoint: String?) -> HomeVideoInfo? {
        guard mediaType == .dvd, let mountPoint = mountPoint,
              homeVideoMounts.contains(mountPoint)
                || HomeVideoDetector.isHomeVideo(kind: mediaType,
                                                 opticalMediaType: DriveDetector.opticalMediaType(at: mountPoint))
        else { return nil }
        return HomeVideoDetector.info(forDiscAt: mountPoint)
    }

    /// Where a disc of this kind is written: its library for music, photo,
    /// data and home-video discs; the output folder for films and TV, which
    /// are routed after the rip.
    func outputDirectory(for mediaType: DiscKind, homeVideo: HomeVideoInfo?) -> String {
        if homeVideo != nil { return settingsManager.libraryRoot(.homeVideos) }
        if let library = mediaType.library { return settingsManager.libraryRoot(library) }
        return outputPathField.stringValue
    }

    /// The name shown in the log and the queue.
    func queueTitle(for drive: OpticalDrive, configuration: MediaRipper.RippingConfiguration) -> String {
        if let home = configuration.homeVideo { return home.folderName }
        if drive.type == .photoDisc || drive.type == .dataDisc { return drive.name }
        return resolvedDiscTitle ?? drive.name
    }
}

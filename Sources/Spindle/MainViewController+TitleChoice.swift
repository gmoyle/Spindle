import AppKit

/// Unsure film lookups: the rip starts under the best guess while a "Which film
/// is this?" window asks; the answer renames the finished rip.
extension MainViewController {

    /// Look a disc up and say how sure the answer is. Calls back on the main
    /// thread; nil when nothing was found.
    func lookupDiscTitle(volumeName: String, completion: @escaping (DiscTitleQuery.Resolution?) -> Void) {
        let year = DiscTitleQuery.year(inVolumeName: volumeName)
        let provider = MetadataProviders.movies
        DiscTitleQuery.lookUp(candidates: DiscTitleQuery.candidates(fromVolumeName: volumeName), year: year,
                              provider: provider,
                              onSearch: { [weak self] query in
                                  self?.appendToLog("Looking up '\(query)' on \(provider.name)...")
                              },
                              completion: { resolution in DispatchQueue.main.async { completion(resolution) } })
    }

    /// After an unsure lookup queued `drive`: ask which film it is. TV season
    /// discs ("FIREFLY_D1") are named episode by episode instead, so they aren't asked.
    func askWhichFilm(for drive: OpticalDrive, resolution: DiscTitleQuery.Resolution) {
        let label = TVDiscLabel(volumeName: drive.name)
        guard !resolution.isConfident, label.season == nil, label.disc == nil else { return }
        askWhichFilm(for: drive, choice: TitleChoice(discName: drive.name, guessedName: resolution.best.libraryName,
                                                     choices: resolution.choices),
                     discOwnName: Self.discOwnName(drive.name))
    }

    /// A disc whose label doesn't name the film ("DVD_VIDEO"): it rips under a
    /// placeholder name, and the window asks for the real one.
    func askWhichFilm(forGenericLabelDisc drive: OpticalDrive, placeholder: String) {
        let label = (drive.mountPoint as NSString).lastPathComponent
        askWhichFilm(for: drive, choice: TitleChoice(discName: label, guessedName: placeholder, choices: [],
                                                     labelIsGeneric: true),
                     discOwnName: nil)
    }

    /// A disc whose label found nothing ("FIGHTCLB"): it rips under the label
    /// as a film name, and the window asks for the real one. Not for TV
    /// season discs, which are named episode by episode.
    func askWhichFilm(forUnfoundDisc drive: OpticalDrive, ripName: String) {
        let choice = TitleChoice(discName: drive.name, guessedName: ripName, choices: [])
        choice.notFound = true
        askWhichFilm(for: drive, choice: choice, discOwnName: ripName)
    }

    private func askWhichFilm(for drive: OpticalDrive, choice: TitleChoice, discOwnName: String?) {
        // Only a disc that was just queued (not one skipped as already ripped).
        guard conversionQueue.hasActiveJob(forSourcePath: drive.mountPoint),
              let job = conversionQueue.getAllJobs().last(where: { $0.sourcePath == drive.mountPoint }),
              !testingUtils.isRunningInTestEnvironment else { return }
        choice.jobId = job.id
        choice.volumeLabel = (job.sourcePath as NSString).lastPathComponent
        titleChoices.append(choice)
        appendToLog(choice.labelIsGeneric || choice.notFound
            ? "\(choice.discName) doesn't say which film it is; ripping it as \(choice.guessedDisplayName). "
              + "Name it in the “Which film is this?” window."
            : "Not sure which film \(drive.name) is; ripping it as \(choice.guessedDisplayName). "
              + "Pick the right one in the “Which film is this?” window.")

        let chooser = TitleChooserWindowController(choice: choice, discOwnName: discOwnName,
                                                   offersHomeVideo: drive.type == .dvd, offersParts: true)
        chooser.onHomeVideo = { [weak self, weak choice] in
            guard let self = self, let choice = choice else { return }
            self.fileAsHomeVideo(choice)
        }
        chooser.onChoose = { [weak self, weak choice] (name: String?) in
            guard let self = self, let choice = choice else { return }
            guard let name = name else {
                self.appendToLog("Keeping \(choice.guessedDisplayName) for \(choice.discName).")
                self.titleChoices.removeAll { $0 === choice }
                return
            }
            self.choose(name, for: choice)
        }
        titleChooserWindows.append(chooser)
        chooser.showWindow(nil)
    }

    /// The user named a rip: show the name now, and rename the files now or
    /// when the rip finishes.
    private func choose(_ name: String, for choice: TitleChoice) {
        choice.chosenName = name
        let shown = Self.ripDisplayName(name, part: choice.part)
        if let id = choice.jobId { ripNames[id] = shown }
        appendToLog("\(choice.discName) will be named \(shown).")
        applyTitleChoiceIfReady(choice)
        reloadDiscList()
    }

    /// "Se7en (1995)", or "Se7en (1995) · Disc 2" for one disc of several.
    static func ripDisplayName(_ name: String, part: DiscPart?) -> String {
        let film = MovieMatch.displayName(ofLibraryName: name)
        return part.map { "\(film) · \($0.label)" } ?? film
    }

    // MARK: - From the Discs list

    /// "Which Film Is This…" on a rip in the Discs list: reading, encoding or
    /// finished. The answer renames it now if it's finished, else when it is.
    func chooseFilm(forJob job: ConversionQueue.ConversionJob) {
        guard job.mediaType.isVideo, job.configuration.homeVideo == nil else {
            appendToLog("Only film rips can be named.")
            return
        }
        if let open = titleChooserWindows.first(where: { $0.window?.isVisible == true && $0.jobId == job.id }) {
            open.showWindow(nil)
            return
        }
        let label = (job.sourcePath as NSString).lastPathComponent
        let choice: TitleChoice
        if let pending = titleChoices.first(where: { $0.jobId == job.id }) {
            choice = pending
        } else if DiscListRow.isActive(job.status), let name = job.configuration.plexName {
            choice = TitleChoice(discName: label, guessedName: name, choices: [])
        } else if job.status == .completed, let folder = ripFolders[job.id] ?? Self.singleFolder(job.outputFiles) {
            choice = TitleChoice(discName: label, guessedName: (folder as NSString).lastPathComponent, choices: [])
            choice.finishedFolder = folder
        } else {
            appendToLog("\(job.discTitle) isn't in one film folder, so it can't be renamed here.")
            return
        }
        choice.jobId = job.id
        choice.volumeLabel = label
        presentChooser(for: choice, label: label)
    }

    /// "Which Film Is This…" on a rip from an earlier session: renamed straight
    /// away, as it's finished.
    func chooseFilm(forEarlierRip entry: RipHistoryEntry) {
        let folder = entry.outputLocation
        guard Self.isFilmFolder(folder) else {
            appendToLog("\(entry.title) isn't in a film folder, so it can't be renamed here.")
            return
        }
        if let open = titleChooserWindows.first(where: { $0.window?.isVisible == true && $0.folder == folder }) {
            open.showWindow(nil)
            return
        }
        let choice = TitleChoice(discName: entry.volumeName, guessedName: (folder as NSString).lastPathComponent,
                                 choices: [])
        choice.finishedFolder = folder
        choice.volumeLabel = entry.volumeName
        presentChooser(for: choice, label: entry.volumeName)
    }

    /// A folder holding a film rip named after the folder.
    static func isFilmFolder(_ folder: String) -> Bool {
        !folder.isEmpty && TitleRetitler.isMovieFolder(folder, base: (folder as NSString).lastPathComponent)
    }

    private func presentChooser(for choice: TitleChoice, label: String) {
        if !titleChoices.contains(where: { $0 === choice }) { titleChoices.append(choice) }
        let generic = DiscTitleQuery.isGenericLabel(label)
        let chooser = TitleChooserWindowController(
            choice: choice, discOwnName: generic ? nil : Self.discOwnName(label),
            intro: "Which film is \(label)? It's \(choice.finishedFolder == nil ? "ripping" : "filed") as "
                + "\(choice.guessedDisplayName). Search for the film, or type its name, and the files are "
                + "renamed\(choice.finishedFolder == nil ? " when the rip finishes" : ""). For a film on more "
                + "than one disc, say which disc this is.",
            keepTitle: "Cancel", searchText: generic ? nil : Self.discOwnName(label), offersParts: true)
        chooser.jobId = choice.jobId
        chooser.folder = choice.finishedFolder
        chooser.onChoose = { [weak self, weak choice] (name: String?) in
            guard let self = self, let choice = choice else { return }
            guard let name = name else {
                if choice.chosenName == nil, choice.finishedFolder != nil { self.dropTitleChoice(choice) }
                return
            }
            self.choose(name, for: choice)
        }
        titleChooserWindows.append(chooser)
        chooser.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// The one folder all these files are in, if there is one.
    static func singleFolder(_ files: [String]) -> String? {
        let folders = Set(files.map { ($0 as NSString).deletingLastPathComponent })
        return folders.count == 1 ? folders.first : nil
    }

    /// "OCEANS ELEVEN 2001" → "Oceans Eleven (2001)": the label as a film name.
    /// What a disc whose label found no film rips as: the label as a film name
    /// ("I_ROBOT_16X9" → "I ROBOT"). Nil for a TV season disc ("FIREFLY_D1"),
    /// which keeps its label and is named episode by episode.
    static func unfoundRipName(forLabel label: String) -> String? {
        let tv = TVDiscLabel(volumeName: label)
        guard tv.season == nil, tv.disc == nil else { return nil }
        return TitleRetitler.fileBase(discOwnName(label))
    }

    static func discOwnName(_ label: String) -> String {
        let title = DiscTitleQuery.candidates(fromVolumeName: label).first ?? label
        return DiscTitleQuery.year(inVolumeName: label).map { "\(title) (\($0))" } ?? title
    }

    /// Called when a job finishes: remember where an unsure rip's files are,
    /// and rename them if the user has already picked.
    func noteFinishedJobForTitleChoice(jobId: UUID, outputFiles: [String]) {
        guard let choice = titleChoices.first(where: { $0.jobId == jobId }) else { return }
        guard let folder = TitleRetitler.movieFolder(of: outputFiles, namedAfter: choice.guessedName) else {
            appendToLog("\(choice.discName) wasn't filed as a film, so its title can't be changed here.")
            dropTitleChoice(choice)
            return
        }
        choice.finishedFolder = folder
        applyTitleChoiceIfReady(choice)
    }

    /// A failed or cancelled rip has nothing to rename.
    func dropTitleChoice(forJob jobId: UUID) {
        if let choice = titleChoices.first(where: { $0.jobId == jobId }) { dropTitleChoice(choice) }
    }

    func dropTitleChoice(_ choice: TitleChoice) {
        titleChoices.removeAll { $0 === choice }
        titleChooserWindows.removeAll { $0.window?.isVisible != true }
    }

    func applyTitleChoiceIfReady(_ choice: TitleChoice) {
        if choice.homeVideo, let folder = choice.finishedFolder {
            dropTitleChoice(choice)
            fileFinishedRipAsHomeVideo(folder: folder, discName: choice.discName)
            return
        }
        guard let name = choice.chosenName, let folder = choice.finishedFolder else { return }
        dropTitleChoice(choice)
        let oldName = choice.guessedName, part = choice.part, volume = choice.volumeLabel, jobId = choice.jobId
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Result {
                try TitleRetitler.refile(folder: folder, volume: volume, from: oldName, to: name, part: part)
            }
            DispatchQueue.main.async {
                switch result {
                case .success(let renamed):
                    if let id = jobId { self?.ripFolders[id] = renamed }
                    self?.reloadEarlierRips()
                    self?.appendToLog("Renamed \(oldName) to \(Self.ripDisplayName(name, part: part)): \(renamed)")
                    Logger.shared.log("Retitled \(folder) → \(renamed)", level: .info, category: .general)
                case .failure(let error):
                    self?.appendToLog("Couldn't rename \(oldName): \(error.localizedDescription)")
                    Logger.shared.logError(error, context: "Retitling \(folder)")
                }
            }
        }
    }
}

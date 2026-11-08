import AppKit

/// Unsure film lookups: the rip starts under the best guess while a "Which film
/// is this?" window asks; the answer renames the finished rip.
extension MainViewController {

    /// Look a disc up and say how sure the answer is. Calls back on the main
    /// thread; nil when nothing was found.
    func lookupDiscTitle(volumeName: String, completion: @escaping (DiscTitleQuery.Resolution?) -> Void) {
        let year = DiscTitleQuery.year(inVolumeName: volumeName)
        resolveTitle(candidates: DiscTitleQuery.candidates(fromVolumeName: volumeName), year: year,
                     provider: MetadataProviders.movies, completion: completion)
    }

    private func resolveTitle(candidates: [String], year: String?, provider: MovieMetadataProvider,
                              completion: @escaping (DiscTitleQuery.Resolution?) -> Void) {
        guard let query = candidates.first else {
            DispatchQueue.main.async { completion(nil) }
            return
        }
        appendToLog("Looking up '\(query)' on \(provider.name)...")
        provider.searchMovies(query: query) { [weak self] matches in
            if let resolution = DiscTitleQuery.resolve(query: query, matches: matches, year: year) {
                DispatchQueue.main.async { completion(resolution) }
            } else {
                self?.resolveTitle(candidates: Array(candidates.dropFirst()), year: year, provider: provider,
                                   completion: completion)
            }
        }
    }

    /// After an unsure lookup queued `drive`: ask which film it is. TV season
    /// discs ("FIREFLY_D1") are named episode by episode instead, so they aren't asked.
    func askWhichFilm(for drive: OpticalDrive, resolution: DiscTitleQuery.Resolution) {
        let label = TVDiscLabel(volumeName: drive.name)
        // Only a disc that was just queued (not one skipped as already ripped).
        guard !resolution.isConfident, label.season == nil, label.disc == nil,
              conversionQueue.hasActiveJob(forSourcePath: drive.mountPoint),
              let job = conversionQueue.getAllJobs().last(where: { $0.sourcePath == drive.mountPoint }),
              !testingUtils.isRunningInTestEnvironment else { return }

        let choice = TitleChoice(discName: drive.name, resolution: resolution)
        choice.jobId = job.id
        titleChoices.append(choice)
        appendToLog("Not sure which film \(drive.name) is; ripping it as \(choice.guessedName). "
                    + "Pick the right one in the “Which film is this?” window.")

        let ownName = Self.discOwnName(drive.name)
        let chooser = TitleChooserWindowController(choice: choice, discOwnName: ownName)
        chooser.onChoose = { [weak self, weak choice] name in
            guard let self = self, let choice = choice else { return }
            guard let name = name else {
                self.appendToLog("Keeping \(choice.guessedName) for \(choice.discName).")
                self.titleChoices.removeAll { $0 === choice }
                return
            }
            choice.chosenName = name
            self.appendToLog("\(choice.discName) will be named \(name).")
            self.applyTitleChoiceIfReady(choice)
        }
        titleChooserWindows.append(chooser)
        chooser.showWindow(nil)
    }

    /// "OCEANS ELEVEN 2001" → "Oceans Eleven (2001)": the label as a film name.
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

    private func dropTitleChoice(_ choice: TitleChoice) {
        titleChoices.removeAll { $0 === choice }
        titleChooserWindows.removeAll { $0.window?.isVisible != true }
    }

    private func applyTitleChoiceIfReady(_ choice: TitleChoice) {
        guard let name = choice.chosenName, let folder = choice.finishedFolder else { return }
        dropTitleChoice(choice)
        let oldName = choice.guessedName
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Result { try TitleRetitler.retitle(folder: folder, from: oldName, to: name) }
            DispatchQueue.main.async {
                switch result {
                case .success(let renamed):
                    self?.appendToLog("Renamed \(oldName) to \(name): \(renamed)")
                    Logger.shared.log("Retitled \(folder) → \(renamed)", level: .info, category: .general)
                case .failure(let error):
                    self?.appendToLog("Couldn't rename \(oldName): \(error.localizedDescription)")
                    Logger.shared.logError(error, context: "Retitling \(folder)")
                }
            }
        }
    }
}

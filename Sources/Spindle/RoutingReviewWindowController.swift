import Cocoa

/// Non-blocking review UI for pending Movie/TV routing decisions. The user opens
/// this when they return to the app; ripping never waits on it. Each row shows a
/// completed rip with a Movie/TV toggle pre-set to the classifier's guess. The
/// user can accept all guesses at once or override individually, then apply —
/// which atomically moves each folder to its library root and drains the queue.
final class RoutingReviewWindowController: NSWindowController {

    private let queue = PendingRoutingQueue.shared
    private var items: [PendingRouting] = []
    /// Per-item chosen type (defaults to the guess), keyed by pending id.
    private var choices: [UUID: ContentType] = [:]
    /// Rows to file as home videos instead (Route as: Home Video).
    private var homeVideoRows: Set<UUID> = []

    private var tableView: NSTableView!
    private var statusLabel: NSTextField!
    private var spinner: NSProgressIndicator!
    private var acceptAllButton: NSButton!
    private var applyButton: NSButton!
    /// Set while choices are being applied: moving a rip to a network library
    /// can take minutes, and a second click would start the same moves again.
    private(set) var isApplying = false
    /// "Moving Reservoir Dogs (1 of 2)…" while applying.
    private var progressText: String?
    /// The open "Which film is this?" window, naming a rip from this list.
    private var nameChooser: TitleChooserWindowController?

    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 420),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered, defer: false)
        window.title = "Review Rips — Movie or TV Show"
        window.center()
        window.minSize = NSSize(width: 520, height: 300)
        self.init(window: window)
        window.isReleasedWhenClosed = false
        reload()
        setupUI()
        NotificationCenter.default.addObserver(
            self, selector: #selector(queueChanged),
            name: PendingRoutingQueue.didChangeNotification, object: nil)
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    @objc private func queueChanged() {
        DispatchQueue.main.async { [weak self] in
            self?.reload()
            self?.tableView?.reloadData()
            self?.updateStatus()
        }
    }

    private func reload() {
        queue.pruneMissingFolders()
        items = queue.items
        // Seed choices from guesses (falling back to .movie for unknown so a
        // toggle always has a concrete position).
        for item in items where choices[item.id] == nil {
            choices[item.id] = item.guessedType == .unknown ? .movie : item.guessedType
        }
    }

    private func setupUI() {
        guard let content = window?.contentView else { return }

        statusLabel = NSTextField(labelWithString: "")
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(statusLabel)

        spinner = Self.makeSpinner()
        content.addSubview(spinner)

        let scroll = NSScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder

        tableView = NSTableView()
        tableView.dataSource = self
        tableView.delegate = self
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.rowHeight = 32

        for column in Self.makeColumns() { tableView.addTableColumn(column) }

        scroll.documentView = tableView
        content.addSubview(scroll)

        let (acceptAll, apply) = makeButtons()
        content.addSubview(acceptAll)
        content.addSubview(apply)

        NSLayoutConstraint.activate([
            statusLabel.topAnchor.constraint(equalTo: content.topAnchor, constant: 12),
            statusLabel.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            statusLabel.trailingAnchor.constraint(equalTo: spinner.leadingAnchor, constant: -8),
            spinner.centerYAnchor.constraint(equalTo: statusLabel.centerYAnchor),
            spinner.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),

            scroll.topAnchor.constraint(equalTo: statusLabel.bottomAnchor, constant: 10),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            scroll.bottomAnchor.constraint(equalTo: apply.topAnchor, constant: -12),

            acceptAll.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            acceptAll.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16),

            apply.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            apply.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16),
        ])

        updateStatus()
    }

    private func makeButtons() -> (acceptAll: NSButton, apply: NSButton) {
        let acceptAll = NSButton(title: "Accept All Guesses", target: self,
                                 action: #selector(acceptAllGuesses))
        acceptAll.translatesAutoresizingMaskIntoConstraints = false
        let apply = NSButton(title: "Apply", target: self, action: #selector(applyChoices))
        apply.translatesAutoresizingMaskIntoConstraints = false
        apply.keyEquivalent = "\r"
        acceptAllButton = acceptAll
        applyButton = apply
        return (acceptAll, apply)
    }

    private static func makeColumns() -> [NSTableColumn] {
        var columns: [NSTableColumn] = []
        let discCol = NSTableColumn(identifier: .init("disc"))
        discCol.title = "Rip"
        discCol.width = 230
        columns.append(discCol)

        let nameCol = NSTableColumn(identifier: .init("name"))
        nameCol.title = ""
        nameCol.width = 80
        columns.append(nameCol)

        let guessCol = NSTableColumn(identifier: .init("guess"))
        guessCol.title = "Spindle's guess"
        guessCol.headerToolTip = "Movie or TV show, judged from the lengths of the disc's titles, "
            + "and how sure Spindle is."
        guessCol.width = 110
        columns.append(guessCol)

        let choiceCol = NSTableColumn(identifier: .init("choice"))
        choiceCol.title = "Route as"
        choiceCol.width = 250
        columns.append(choiceCol)
        return columns
    }

    private static func makeSpinner() -> NSProgressIndicator {
        let spinner = NSProgressIndicator()
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        spinner.translatesAutoresizingMaskIntoConstraints = false
        return spinner
    }

    private func updateStatus() {
        if isApplying, let progress = progressText {
            statusLabel.stringValue = progress
            return
        }
        let n = items.count
        statusLabel.stringValue = n == 0
            ? "No rips awaiting routing. New rips will appear here."
            : "\(n) rip\(n == 1 ? "" : "s") to file. Choose Movie, TV Show or Home Video for each, then Apply. "
                + "Name… names a rip Spindle couldn't identify."
    }

    /// Accept every row's guess and route them now. Sets each choice to its guess
    /// (falling back to .movie for an unknown guess, matching the row toggle's
    /// default) and then applies — so the button actually drains the queue rather
    /// than only re-selecting toggles the user hadn't touched.
    @objc private func acceptAllGuesses() {
        guard !isApplying else { return }
        for item in items {
            choices[item.id] = item.guessedType == .unknown ? .movie : item.guessedType
        }
        homeVideoRows.removeAll()
        tableView.reloadData()
        applyChoices()
    }

    @objc private func applyChoices() {
        // Moving to a network library, and filing TV episodes (which looks the
        // series up online), take a while, so it runs off the main thread with
        // the window's controls locked until every choice is applied.
        guard !isApplying, !items.isEmpty else { return }
        let decisions = items.map { ($0, choices[$0.id] ?? .movie) }
        let homeVideos = homeVideoRows
        let homeRoot = SettingsManager.shared.libraryRoot(.homeVideos)
        setApplying(true)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var moved = 0
            var failures: [String] = []
            for (index, (item, type)) in decisions.enumerated() {
                let progress = decisions.count == 1
                    ? "Moving \(item.discName)…"
                    : "Moving \(item.discName) (\(index + 1) of \(decisions.count))…"
                DispatchQueue.main.async { self?.showProgress(progress) }
                do {
                    let status: String
                    if homeVideos.contains(item.id) {
                        let info = HomeVideoFiler.info(forRipIn: item.folderPath, label: item.discName)
                        let destination = try HomeVideoFiler.file(folder: item.folderPath, as: info, into: homeRoot)
                        status = "Filed \(item.discName) in Home Videos: \(destination)"
                    } else {
                        status = try ContentRouter.applyReviewChoice(item, as: type)
                    }
                    Logger.shared.log(status, level: .info, category: .general)
                    self?.queue.remove(id: item.id)
                    moved += 1
                } catch {
                    failures.append("\(item.discName): \(error.localizedDescription)")
                }
            }
            DispatchQueue.main.async { self?.finishApplying(moved: moved, failures: failures) }
        }
    }

    private func showProgress(_ text: String) {
        progressText = text
        updateStatus()
    }

    /// Lock or unlock the window's controls around applying choices.
    private func setApplying(_ applying: Bool) {
        isApplying = applying
        progressText = applying ? "Moving…" : nil
        acceptAllButton.isEnabled = !applying
        applyButton.isEnabled = !applying
        tableView.isEnabled = !applying
        for row in 0..<tableView.numberOfRows {
            for column in [1, 3] {
                (tableView.view(atColumn: column, row: row, makeIfNecessary: false) as? NSControl)?
                    .isEnabled = !applying
            }
        }
        if applying { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
        updateStatus()
    }

    private func finishApplying(moved: Int, failures: [String]) {
        setApplying(false)
        for id in choices.keys where !queue.items.contains(where: { $0.id == id }) { choices[id] = nil }
        homeVideoRows = homeVideoRows.filter { id in queue.items.contains { $0.id == id } }
        reload()
        tableView.reloadData()
        updateStatus()

        if !failures.isEmpty {
            let alert = NSAlert()
            alert.messageText = "Some rips couldn't be routed"
            alert.informativeText = failures.joined(separator: "\n")
            alert.alertStyle = .warning
            alert.runModal()
        } else if moved > 0, items.isEmpty {
            window?.performClose(nil)
        }
    }

    /// Row's Movie/TV segmented control changed.
    @objc private func choiceChanged(_ sender: NSSegmentedControl) {
        let row = sender.tag
        guard row >= 0, row < items.count else { return }
        let id = items[row].id
        if sender.selectedSegment == 2 {
            homeVideoRows.insert(id)
        } else {
            homeVideoRows.remove(id)
            choices[id] = sender.selectedSegment == 0 ? .movie : .tvShow
        }
    }
}

extension RoutingReviewWindowController: NSTableViewDataSource, NSTableViewDelegate {

    func numberOfRows(in tableView: NSTableView) -> Int { items.count }

    func tableView(_ tableView: NSTableView,
                   viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row < items.count, let id = tableColumn?.identifier.rawValue else { return nil }
        let item = items[row]

        switch id {
        case "disc":
            let label = NSTextField(labelWithString: Self.ripName(item))
            label.toolTip = item.note
            label.lineBreakMode = .byTruncatingMiddle
            return label
        case "name":
            let button = NSButton(title: "Name…", target: self, action: #selector(nameRip(_:)))
            button.tag = row
            button.controlSize = .small
            button.isEnabled = !isApplying
            return button
        case "guess":
            let pct = Int(item.confidence * 100)
            let text = item.guessedType == .unknown
                ? "— (unsure)"
                : "\(item.guessedType.displayName) (\(pct)%)"
            let label = NSTextField(labelWithString: text)
            label.textColor = item.confidence >= ContentRouter.autoRouteConfidenceThreshold
                ? .labelColor : .secondaryLabelColor
            return label
        case "choice":
            let seg = NSSegmentedControl(labels: ["Movie", "TV Show", "Home Video"],
                                         trackingMode: .selectOne,
                                         target: self, action: #selector(choiceChanged(_:)))
            seg.tag = row
            seg.selectedSegment = homeVideoRows.contains(item.id) ? 2 : (choices[item.id] ?? .movie) == .movie ? 0 : 1
            seg.isEnabled = !isApplying
            return seg
        default:
            return nil
        }
    }
}

// MARK: - Naming a rip

extension RoutingReviewWindowController {

    /// The rip as listed: its folder's name, with the disc label when they
    /// differ ("Heat (1995)  ·  disc HEAT_DC").
    static func ripName(_ item: PendingRouting) -> String {
        let folder = (item.folderPath as NSString).lastPathComponent
        return folder == item.discName ? folder : "\(folder)  ·  disc \(item.discName)"
    }

    /// "Name…": find the film (or type its name), and the rip's folder and
    /// files are renamed to it, ready to file as a movie.
    @objc func nameRip(_ sender: NSButton) {
        guard !isApplying, sender.tag >= 0, sender.tag < items.count else { return }
        let item = items[sender.tag]
        let folderName = (item.folderPath as NSString).lastPathComponent
        let generic = DiscTitleQuery.isGenericLabel(item.discName)
        let choice = TitleChoice(discName: item.discName, guessedName: folderName, choices: [],
                                 labelIsGeneric: true)
        let chooser = TitleChooserWindowController(
            choice: choice,
            discOwnName: generic ? nil : MainViewController.discOwnName(item.discName),
            intro: "Which film is \(folderName)? Search for it, or type its name, and the rip's folder "
                + "and files are renamed to it. Then file it as a Movie.",
            keepTitle: "Cancel",
            searchText: generic ? nil : MainViewController.discOwnName(item.discName))
        chooser.onChoose = { [weak self] name in
            self?.nameChooser = nil
            guard let name = name else { return }
            self?.rename(item, to: name)
        }
        nameChooser = chooser
        chooser.showWindow(nil)
    }

    private func rename(_ item: PendingRouting, to name: String) {
        showProgress("Naming \((item.folderPath as NSString).lastPathComponent)…")
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Result { try TitleRetitler.nameRip(folder: item.folderPath, to: name) }
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.progressText = nil
                switch result {
                case .success(let renamed):
                    Logger.shared.log("Named \(item.folderPath) → \(renamed)", level: .info, category: .general)
                    self.choices[item.id] = .movie
                case .failure(let error):
                    Logger.shared.logError(error, context: "Naming \(item.folderPath)")
                    let alert = NSAlert()
                    alert.messageText = "Couldn't name the rip"
                    alert.informativeText = error.localizedDescription
                    if !TestingUtilities.shared.isRunningInTestEnvironment { alert.runModal() }
                }
                self.reload()
                self.tableView.reloadData()
                self.updateStatus()
            }
        }
    }
}

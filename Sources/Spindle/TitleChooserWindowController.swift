import AppKit

/// "Which film is this?": shown when a disc's title lookup wasn't sure, or its
/// label doesn't name the film at all ("DVD_VIDEO"). It never blocks: the disc
/// is already ripping under a guess, and the answer renames the rip (now, or
/// when it finishes). The user can pick a match, search for another, or type
/// the name to use.
final class TitleChooserWindowController: NSWindowController {

    /// Called with the chosen name, or nil to keep the guess.
    var onChoose: ((String?) -> Void)?
    /// Searches for films; replaceable in tests.
    var provider: MovieMetadataProvider = MetadataProviders.movies

    private let choice: TitleChoice
    private let discOwnName: String?
    private let listStack = NSStackView()
    let searchField = NSSearchField()
    private let statusLabel = NSTextField(labelWithString: "")
    private var radios: [NSButton] = []
    private var names: [String] = []
    /// Replaces the usual explanation (naming a finished rip in Review Rips).
    private let intro: String?
    /// The button that keeps the current name.
    private let keepTitle: String
    /// Offer "It's a Home Video" (a disc being ripped, not a rip being named).
    private let offersHomeVideo: Bool
    /// Called when the user says the disc is a home video.
    var onHomeVideo: (() -> Void)?

    /// - Parameter discOwnName: the label as a film name, offered as a choice
    ///   (nil for a generic label, which isn't worth offering).
    /// - Parameters:
    ///   - intro: text to show instead of the usual explanation.
    ///   - keepTitle: the title of the button that keeps the current name.
    ///   - searchText: a search to run straight away.
    init(choice: TitleChoice, discOwnName: String?, intro: String? = nil, keepTitle: String = "Use Guess",
         searchText: String? = nil, offersHomeVideo: Bool = false) {
        self.choice = choice
        self.discOwnName = discOwnName
        self.intro = intro
        self.keepTitle = keepTitle
        self.offersHomeVideo = offersHomeVideo
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 240),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Which film is this?"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        buildContent()
        showMatches(choice.choices)
        window.center()
        if let text = searchText, !text.isEmpty {
            searchField.stringValue = text
            search()
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    // MARK: - Layout

    private func buildContent() {
        guard let window = window else { return }
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let intro = NSTextField(wrappingLabelWithString: introText)
        intro.preferredMaxLayoutWidth = 440
        stack.addArrangedSubview(intro)

        // Search: type a title and press Return (or Search) for matches;
        // "Use Typed Name" names the rip exactly as typed.
        searchField.placeholderString = "Film title, e.g. Something's Gotta Give 2003"
        searchField.sendsWholeSearchString = true
        searchField.target = self
        searchField.action = #selector(search)
        searchField.translatesAutoresizingMaskIntoConstraints = false
        searchField.widthAnchor.constraint(equalToConstant: 250).isActive = true
        let searchButton = NSButton(title: "Search", target: self, action: #selector(search))
        let typedButton = NSButton(title: "Use Typed Name", target: self, action: #selector(useTypedName))
        stack.addArrangedSubview(NSStackView(views: [searchField, searchButton, typedButton]))

        statusLabel.textColor = .secondaryLabelColor
        statusLabel.isHidden = true
        stack.addArrangedSubview(statusLabel)

        listStack.orientation = .vertical
        listStack.alignment = .leading
        listStack.spacing = 8
        stack.addArrangedSubview(listStack)

        // "Use Guess" keeps the name the disc is ripping under; "Use Selected"
        // takes the film picked in the list. No default button: Return in the
        // search box searches.
        let keep = NSButton(title: keepTitle, target: self, action: #selector(keepGuess))
        if self.intro == nil { keep.toolTip = "Keep \(choice.guessedDisplayName), the name the disc is ripping under" }
        let use = NSButton(title: "Use Selected", target: self, action: #selector(useSelection))
        let buttons = NSStackView(views: [keep, use])
        if offersHomeVideo {
            let home = NSButton(title: "It's a Home Video", target: self, action: #selector(markHomeVideo))
            home.toolTip = "Not a film: rip every recording on the disc into Home Videos, named by date"
            buttons.insertView(home, at: 0, in: .leading)
        }
        buttons.spacing = 8
        stack.addArrangedSubview(buttons)

        let content = NSView()
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            content.widthAnchor.constraint(equalToConstant: 480)
        ])
        window.contentView = content
        if choice.labelIsGeneric || choice.notFound { window.initialFirstResponder = searchField }
        // Nothing matched the label: start from it, so a fix is a small edit.
        if choice.notFound, let own = discOwnName { searchField.stringValue = own }
    }

    private var introText: String {
        if let intro = intro { return intro }
        if choice.notFound {
            return "Spindle couldn't find a film for the disc's label (\(choice.discName)), so it's ripping it as "
                + "\(choice.guessedDisplayName). Search for the film, or type its name, and the files are renamed "
                + "when the rip finishes."
        }
        if choice.labelIsGeneric {
            return "The disc's label (\(choice.discName)) doesn't say which film it is, so Spindle is ripping "
                + "it as \(choice.guessedDisplayName). Search for the film, or type its name, and the files are "
                + "renamed when the rip finishes."
        }
        return "Spindle isn't sure which film \(choice.discName) is. It's ripping it as \(choice.guessedDisplayName). "
            + "Pick the right one, or search for it, and the files are renamed when the rip finishes."
    }

    /// Replace the list with these matches (plus the disc's own name).
    private func showMatches(_ matches: [MovieMatch]) {
        for view in listStack.arrangedSubviews {
            listStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        radios.removeAll()
        names.removeAll()
        for match in matches.prefix(DiscTitleQuery.maxChoices) {
            // Shown as "Title (Year)"; named with its id, so Plex matches this film.
            listStack.addArrangedSubview(row(title: match.libraryName, poster: match.posterURL,
                                             label: match.displayName))
        }
        if let own = discOwnName, !names.contains(own) {
            listStack.addArrangedSubview(row(title: own, poster: nil, label: "The disc's own name: \(own)"))
        }
        radios.first?.state = .on
        if let window = window, let content = window.contentView {
            content.layoutSubtreeIfNeeded()
            window.setContentSize(content.fittingSize)
        }
    }

    private func row(title: String, poster: URL?, label: String? = nil) -> NSView {
        let radio = NSButton(radioButtonWithTitle: label ?? title, target: self, action: #selector(radioChanged(_:)))
        radios.append(radio)
        names.append(title)
        guard let poster = poster else { return radio }
        let image = NSImageView()
        image.imageScaling = .scaleProportionallyUpOrDown
        image.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([image.widthAnchor.constraint(equalToConstant: 40),
                                     image.heightAnchor.constraint(equalToConstant: 60)])
        URLSession.shared.dataTask(with: poster) { data, _, _ in
            guard let data = data, let picture = NSImage(data: data) else { return }
            DispatchQueue.main.async { image.image = picture }
        }.resume()
        let row = NSStackView(views: [radio, image])
        row.spacing = 8
        return row
    }

    // MARK: - Actions

    /// The names on offer, in order (for tests).
    var offeredNames: [String] { names }

    @objc func search() {
        let text = searchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let year = DiscTitleQuery.year(inVolumeName: text)
        let query = year.map { year in
            text.replacingOccurrences(of: year, with: "").trimmingCharacters(in: .whitespaces)
        } ?? text
        showStatus("Searching for “\(text)”…")
        provider.searchMovies(query: query.isEmpty ? text : query) { [weak self] matches in
            DispatchQueue.main.async {
                guard let self = self else { return }
                let ordered = DiscTitleQuery.resolve(query: query, matches: matches, year: year)?.choices ?? []
                self.showStatus(ordered.isEmpty
                    ? "Nothing found for “\(text)”. Check the spelling, or use the typed name." : nil)
                self.showMatches(ordered)
            }
        }
    }

    @objc func markHomeVideo() {
        onHomeVideo?()
        onHomeVideo = nil
        onChoose = nil
        close()
    }

    @objc func useTypedName() {
        guard let name = TitleChoice.typedName(searchField.stringValue) else {
            showStatus("Type the film's name first, e.g. Something's Gotta Give 2003.")
            return
        }
        finish(name)
    }

    private func showStatus(_ text: String?) {
        statusLabel.stringValue = text ?? ""
        statusLabel.isHidden = text == nil
    }

    @objc private func radioChanged(_ sender: NSButton) {
        for radio in radios { radio.state = radio === sender ? .on : .off }
    }

    @objc private func useSelection() {
        guard let index = radios.firstIndex(where: { $0.state == .on }) else {
            showStatus("Search for the film, or type its name and click Use Typed Name.")
            return
        }
        finish(names[index] == choice.guessedName ? nil : names[index])
    }

    @objc private func keepGuess() { finish(nil) }

    private func finish(_ name: String?) {
        onChoose?(name)
        onChoose = nil
        close()
    }
}

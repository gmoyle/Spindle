import AppKit

/// "Which film is this?" — shown when a disc's title lookup wasn't sure. It
/// never blocks: the disc is already ripping under the best guess, and the
/// pick renames the rip (now, or when it finishes).
final class TitleChooserWindowController: NSWindowController {

    /// Called with the chosen name, or nil to keep the guess.
    var onChoose: ((String?) -> Void)?

    private let choice: TitleChoice
    private let discOwnName: String
    private var radios: [NSButton] = []
    private var names: [String] = []

    init(choice: TitleChoice, discOwnName: String) {
        self.choice = choice
        self.discOwnName = discOwnName
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 200),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Which film is this?"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        buildContent()
        window.center()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    private func buildContent() {
        guard let window = window else { return }
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let intro = NSTextField(wrappingLabelWithString:
            "Spindle isn't sure which film \(choice.discName) is. It's ripping it as "
            + "\(choice.guessedName). Pick the right one and the files are renamed when the rip finishes.")
        intro.preferredMaxLayoutWidth = 420
        stack.addArrangedSubview(intro)

        for match in choice.resolution.choices {
            stack.addArrangedSubview(row(title: match.displayName, poster: match.posterURL))
        }
        stack.addArrangedSubview(row(title: discOwnName, poster: nil, label: "Keep the disc's name: \(discOwnName)"))
        radios.first?.state = .on

        let keep = NSButton(title: "Keep \(choice.guessedName)", target: self, action: #selector(keepGuess))
        let use = NSButton(title: "Use This Film", target: self, action: #selector(useSelection))
        use.keyEquivalent = "\r"
        let buttons = NSStackView(views: [keep, use])
        buttons.spacing = 8
        stack.addArrangedSubview(buttons)

        let content = NSView()
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            content.widthAnchor.constraint(equalToConstant: 460)
        ])
        window.contentView = content
        window.setContentSize(content.fittingSize)
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

    @objc private func radioChanged(_ sender: NSButton) {
        for radio in radios { radio.state = radio === sender ? .on : .off }
    }

    @objc private func useSelection() {
        let index = radios.firstIndex { $0.state == .on } ?? 0
        finish(names[index] == choice.guessedName ? nil : names[index])
    }

    @objc private func keepGuess() { finish(nil) }

    private func finish(_ name: String?) {
        onChoose?(name)
        onChoose = nil
        close()
    }
}

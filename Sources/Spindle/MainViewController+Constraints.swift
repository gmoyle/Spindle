import Cocoa

// MARK: - Constraints Setup

extension MainViewController {

    func setupConstraints() {
        logHeightConstraint = scrollView.heightAnchor.constraint(equalToConstant: 180)

        NSLayoutConstraint.activate([
            // Title
            titleLabel.topAnchor.constraint(equalTo: view.topAnchor, constant: 20),
            titleLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),

            // A line per disc, each with its Cancel
            discLinesStack.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 16),
            discLinesStack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            discLinesStack.trailingAnchor.constraint(
                lessThanOrEqualTo: refreshDrivesButton.leadingAnchor, constant: -12
            ),

            // Refresh at the right of the first disc line, above Settings
            refreshDrivesButton.topAnchor.constraint(equalTo: discLinesStack.topAnchor, constant: -3),
            refreshDrivesButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            refreshDrivesButton.widthAnchor.constraint(equalToConstant: 80),

            // The drive menu and Browse are hidden; they sit under the disc lines.
            sourceDropDown.topAnchor.constraint(equalTo: discLinesStack.bottomAnchor, constant: 8),
            sourceDropDown.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            sourceDropDown.trailingAnchor.constraint(
                equalTo: browseSourceButton.leadingAnchor, constant: -10
            ),
            browseSourceButton.topAnchor.constraint(equalTo: sourceDropDown.topAnchor),
            browseSourceButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            browseSourceButton.widthAnchor.constraint(equalToConstant: 80),

            // Automation Settings — checkboxes stacked, settings button at right
            autoRipCheckbox.topAnchor.constraint(equalTo: discLinesStack.bottomAnchor, constant: 20),
            autoRipCheckbox.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),

            autoEjectCheckbox.topAnchor.constraint(equalTo: autoRipCheckbox.bottomAnchor, constant: 5),
            autoEjectCheckbox.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),

            skipRippedCheckbox.topAnchor.constraint(equalTo: autoEjectCheckbox.bottomAnchor, constant: 5),
            skipRippedCheckbox.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),

            settingsButton.topAnchor.constraint(equalTo: autoRipCheckbox.topAnchor),
            settingsButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            settingsButton.widthAnchor.constraint(equalToConstant: 80),

            reviewRipsButton.centerYAnchor.constraint(equalTo: settingsButton.centerYAnchor),
            reviewRipsButton.trailingAnchor.constraint(equalTo: settingsButton.leadingAnchor, constant: -8),

            keepAwakeCheckbox.topAnchor.constraint(equalTo: skipRippedCheckbox.bottomAnchor, constant: 5),
            keepAwakeCheckbox.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),

            // Rip Button
            ripButton.topAnchor.constraint(equalTo: keepAwakeCheckbox.bottomAnchor, constant: 20),
            ripButton.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            ripButton.widthAnchor.constraint(equalToConstant: 120),

            // Progress Indicator
            progressIndicator.topAnchor.constraint(equalTo: ripButton.bottomAnchor, constant: 20),
            progressIndicator.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            progressIndicator.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),

            // Progress Status Label
            progressStatusLabel.topAnchor.constraint(equalTo: progressIndicator.bottomAnchor, constant: 4),
            progressStatusLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            progressStatusLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),

            // Queue table fills the space between progress and the log disclosure
            queueScrollView.topAnchor.constraint(equalTo: progressStatusLabel.bottomAnchor, constant: 8),
            queueScrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            queueScrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            queueScrollView.heightAnchor.constraint(greaterThanOrEqualToConstant: 120),

            // Log disclosure row
            logDisclosureButton.topAnchor.constraint(equalTo: queueScrollView.bottomAnchor, constant: 8),
            logDisclosureButton.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            logDisclosureLabel.centerYAnchor.constraint(equalTo: logDisclosureButton.centerYAnchor),
            logDisclosureLabel.leadingAnchor.constraint(
                equalTo: logDisclosureButton.trailingAnchor, constant: 4
            ),

            // Log Text View (collapsed by default via logHeightConstraint)
            scrollView.topAnchor.constraint(equalTo: logDisclosureButton.bottomAnchor, constant: 6),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -20),
            logHeightConstraint
        ])
    }
}

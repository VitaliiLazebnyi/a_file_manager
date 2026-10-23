import AFMKernel
import AppKit

/// The menu strip, the content area and the status line.
extension ViewerPane {
    /// Gives the pane the keyboard: to the text when it shows text.
    internal func takeKeyboard() {
        window?.makeFirstResponder(contentView === pager ? pager : self)
    }

    /// The titles of the entries of one of the menus, for tests.
    internal func menuTitles(_ menu: String) -> [String] { menuEntries(menu).map { $0?.title ?? "-" } }

    /// Shows the status, the percent item, the file counter and the progress of `activity` as they are now.
    internal func updateChrome() {
        statusLabel.stringValue = statusText
        percentButton.title = percentText
        percentButton.isHidden = percentText.isEmpty
        let several = fileCounter.count > 1
        for view in [previousButton, nextButton, counterLabel] as [NSView] { view.isHidden = !several }
        counterLabel.stringValue = "\(fileCounter.index + 1)/\(fileCounter.count)"
        progressBar.isHidden = activity == nil
        cancelButton.isHidden = activity == nil
        if let activity {
            progressBar.isIndeterminate = activity.progress == nil
            progressBar.doubleValue = activity.progress ?? 0
            if activity.progress == nil { progressBar.startAnimation(nil) }
        }
    }

    /// Puts a view into the content area in place of the one before; the keyboard goes to `responder`, or to the
    /// pane when it is nil.
    internal func setContent(_ view: NSView, keyboardTo responder: NSView?) {
        if contentView !== view {
            contentView?.removeFromSuperview()
            view.translatesAutoresizingMaskIntoConstraints = false
            contentHost.addSubview(view)
            NSLayoutConstraint.activate([
                view.topAnchor.constraint(equalTo: contentHost.topAnchor),
                view.bottomAnchor.constraint(equalTo: contentHost.bottomAnchor),
                view.leadingAnchor.constraint(equalTo: contentHost.leadingAnchor),
                view.trailingAnchor.constraint(equalTo: contentHost.trailingAnchor)
            ])
            contentView = view
        }
        if !isEmbedded || hasKeyboard { window?.makeFirstResponder(responder ?? self) }
    }

    /// Lays out the strip, the content area and the status line, once.
    internal func buildChrome() {
        for button in menuButtons { button.menu?.delegate = self }
        for (button, action) in [
            (previousButton, #selector(previousFile)), (nextButton, #selector(nextFile)),
            (percentButton, #selector(percentClicked)),
            (cancelButton, #selector(cancelActivity))
        ] {
            button.target = self
            button.action = action
            button.isBordered = button === cancelButton
            button.controlSize = .small
            button.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        }
        percentButton.toolTip = "Go to position (in %)"
        counterLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        statusLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingMiddle
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        progressBar.style = .bar
        progressBar.controlSize = .small
        progressBar.minValue = 0
        progressBar.maxValue = 1
        progressBar.isHidden = true
        cancelButton.isHidden = true
        arrangeChrome()
    }

    @objc
    private func previousFile() { onStep(-1) }

    @objc
    private func nextFile() { onStep(1) }

    @objc
    private func percentClicked() { goToPercent() }

    @objc
    private func cancelActivity() { activity?.cancel.cancel() }

    /// Stacks the strip, the content area and the status line, filling the pane.
    private func arrangeChrome() {
        let spacer = NSView()
        let statusSpacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        statusSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let strip = NSStackView(views: menuButtons + [spacer, previousButton, counterLabel, nextButton, percentButton])
        strip.spacing = 6
        strip.edgeInsets = NSEdgeInsets(top: 2, left: 6, bottom: 2, right: 8)
        let status = NSStackView(views: [statusLabel, statusSpacer, progressBar, cancelButton])
        status.spacing = 8
        status.edgeInsets = NSEdgeInsets(top: 2, left: 8, bottom: 2, right: 8)
        progressBar.widthAnchor.constraint(equalToConstant: 140).isActive = true
        let stack = NSStackView(views: [strip, contentHost, status])
        stack.orientation = .vertical
        stack.spacing = 0
        stack.alignment = .leading
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor), stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            strip.widthAnchor.constraint(equalTo: stack.widthAnchor),
            status.widthAnchor.constraint(equalTo: stack.widthAnchor),
            contentHost.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
        contentHost.setContentHuggingPriority(.defaultLow, for: .vertical)
        contentHost.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        contentHost.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    }
}

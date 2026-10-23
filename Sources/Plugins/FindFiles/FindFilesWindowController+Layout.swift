import AFMKernel
import AppKit

/// The content of the window: the form and its buttons, the result list and the buttons under it.
extension FindFilesWindowController {
    /// Makes the content of `window`.
    internal func buildContent(in window: NSWindow) {
        startButton.target = self
        startButton.action = #selector(startPressed)
        cancelButton.target = self
        cancelButton.action = #selector(cancelPressed)
        for (button, action) in [(backButton, #selector(showEarlier)), (forwardButton, #selector(showLater))] {
            button.target = self
            button.action = action
            button.bezelStyle = .roundRect
        }
        let scroll = makeResultList()
        statusLabel.lineBreakMode = .byTruncatingMiddle
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        newSearchButton = NSButton(title: "New search", target: self, action: #selector(newSearch))
        feedButton = NSButton(title: "Feed to listbox", target: self, action: #selector(feedToListbox))
        resultButtons = [
            NSButton(title: "F3 View", target: self, action: #selector(viewResult)),
            NSButton(title: "F4 Edit", target: self, action: #selector(editResult)),
            NSButton(title: "Go to file", target: self, action: #selector(goToFile))
        ]
        let header = NSStackView(views: [
            NSTextField(labelWithString: "Search results:"), NSView(), backButton, forwardButton, inFoundBox
        ])
        let footer = NSStackView(views: [
            resultButtons[0], resultButtons[1], newSearchButton, resultButtons[2], feedButton, NSView()
        ])
        let top = makeTop()
        let stack = NSStackView(views: [top, header, scroll, footer, statusLabel])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 14, bottom: 10, right: 14)
        for part in [top, header, scroll, footer, statusLabel] as [NSView] {
            part.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -28).isActive = true
        }
        scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 120).isActive = true
        scroll.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .vertical)
        window.contentView = stack
        updateButtons()
    }

    /// The result list in its scroll view.
    private func makeResultList() -> NSScrollView {
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("path"))
        column.title = "Search results"
        resultsTable.addTableColumn(column)
        resultsTable.headerView = nil
        resultsTable.dataSource = self
        resultsTable.delegate = self
        resultsTable.rowHeight = 18
        resultsTable.style = .plain
        resultsTable.usesAlternatingRowBackgroundColors = true
        resultsTable.target = self
        resultsTable.doubleAction = #selector(goToFile)
        resultsTable.onKey = { [weak self] event in self?.handleResultKey(event) == true }
        let scroll = NSScrollView()
        scroll.documentView = resultsTable
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        return scroll
    }

    /// The form with Start and Close beside it.
    private func makeTop() -> NSStackView {
        let buttons = NSStackView(views: [startButton, cancelButton])
        buttons.orientation = .vertical
        buttons.alignment = .leading
        buttons.spacing = 8
        buttons.edgeInsets.top = 24
        for button in [startButton, cancelButton] {
            button.widthAnchor.constraint(equalToConstant: 110).isActive = true
        }
        let top = NSStackView(views: [form.tabView, buttons])
        top.alignment = .top
        form.tabView.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)
        return top
    }

    @objc
    private func startPressed() {
        if !isSearching {
            startSearch()
        }
    }

    @objc
    private func cancelPressed() {
        if isSearching {
            cancelSearch()
        } else {
            close()
        }
    }
}

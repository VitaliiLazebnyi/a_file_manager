import AFMContracts
import AFMKernel
import AFMShell
import AppKit

/// The result list: its lines, the earlier lists, and what can be done with a result.
extension FindFilesWindowController {
    /// The files and folders in the list, in list order.
    internal var resultItems: [FileItem] {
        rows.compactMap { row in
            if case .item(let item) = row {
                return item
            }
            return nil
        }
    }

    /// The lines of the list as they are shown and copied.
    internal var lines: [String] { rows.map(text) }

    /// The list as text: one line per result, an empty line between groups of duplicates.
    internal var copyText: String {
        Self.copyText(of: rows, showsDuplicates: showsDuplicates, fileSystems: kernel.fileSystems)
    }

    /// The result under the cursor, if the cursor is on one.
    internal var selectedItem: FileItem? {
        guard rows.indices.contains(resultsTable.selectedRow), case .item(let item) = rows[resultsTable.selectedRow]
        else {
            return nil
        }
        return item
    }

    /// The location of the result under the cursor.
    internal var selectedResult: URL? { selectedItem?.url }

    /// Whether Shift is held down.
    internal var shiftIsDown: Bool { modifierFlags().contains(.shift) }

    /// The text of a row as the list shows it.
    internal func text(of row: Row) -> String {
        switch row {
        case .summary(let text):
            return text

        case .separator:
            return String(repeating: "- ", count: 40)

        case .item(let item):
            return Self.text(
                of: item,
                showsDuplicates: showsDuplicates,
                fileSystems: kernel.fileSystems
            )
        }
    }

    /// Empties the list.
    internal func clearResults() {
        let dropped = (rows, resultURLs)
        DispatchQueue.global(qos: .utility)
            .async {
                withExtendedLifetime(dropped) {
                    // The list goes here, off the main thread.
                }
            }
        rows = []
        (resultURLs, foundFiles, foundDirectories) = ([], 0, 0)
        showsDuplicates = false
        resultsTable.reloadData()
        statusLabel.stringValue = ""
        updateButtons()
    }

    /// Keeps the list of the search that ended with the earlier ones: the last few, as far as their lists
    /// are not huge.
    internal func keepResults() {
        earlier.append(
            ResultSet(
                rows: rows,
                showsDuplicates: showsDuplicates,
                urls: resultURLs,
                files: foundFiles,
                directories: foundDirectories
            )
        )
        var kept = 0
        for (index, set) in earlier.enumerated().reversed() {
            kept += set.rows.count
            if index < earlier.count - Self.earlierLimit
                || (kept > limits.earlierRows && index < earlier.count - 1)
            {
                let dropped = Array(earlier[...index])
                earlier.removeFirst(index + 1)
                // Freeing a list of millions of rows is not done on the main thread.
                DispatchQueue.global(qos: .utility)
                    .async {
                        withExtendedLifetime(dropped) {
                            // The lists go here, off the main thread.
                        }
                    }
                break
            }
        }
        earlierIndex = earlier.count - 1
    }

    /// New search: empties the list and goes back to the form.
    @objc
    internal func newSearch() {
        guard !isSearching else {
            return
        }
        clearResults()
        form.tabView.selectTabViewItem(at: 0)
        window?.makeFirstResponder(form.searchForField)
    }

    /// Go to file: closes the window and puts the panel's cursor on the result; with Shift in
    /// a new tab.
    ///
    /// A single result is taken even when it is not the selected line.
    @objc
    internal func goToFile() {
        guard let url = selectedResult ?? (resultURLs.count == 1 ? resultURLs[0] : nil) else {
            return
        }
        close()
        if shiftIsDown {
            kernel.panels.source.tabs.openTab()
        }
        kernel.commands.perform(.changeDirectory, .location(url))
    }

    /// Feed to listbox: the results become the list of the source panel, through whichever
    /// plugin shows file lists as folders (spec 09 › Feed to listbox); with Shift in a new tab.
    ///
    /// The window closes and does not keep these results.
    @objc
    internal func feedToListbox() {
        let urls = resultURLs
        guard !isSearching, !urls.isEmpty, let lists = kernel.services.find((any FileListService).self) else {
            return
        }
        let inNewTab = shiftIsDown
        close()
        let panel = kernel.panels.source
        if inNewTab {
            panel.tabs.openTab()
        }
        // The search leaves out a file it has reported: the list holds no location twice.
        lists.show(urls, title: "Search result", in: panel, isUnique: true)
        clearResults()
        (earlier, earlierIndex) = ([], 0)
    }

    /// `<`: the list of the search before.
    @objc
    internal func showEarlier() {
        guard !isSearching, earlierIndex > 0 else {
            return
        }
        earlierIndex -= 1
        show(earlier[earlierIndex])
    }

    /// `>`: the list of the search after.
    @objc
    internal func showLater() {
        guard !isSearching, earlierIndex < earlier.count - 1 else {
            return
        }
        earlierIndex += 1
        show(earlier[earlierIndex])
    }

    /// F3 View: the result under the cursor in the viewer.
    @objc
    internal func viewResult() {
        if let url = selectedResult {
            kernel.commands.perform(.view, .location(url))
        }
    }

    /// F4 Edit: the result under the cursor in the editor.
    @objc
    internal func editResult() {
        if let url = selectedResult {
            kernel.commands.perform(.edit, .location(url))
        }
    }

    /// Enter goes to the file and Cmd+C copies the whole list; View and Edit answer to whatever
    /// keys they are bound to in the main window.
    internal func handleResultKey(_ event: NSEvent) -> Bool {
        if Shortcut(.returnKey).matches(event) || Shortcut(.returnKey, .shift).matches(event) {
            goToFile()
        } else if Shortcut.cmd("c").matches(event) || Shortcut(.character("c"), .control).matches(event) {
            copyListToPasteboard()
        } else if let command = kernel.keyBindings.command(for: event), command == .view || command == .edit,
            let url = selectedResult
        {
            kernel.commands.perform(command, .location(url))
        } else {
            return false
        }
        return true
    }

    private func show(_ set: ResultSet) {
        (rows, showsDuplicates) = (set.rows, set.showsDuplicates)
        (resultURLs, foundFiles, foundDirectories) = (set.urls, set.files, set.directories)
        resultsTable.reloadData()
        if case .summary(let text)? = rows.first {
            statusLabel.stringValue = text
        }
        updateButtons()
    }

    /// Cmd+C: a long list is turned into text on a background queue (that takes a second for
    /// millions of rows) and put on the pasteboard when it is ready; a list shown again or
    /// copied again meanwhile drops the older request.
    private func copyListToPasteboard() {
        copyRequest += 1
        let request = copyRequest
        let (copied, duplicates, fileSystems) = (rows, showsDuplicates, kernel.fileSystems)
        let board = Handover(pasteboard)
        let put: @MainActor @Sendable (String) -> Void = { text in
            board.value.clearContents()
            board.value.setString(text, forType: .string)
        }
        guard copied.count > Self.smallList else {
            put(copyText)
            return
        }
        statusLabel.stringValue = "[Copying the list...]"
        DispatchQueue.global(qos: .userInitiated)
            .async { [weak self] in
                let text = Self.copyText(of: copied, showsDuplicates: duplicates, fileSystems: fileSystems)
                DispatchQueue.main.async { [weak self] in
                    guard let self, copyRequest == request else {
                        return
                    }
                    put(text)
                    if case .summary(let summary)? = rows.first, !isSearching {
                        statusLabel.stringValue = summary
                    }
                }
            }
    }
}

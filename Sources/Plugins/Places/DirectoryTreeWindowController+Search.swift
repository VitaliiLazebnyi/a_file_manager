import AFMKernel
import AFMShell
import AppKit

/// The quick search and the keys of the tree window.
extension DirectoryTreeWindowController {
    /// One quick search, which goes on in slices: what it looks for, where, and which search it is.
    private struct SearchRun {
        /// The tree searched.
        let tree: DirectoryTree
        /// What was typed.
        let text: String
        /// The direction it goes in.
        let forward: Bool
        /// The number of the search (`searchCounter`): a newer one ends it.
        let number: Int
    }

    /// What a key press types, when it types something: no control or command key, and not one
    /// of the keys that only have a code (arrows, function keys).
    private static func typedText(_ event: NSEvent) -> String? {
        guard event.modifierFlags.isDisjoint(with: [.command, .control]), let text = event.characters, !text.isEmpty,
            text.unicodeScalars.allSatisfy({ scalar in
                scalar.value >= 0x20 && scalar.value != 0x7F && !(0xF700...0xF8FF).contains(scalar.value)
            })
        else { return nil }
        return text
    }

    /// The quick-search field changed: the search starts again at the cursor.
    internal func controlTextDidChange(_: Notification) {
        search(forward: true, includingStart: true)
    }

    /// Keys in the quick-search field: Ctrl+Enter and Ctrl+arrows step through the matches, and
    /// plain arrows move the cursor in the tree.
    internal func control(_: NSControl, textView _: NSTextView, doCommandBy _: Selector) -> Bool {
        handleFieldKey(NSApplication.shared.currentEvent)
    }

    /// The key press behind a command of the quick-search field, if it was one.
    internal func handleFieldKey(_ event: NSEvent?) -> Bool {
        guard let event, event.type == .keyDown else {
            return false
        }
        if Shortcut(.returnKey).matches(event) || Shortcut(.enter).matches(event) {
            accept()
            return true
        }
        if handleStepKey(event) {
            return true
        }
        if Shortcut(.upArrow).matches(event) || Shortcut(.downArrow).matches(event) {
            outline.keyDown(with: event)
            return true
        }
        return false
    }

    /// Keys in the tree: Enter goes there, F2 rescans, and typing fills the quick search.
    internal func handleKey(_ event: NSEvent) -> Bool {
        if handleStepKey(event) {
            return true
        }
        if Self.isRescanKey(event) {
            rescan()
        } else if Shortcut(.returnKey).matches(event) || Shortcut(.enter).matches(event) {
            accept()
        } else if Shortcut(.backspace).matches(event) {
            searchField.stringValue = String(searchField.stringValue.dropLast())
            search(forward: true, includingStart: true)
        } else if let typed = Self.typedText(event) {
            searchField.stringValue += typed
            search(forward: true, includingStart: true)
        } else {
            return false
        }
        return true
    }

    /// Ctrl+Enter and Ctrl+Down find the next match, Ctrl+Up the one before; false for any other key.
    private func handleStepKey(_ event: NSEvent) -> Bool {
        if Shortcut(.returnKey, .control).matches(event) || Shortcut(.downArrow, .control).matches(event) {
            search(forward: true, includingStart: false)
        } else if Shortcut(.upArrow, .control).matches(event) {
            search(forward: false, includingStart: false)
        } else {
            return false
        }
        return true
    }

    /// Quick search, in slices of `turnBudget`: in a tree of millions of folders the search
    /// goes on in later turns, and a new key press or a new tree ends the one that is going on.
    private func search(forward: Bool, includingStart: Bool) {
        searchCounter += 1
        guard let tree, !searchField.stringValue.isEmpty else {
            return
        }
        let run = SearchRun(tree: tree, text: searchField.stringValue, forward: forward, number: searchCounter)
        continueSearch(run, from: selectedNode, includingStart: includingStart, remaining: nil)
    }

    /// One slice of `run`, from `start` on with `remaining` folders still to look at; the next slice is asked for
    /// when the time is up.
    private func continueSearch(_ run: SearchRun, from start: TreeNode?, includingStart: Bool, remaining: Int?) {
        guard run.number == searchCounter, run.tree === tree else {
            return
        }
        let progress = run.tree.search(
            run.text,
            from: start,
            forward: run.forward,
            includingStart: includingStart,
            remaining: remaining,
            timeBudget: Self.turnBudget
        )
        switch progress {
        case .found(let match):
            reveal(match)

        case .notFound:
            beep()

        case .pending(let node, let left):
            DispatchQueue.main.async { [weak self] in
                self?.continueSearch(run, from: node, includingStart: true, remaining: left)
            }
        }
    }
}

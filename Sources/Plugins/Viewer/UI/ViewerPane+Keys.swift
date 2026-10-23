import AFMKernel
import AFMShell
import AppKit

/// The keyboard: the keys of the menu entries, the cursor keys and the keys of the media player.
extension ViewerPane {
    /// A key that was pressed, asked about the keys it may be.
    private struct KeyPress {
        let event: NSEvent
        /// The modifiers held with it.
        let flags: KeyModifiers

        init(_ event: NSEvent) {
            self.event = event
            flags = KeyModifiers(
                rawValue: (event.modifierFlags.contains(.shift) ? 1 : 0)
                    | (event.modifierFlags.contains(.control) ? 2 : 0)
                    | (event.modifierFlags.contains(.option) ? 4 : 0)
                    | (event.modifierFlags.contains(.command) ? 8 : 0)
            )
        }

        /// Whether it is `key` with exactly `modifiers`.
        func pressed(_ key: Key, _ modifiers: KeyModifiers = []) -> Bool { Shortcut(key, modifiers).matches(event) }

        /// Whether it is `key`, whatever the modifiers.
        func named(_ key: Key) -> Bool { Shortcut(key, flags).matches(event) }
    }

    /// What the key monitor does with a key of the application: a key of this pane's window
    /// that the pane handles is taken (nil), any other is passed on.
    internal func monitored(_ event: NSEvent) -> NSEvent? {
        takes(event) ? nil : event
    }

    /// Whether the pane handles `event`, a key of the application: only one of its window.
    internal func takes(_ event: NSEvent) -> Bool {
        guard let window, event.window === window, window.attachedSheet == nil,
            !isEmbedded || hasKeyboard,
            !(window.firstResponder is NSText) || richText === window.firstResponder
        else { return false }
        return handleKey(event)
    }

    /// Runs what a key stands for in the Lister; false when the key means nothing here.
    @discardableResult
    internal func handleKey(_ event: NSEvent) -> Bool {
        if Shortcut(.character("\u{1B}")).matches(event) || event.keyCode == 53 {
            if let activity {
                activity.cancel.cancel()
                return true
            }
            guard !isEmbedded else {
                return false
            }
            onClose()
            return true
        }
        // Tab leaves the quick view for the file list it follows.
        if isEmbedded, Shortcut(.tab).matches(event) {
            kernel.panels.source.focus()
            return true
        }
        for menu in Self.menuTitles {
            for case let entry? in menuEntries(menu)
            where entry.isEnabled && entry.shortcuts.contains(where: { $0.matches(event) }) {
                entry.run()
                updateChrome()
                return true
            }
        }
        return handleNavigation(KeyPress(event))
    }

    /// Cursor keys and the keys of the media player.
    private func handleNavigation(_ key: KeyPress) -> Bool {
        if let mediaView {
            return handleMediaKey(key, in: mediaView)
        }
        if let imageView {
            return handleImageKey(key, in: imageView)
        }
        // Shown text is always in the pager, which is then the content.
        guard showsText, let motion = textMotion(for: key) else {
            return false
        }
        pager.perform(motion, extending: key.flags.contains(.shift))
        return true
    }

    /// The player's keys: Space, M, E, the volume on ↑ and ↓, 10 seconds on ← and → with a modifier.
    private func handleMediaKey(_ key: KeyPress, in mediaView: MediaView) -> Bool {
        let step: Float = key.flags.isEmpty ? 0.01 : 0.1
        if key.pressed(.space) {
            mediaView.togglePlaying()
        } else if key.pressed(.character("m")) {
            mediaView.toggleMute()
        } else if key.pressed(.character("e")) {
            mediaView.step()
        } else if key.named(.upArrow) {
            mediaView.changeVolume(by: step)
            settings.playerVolume = mediaView.volume
        } else if key.named(.downArrow) {
            mediaView.changeVolume(by: -step)
            settings.playerVolume = mediaView.volume
        } else if key.named(.leftArrow), !key.flags.isEmpty {
            mediaView.seek(by: -10)
        } else if key.named(.rightArrow), !key.flags.isEmpty {
            mediaView.seek(by: 10)
        } else {
            return false
        }
        return true
    }

    /// The arrows scroll the image, by less with Shift.
    private func handleImageKey(_ key: KeyPress, in imageView: ImageCanvasView) -> Bool {
        let step: CGFloat = key.flags.contains(.shift) ? 8 : 48
        if key.named(.leftArrow) {
            imageView.scroll(byX: -step, y: 0)
        } else if key.named(.rightArrow) {
            imageView.scroll(byX: step, y: 0)
        } else if key.named(.upArrow) {
            imageView.scroll(byX: 0, y: step)
        } else if key.named(.downArrow) {
            imageView.scroll(byX: 0, y: -step)
        } else {
            return false
        }
        return true
    }

    /// How a key moves in a text (spec 10 › Text modes); nil for a key that does not.
    private func textMotion(for key: KeyPress) -> TextPagerView.Motion? {
        let flags = key.flags
        let jump = flags.contains(.control) || flags.contains(.command)
        let word = flags.contains(.control) || flags.contains(.option)
        if key.named(.upArrow) {
            return jump && flags.contains(.command) ? .fileStart : .rowUp
        }
        if key.named(.downArrow) {
            return jump && flags.contains(.command) ? .fileEnd : .rowDown
        }
        if key.named(.leftArrow) {
            return word ? .wordLeft : flags.contains(.command) ? .rowStart : .left
        }
        if key.named(.rightArrow) {
            return word ? .wordRight : flags.contains(.command) ? .rowEnd : .right
        }
        if key.named(.pageUp) {
            return jump ? .fileStart : .pageUp
        }
        if key.named(.pageDown) || key.pressed(.space) {
            return jump ? .fileEnd : .pageDown
        }
        if key.named(.home) {
            return jump ? .fileStart : .rowStart
        }
        if key.named(.end) {
            return jump ? .fileEnd : .rowEnd
        }
        return nil
    }
}

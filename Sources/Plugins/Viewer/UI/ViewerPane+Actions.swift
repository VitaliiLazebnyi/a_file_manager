import AFMKernel
import AppKit

/// The entries of the menus of the strip: what each is called, its keys and what it does.
extension ViewerPane {
    /// A plain key, with `modifiers`.
    private static func key(_ character: String, _ modifiers: KeyModifiers = []) -> Shortcut {
        Shortcut(.character(character), modifiers)
    }

    /// The entries of one menu of the strip; nil is a separator.
    internal func menuEntries(_ menu: String) -> [ViewerAction?] {
        switch menu {
        case "File":
            return fileMenu()

        case "Edit":
            return editMenu() + placeEntries()

        case "Options":
            return modeEntries() + [nil] + fontEntries() + [nil] + textEntries() + [nil] + imageEntries() + [nil]
                + windowEntries()

        case "Encoding":
            return encodingMenu()

        default:
            return []
        }
    }

    /// Fills a menu of the strip, or the context menu, with entries.
    internal func fill(_ menu: NSMenu, with entries: [ViewerAction?]) {
        menu.autoenablesItems = false
        let style = NSMutableParagraphStyle()
        style.tabStops = [NSTextTab(textAlignment: .right, location: 300)]
        for entry in entries {
            guard let entry else {
                menu.addItem(.separator())
                continue
            }
            let item = NSMenuItem(title: entry.title, action: #selector(runMenuEntry(_:)), keyEquivalent: "")
            // The keys are shown, not bound: the pane handles the keyboard itself, the same
            // way whether or not a menu was ever opened.
            if let shortcut = entry.shortcuts.first {
                item.attributedTitle = NSAttributedString(
                    string: "\(entry.title)\t\(shortcut.displayText)",
                    attributes: [.paragraphStyle: style, .font: NSFont.menuFont(ofSize: 0)]
                )
            }
            item.target = self
            item.representedObject = entry.run
            item.isEnabled = entry.isEnabled
            item.state = entry.isChecked ? .on : .off
            menu.addItem(item)
        }
    }

    /// The action of every entry `fill` made: runs what the entry does.
    @objc
    internal func runMenuEntry(_ sender: NSMenuItem) {
        (sender.representedObject as? () -> Void)?()
        updateChrome()
    }

    /// File: open, save, step through the session, print, reload, edit, close.
    private func fileMenu() -> [ViewerAction?] {
        let several = fileCounter.count > 1
        return [
            ViewerAction(title: "Open…", shortcuts: [.cmd("o")]) { [weak self] in self?.openFile() },
            ViewerAction(title: "Save as…", isEnabled: loaded != nil) { [weak self] in self?.saveAs() },
            ViewerAction(
                title: "Next File",
                shortcuts: [Self.key("n"), Shortcut(.rightArrow, .option)],
                isEnabled: several
            ) { [weak self] in self?.onStep(1) },
            ViewerAction(
                title: "Previous",
                shortcuts: [Self.key("p"), Shortcut(.leftArrow, .option)],
                isEnabled: several
            ) { [weak self] in self?.onStep(-1) },
            ViewerAction(
                title: "Print…",
                shortcuts: [Self.key("p", .control), .cmd("p")],
                isEnabled: loaded != nil
            ) { [weak self] in self?.printContent() },
            ViewerAction(title: "Page Setup…", shortcuts: [.cmd("p", .shift)]) { [weak self] in self?.pageSetup() },
            ViewerAction(
                title: "Reload file",
                shortcuts: [.f(2), .cmd("r")],
                isEnabled: item != nil
            ) { [weak self] in self?.reload() },
            ViewerAction(title: "Edit", shortcuts: [.f(4)], isEnabled: canEdit) { [weak self] in self?.edit() },
            nil,
            ViewerAction(title: "Close", shortcuts: [Self.key("q"), .f(10)], isEnabled: !isEmbedded) { [weak self] in
                self?.onClose()
            }
        ]
    }

    /// Edit: copy, select all, find.
    private func editMenu() -> [ViewerAction?] {
        [
            ViewerAction(
                title: "Copy as text",
                shortcuts: [Self.key("c", .control), .cmd("c")],
                isEnabled: hasSelection
            ) { [weak self] in self?.copySelection(asHex: false) },
            ViewerAction(
                title: "Copy as hex",
                shortcuts: [Self.key("c", [.control, .shift]), .cmd("c", .shift)],
                isEnabled: hasSelection
            ) { [weak self] in
                self?.copySelection(asHex: true)
            },
            ViewerAction(
                title: "Select all",
                shortcuts: [Self.key("a", .control), .cmd("a")],
                isEnabled: showsText
            ) { [weak self] in self?.pager.selectAll() },
            nil,
            ViewerAction(
                title: "Find…",
                shortcuts: [.f(7), Self.key("f", .control), .cmd("f")],
                isEnabled: showsText
            ) { [weak self] in self?.find() },
            ViewerAction(
                title: "Find next",
                shortcuts: [.f(3), .f(5), .f(7, .shift), .cmd("g")],
                isEnabled: showsText
            ) { [weak self] in
                self?.findAgain(.same)
            },
            ViewerAction(
                title: "Find previous",
                shortcuts: [.f(3, .shift), .f(5, .shift), .cmd("g", .shift)],
                isEnabled: showsText
            ) { [weak self] in
                self?.findAgain(.backwards)
            },
            ViewerAction(
                title: "Find in the other direction",
                shortcuts: [.f(3, .control), .f(5, .control)],
                isEnabled: showsText
            ) { [weak self] in
                self?.findAgain(.reversed)
            }
        ]
    }

    /// The end of Edit: go to a position, an offset, a line.
    private func placeEntries() -> [ViewerAction?] {
        [
            nil,
            ViewerAction(
                title: "Go to position (in %)…",
                shortcuts: [Self.key("g", .control)],
                isEnabled: showsText
            ) { [weak self] in self?.goToPercent() },
            ViewerAction(
                title: "Go to offset…",
                shortcuts: [Self.key("o", .control)],
                isEnabled: showsText
            ) { [weak self] in self?.goToOffset() },
            ViewerAction(
                title: "Go to line…",
                shortcuts: [Self.key("l", .control), .cmd("l")],
                isEnabled: showsText
            ) { [weak self] in self?.goToLine() }
        ]
    }

    /// The start of Options: the display modes, by their keys 1…8.
    private func modeEntries() -> [ViewerAction?] {
        ViewMode.allCases.map { candidate in
            let available =
                loaded != nil && (candidate.isTextual || (!internalOnly && item?.url != nil))
                && (candidate != .preview || settings.usesQuickLook)
            return ViewerAction(
                title: "\(candidate.rawValue) \(candidate.title)",
                shortcuts: [Self.key(String(candidate.rawValue))],
                isEnabled: available,
                isChecked: mode == candidate
            ) { [weak self] in self?.setMode(candidate) }
        }
    }

    /// Options: the three fonts.
    private func fontEntries() -> [ViewerAction?] {
        [
            fontEntry("ANSI (Windows charset)", key: "a", slot: .ansi),
            fontEntry("ASCII (DOS charset)", key: "s", slot: .ascii),
            fontEntry("Variable char width", key: "v", slot: .variable)
        ]
    }

    /// The entry of one font, checked while it is in use without a code page of the Encoding menu.
    private func fontEntry(_ title: String, key: String, slot: FontSlot) -> ViewerAction {
        ViewerAction(
            title: title,
            shortcuts: [Self.key(key)],
            isEnabled: showsText,
            isChecked: showsText && fontSlot == slot && codePage == nil
        ) { [weak self] in
            self?.setFontSlot(slot)
        }
    }

    /// Options: wrapping, the text cursor, the size of the font or the zoom.
    private func textEntries() -> [ViewerAction?] {
        let isImage = imageView != nil
        return [
            ViewerAction(
                title: "Wrap text",
                shortcuts: [Self.key("w")],
                isEnabled: showsText && mode != .binary && mode != .hex,
                isChecked: settings.wrap
            ) { [weak self] in
                guard let self else {
                    return
                }
                settings.wrap.toggle()
                relayout()
            },
            ViewerAction(
                title: "Show text cursor",
                shortcuts: [.f(6)],
                isEnabled: showsText,
                isChecked: settings.caret
            ) { [weak self] in
                guard let self else {
                    return
                }
                settings.caret.toggle()
                pager.showsCaret = settings.caret
            },
            ViewerAction(
                title: "Larger",
                shortcuts: [
                    Shortcut(.keypadPlus), Self.key("+", .control), Self.key("=", .control), .cmd("="), .cmd("+")
                ],
                isEnabled: showsText || isImage
            ) { [weak self] in self?.zoom(1) },
            ViewerAction(
                title: "Smaller",
                shortcuts: [Shortcut(.keypadMinus), Self.key("-", .control), .cmd("-")],
                isEnabled: showsText || isImage
            ) { [weak self] in
                self?.zoom(-1)
            },
            ViewerAction(
                title: "Actual size",
                shortcuts: [Self.key("0", .control), .cmd("0")],
                isEnabled: showsText || isImage
            ) { [weak self] in self?.zoom(0) }
        ]
    }

    /// Options: fitting, centring and turning images.
    private func imageEntries() -> [ViewerAction?] {
        let isImage = imageView != nil
        return [
            ViewerAction(
                title: "Fit image to window",
                shortcuts: [Self.key("f")],
                isEnabled: isImage || mediaView != nil,
                isChecked: settings.imageFit == .window
            ) { [weak self] in
                self?.toggleFit(.window)
            },
            ViewerAction(
                title: "Fit only larger images to window",
                shortcuts: [Self.key("l")],
                isEnabled: isImage,
                isChecked: settings.imageFit == .largerOnly
            ) { [weak self] in
                self?.toggleFit(.largerOnly)
            },
            ViewerAction(
                title: "Center images",
                shortcuts: [Self.key("c")],
                isEnabled: isImage,
                isChecked: settings.centersImages
            ) { [weak self] in
                guard let self else {
                    return
                }
                settings.centersImages.toggle()
                imageView?.centered = settings.centersImages
            },
            ViewerAction(title: "Rotate right", shortcuts: [Self.key("r")], isEnabled: isImage) { [weak self] in
                self?.imageView?.rotate(by: 1)
            },
            ViewerAction(title: "Rotate left", shortcuts: [Self.key("r", .shift)], isEnabled: isImage) { [weak self] in
                self?.imageView?.rotate(by: -1)
            }
        ]
    }

    /// The end of Options: configuration and the window.
    private func windowEntries() -> [ViewerAction?] {
        [
            ViewerAction(title: "Configure…") { [weak self] in self?.onConfigure() },
            ViewerAction(
                title: "Full screen",
                shortcuts: [Shortcut(.returnKey, .option), .cmd("f", .control)],
                isEnabled: !isEmbedded
            ) { [weak self] in
                self?.dialogs.toggleFullScreen(self?.window)
            },
            ViewerAction(title: "Maximize", shortcuts: [.f(11)], isEnabled: !isEmbedded) { [weak self] in
                self?.dialogs.zoom(self?.window)
            },
            ViewerAction(title: "Save position", isEnabled: !isEmbedded) { [weak self] in self?.onSavePosition() }
        ]
    }

    /// Encoding: as configured, the Unicode modes, the code pages and those the user added.
    private func encodingMenu() -> [ViewerAction?] {
        let usesCodePage = showsText && mode != .utf8 && mode != .unicode
        var entries: [ViewerAction?] = [
            ViewerAction(
                title: "As configured for current font",
                isEnabled: showsText,
                isChecked: usesCodePage && codePage == nil
            ) { [weak self] in
                self?.setEncoding(nil)
            },
            nil
        ]
        let userPages = settings.userCodePages.compactMap(ViewerEncoding.codePage)
        for choice in [ViewerEncoding.utf8, .utf16LE, .utf16BE] + ViewerEncoding.codePages
            + userPages.filter({ !ViewerEncoding.codePages.contains($0) })
        {
            let isCurrent =
                showsText
                && (choice.isUnicode ? encoding == choice && !usesCodePage : usesCodePage && codePage == choice)
            entries.append(
                ViewerAction(title: choice.name, isEnabled: showsText, isChecked: isCurrent) { [weak self] in
                    self?.setEncoding(choice)
                }
            )
        }
        entries += [
            nil,
            ViewerAction(title: "Other (enter code page manually)…", isEnabled: showsText) { [weak self] in
                self?.askForCodePage()
            }
        ]
        return entries
    }
}

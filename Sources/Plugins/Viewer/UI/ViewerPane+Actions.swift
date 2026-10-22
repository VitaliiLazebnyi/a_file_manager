import AFMContracts
import AFMKernel
import AFMShell
import AppKit
import PDFKit

/// One entry of the Lister's menus: what it is called, its keys, whether it applies right now
/// and what it does.
///
/// The menus and the keyboard are both driven by the same list, so a key does exactly what its menu
/// entry does (spec 10 › Menu bar, 10 › General keys).
internal struct ViewerAction {
    internal let title: String
    internal var shortcuts: [Shortcut] = []
    internal var isEnabled = true
    internal var isChecked = false
    internal let run: () -> Void
}

extension Shortcut {
    /// The shortcut as a menu shows it: `⌃⇧C`, `F7`, `Num +`.
    internal var displayText: String {
        var text = ""
        if modifiers.contains(.control) { text += "⌃" }
        if modifiers.contains(.option) { text += "⌥" }
        if modifiers.contains(.shift) { text += "⇧" }
        if modifiers.contains(.command) { text += "⌘" }
        switch key {
        case .character(let character):
            return text + character.uppercased()

        case .function(let number):
            return text + "F\(number)"

        case .returnKey, .enter:
            return text + "↩"

        case .keypadPlus:
            return text + "Num +"

        case .keypadMinus:
            return text + "Num −"

        case .leftArrow:
            return text + "←"

        case .rightArrow:
            return text + "→"

        case .upArrow:
            return text + "↑"

        case .downArrow:
            return text + "↓"

        default:
            return text + notation
        }
    }
}

extension ViewerPane {
    // MARK: Search

    internal enum SearchDirection {
        case same, backwards, reversed
    }

    // MARK: Clipboard and context menu

    /// The most that is copied to the clipboard at once (the string goes to the pasteboard on
    /// the main thread; hex is half of this).
    internal static let copyLimit: Int64 = 16 << 20

    // MARK: Printing

    /// The most pages of text that are printed; a longer text is cut there, and the user is told.
    nonisolated internal static let printPageLimit = 2_000

    private var showsText: Bool { mode.isTextual && pager.document != nil }
    private var hasSelection: Bool { showsText && pager.selection != nil }

    /// F4 opens the editor, for files that are files and are shown as text (spec 10 › F4
    /// inside Lister).
    private var canEdit: Bool {
        guard let url = item?.url, mode.isTextual, !isEmbedded else {
            return false
        }
        return url.isFileURL && kernel.commands[.edit] != nil
    }

    /// A number as the user types it: `50.5`, `20,7`, `50 %`.
    internal static func number(in text: String) -> Double? {
        Double(
            text.replacingOccurrences(of: ",", with: ".").replacingOccurrences(of: "%", with: "")
                .trimmingCharacters(
                    in: .whitespaces
                )
        )
    }

    /// A byte offset as the user types it: decimal, or hexadecimal with `0x` or `$`.
    internal static func offset(in text: String) -> Int64? {
        let text = text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: "").lowercased()
        if text.hasPrefix("0x") {
            return Int64(text.dropFirst(2), radix: 16)
        }
        if text.hasPrefix("$") {
            return Int64(text.dropFirst(), radix: 16)
        }
        return Int64(text)
    }

    /// The link in `text` around UTF-16 index `index`: the word there, when it is a link.
    internal static func link(in text: String, at index: Int) -> URL? {
        let units = Array(text.utf16)
        var lower = min(index, units.count)
        var upper = lower
        while lower > 0, units[lower - 1] != 0x20 { lower -= 1 }
        while upper < units.count, units[upper] != 0x20 { upper += 1 }
        return HTMLText.url(from: String(decoding: units[lower..<upper], as: UTF16.self))
    }

    /// The work of Save as: `source` written to `target`, with its progress; the error, unless
    /// the user stopped it.
    nonisolated internal static func save(_ source: any ByteSource, to target: URL, monitor: any JobMonitor) -> (
        any Error
    )? {
        do {
            try ViewerSave.save(source, to: target, cancellation: monitor.cancellation) { offset in
                monitor.report(
                    JobProgress(
                        lines: ["To: \(target.path)"],
                        itemsDone: 0,
                        itemsTotal: 1,
                        bytesDone: offset,
                        bytesTotal: source.length
                    )
                )
            }
            return nil
        } catch {
            return monitor.cancellation.isCancelled ? nil : error
        }
    }

    /// The rows of `range` as the document's layout shows them, at most `maxRows` of them (`truncated`
    /// when there are more).
    ///
    /// Blocks.
    nonisolated internal static func printableText(
        of document: TextDocument,
        in range: Range<Int64>,
        maxRows: Int = printPageLimit * 60,
        cancellation: CancellationFlag = CancellationFlag()
    ) -> PrintableText {
        guard var row = (try? document.row(containing: range.lowerBound, cancellation: cancellation)) ?? nil else {
            return PrintableText(lines: [], truncated: false)
        }
        var lines: [String] = []
        while !cancellation.isCancelled,
            let rows = try? document.rows(from: row, count: 512, cancellation: cancellation), !rows.isEmpty
        {
            for line in rows {
                if line.range.lowerBound >= range.upperBound {
                    return PrintableText(lines: lines, truncated: false)
                }
                if lines.count >= maxRows {
                    return PrintableText(lines: lines, truncated: true)
                }
                lines.append(line.text)
            }
            row += rows.count
        }
        return PrintableText(lines: lines, truncated: false)
    }

    // MARK: The menus

    /// The entries of one menu of the strip; nil is a separator.
    internal func menuEntries(_ menu: String) -> [ViewerAction?] {
        func key(_ character: String, _ modifiers: KeyModifiers = []) -> Shortcut {
            Shortcut(.character(character), modifiers)
        }
        switch menu {
        case "File":
            let several = fileCounter.count > 1
            return [
                ViewerAction(title: "Open…", shortcuts: [.cmd("o")]) { [weak self] in self?.openFile() },
                ViewerAction(title: "Save as…", isEnabled: loaded != nil) { [weak self] in self?.saveAs() },
                ViewerAction(
                    title: "Next File",
                    shortcuts: [key("n"), Shortcut(.rightArrow, .option)],
                    isEnabled: several
                ) { [weak self] in self?.onStep(1) },
                ViewerAction(
                    title: "Previous",
                    shortcuts: [key("p"), Shortcut(.leftArrow, .option)],
                    isEnabled: several
                ) {
                    [weak self] in self?.onStep(-1)
                },
                ViewerAction(title: "Print…", shortcuts: [key("p", .control), .cmd("p")], isEnabled: loaded != nil) {
                    [weak self] in self?.printContent()
                },
                ViewerAction(title: "Page Setup…", shortcuts: [.cmd("p", .shift)]) { [weak self] in self?.pageSetup() },
                ViewerAction(title: "Reload file", shortcuts: [.f(2), .cmd("r")], isEnabled: item != nil) {
                    [weak self] in self?.reload()
                },
                ViewerAction(title: "Edit", shortcuts: [.f(4)], isEnabled: canEdit) { [weak self] in self?.edit() },
                nil,
                ViewerAction(title: "Close", shortcuts: [key("q"), .f(10)], isEnabled: !isEmbedded) { [weak self] in
                    self?.onClose()
                }
            ]

        case "Edit":
            return [
                ViewerAction(
                    title: "Copy as text",
                    shortcuts: [key("c", .control), .cmd("c")],
                    isEnabled: hasSelection
                ) { [weak self] in self?.copySelection(asHex: false) },
                ViewerAction(
                    title: "Copy as hex",
                    shortcuts: [key("c", [.control, .shift]), .cmd("c", .shift)],
                    isEnabled: hasSelection
                ) { [weak self] in
                    self?.copySelection(asHex: true)
                },
                ViewerAction(title: "Select all", shortcuts: [key("a", .control), .cmd("a")], isEnabled: showsText) {
                    [weak self] in self?.pager.selectAll()
                },
                nil,
                ViewerAction(title: "Find…", shortcuts: [.f(7), key("f", .control), .cmd("f")], isEnabled: showsText) {
                    [weak self] in self?.find()
                },
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
                },
                nil,
                ViewerAction(title: "Go to position (in %)…", shortcuts: [key("g", .control)], isEnabled: showsText) {
                    [weak self] in self?.goToPercent()
                },
                ViewerAction(title: "Go to offset…", shortcuts: [key("o", .control)], isEnabled: showsText) {
                    [weak self] in self?.goToOffset()
                },
                ViewerAction(title: "Go to line…", shortcuts: [key("l", .control), .cmd("l")], isEnabled: showsText) {
                    [weak self] in self?.goToLine()
                }
            ]

        case "Options":
            let isImage = imageView != nil
            let isMedia = mediaView != nil
            var entries: [ViewerAction?] = ViewMode.allCases.map { candidate in
                let available =
                    loaded != nil && (candidate.isTextual || (!internalOnly && item?.url != nil))
                    && (candidate != .preview || settings.usesQuickLook)
                return ViewerAction(
                    title: "\(candidate.rawValue) \(candidate.title)",
                    shortcuts: [key(String(candidate.rawValue))],
                    isEnabled: available,
                    isChecked: mode == candidate
                ) { [weak self] in self?.setMode(candidate) }
            }
            let fonts: [(String, String, FontSlot)] = [
                ("ANSI (Windows charset)", "a", .ansi), ("ASCII (DOS charset)", "s", .ascii),
                ("Variable char width", "v", .variable)
            ]
            entries.append(nil)
            entries += fonts.map { title, character, slot in
                ViewerAction(
                    title: title,
                    shortcuts: [key(character)],
                    isEnabled: showsText,
                    isChecked: showsText && fontSlot == slot && codePage == nil
                ) { [weak self] in
                    self?.setFontSlot(slot)
                }
            }
            entries += [
                nil,
                ViewerAction(
                    title: "Wrap text",
                    shortcuts: [key("w")],
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
                    shortcuts: [Shortcut(.keypadPlus), key("+", .control), key("=", .control), .cmd("="), .cmd("+")],
                    isEnabled: showsText || isImage
                ) { [weak self] in self?.zoom(1) },
                ViewerAction(
                    title: "Smaller",
                    shortcuts: [Shortcut(.keypadMinus), key("-", .control), .cmd("-")],
                    isEnabled: showsText || isImage
                ) { [weak self] in
                    self?.zoom(-1)
                },
                ViewerAction(
                    title: "Actual size",
                    shortcuts: [key("0", .control), .cmd("0")],
                    isEnabled: showsText || isImage
                ) { [weak self] in self?.zoom(0) },
                nil,
                ViewerAction(
                    title: "Fit image to window",
                    shortcuts: [key("f")],
                    isEnabled: isImage || isMedia,
                    isChecked: settings.imageFit == .window
                ) { [weak self] in
                    self?.toggleFit(.window)
                },
                ViewerAction(
                    title: "Fit only larger images to window",
                    shortcuts: [key("l")],
                    isEnabled: isImage,
                    isChecked: settings.imageFit == .largerOnly
                ) { [weak self] in
                    self?.toggleFit(.largerOnly)
                },
                ViewerAction(
                    title: "Center images",
                    shortcuts: [key("c")],
                    isEnabled: isImage,
                    isChecked: settings.centersImages
                ) { [weak self] in
                    guard let self else {
                        return
                    }
                    settings.centersImages.toggle()
                    imageView?.centered = settings.centersImages
                },
                ViewerAction(title: "Rotate right", shortcuts: [key("r")], isEnabled: isImage) { [weak self] in
                    self?.imageView?.rotate(by: 1)
                },
                ViewerAction(title: "Rotate left", shortcuts: [key("r", .shift)], isEnabled: isImage) { [weak self] in
                    self?.imageView?.rotate(by: -1)
                },
                nil,
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
            return entries

        case "Encoding":
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
            for encoding in [ViewerEncoding.utf8, .utf16LE, .utf16BE] + ViewerEncoding.codePages
                + userPages.filter({ !ViewerEncoding.codePages.contains($0) })
            {
                let isCurrent =
                    showsText
                    && (encoding.isUnicode
                        ? self.encoding == encoding && !usesCodePage : usesCodePage && codePage == encoding)
                entries.append(
                    ViewerAction(title: encoding.name, isEnabled: showsText, isChecked: isCurrent) { [weak self] in
                        self?.setEncoding(encoding)
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

    @objc
    internal func runMenuEntry(_ sender: NSMenuItem) {
        (sender.representedObject as? () -> Void)?()
        updateChrome()
    }

    // MARK: Keyboard

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
        return handleNavigation(event)
    }

    /// Cursor keys and the keys of the media player.
    private func handleNavigation(_ event: NSEvent) -> Bool {
        let flags = KeyModifiers(
            rawValue: (event.modifierFlags.contains(.shift) ? 1 : 0) | (event.modifierFlags.contains(.control) ? 2 : 0)
                | (event.modifierFlags.contains(.option) ? 4 : 0) | (event.modifierFlags.contains(.command) ? 8 : 0)
        )
        func pressed(_ key: Key, _ modifiers: KeyModifiers = []) -> Bool { Shortcut(key, modifiers).matches(event) }
        func named(_ key: Key) -> Bool { Shortcut(key, flags).matches(event) }
        let shift = flags.contains(.shift)
        let jump = flags.contains(.control) || flags.contains(.command)
        let word = flags.contains(.control) || flags.contains(.option)
        if let mediaView {
            let step: Float = flags.isEmpty ? 0.01 : 0.1
            if pressed(.space) {
                mediaView.togglePlaying()
            } else if pressed(.character("m")) {
                mediaView.toggleMute()
            } else if pressed(.character("e")) {
                mediaView.step()
            } else if named(.upArrow) {
                mediaView.changeVolume(by: step)
                settings.playerVolume = mediaView.volume
            } else if named(.downArrow) {
                mediaView.changeVolume(by: -step)
                settings.playerVolume = mediaView.volume
            } else if named(.leftArrow), !flags.isEmpty {
                mediaView.seek(by: -10)
            } else if named(.rightArrow), !flags.isEmpty {
                mediaView.seek(by: 10)
            } else {
                return false
            }
            return true
        }
        if let imageView {
            let step: CGFloat = shift ? 8 : 48
            if named(.leftArrow) {
                imageView.scroll(byX: -step, y: 0)
            } else if named(.rightArrow) {
                imageView.scroll(byX: step, y: 0)
            } else if named(.upArrow) {
                imageView.scroll(byX: 0, y: step)
            } else if named(.downArrow) {
                imageView.scroll(byX: 0, y: -step)
            } else {
                return false
            }
            return true
        }
        // Shown text is always in the pager, which is then the content.
        guard showsText else {
            return false
        }
        let motion: TextPagerView.Motion
        if named(.upArrow) {
            motion = jump && flags.contains(.command) ? .fileStart : .up
        } else if named(.downArrow) {
            motion = jump && flags.contains(.command) ? .fileEnd : .down
        } else if named(.leftArrow) {
            motion = word ? .wordLeft : flags.contains(.command) ? .rowStart : .left
        } else if named(.rightArrow) {
            motion = word ? .wordRight : flags.contains(.command) ? .rowEnd : .right
        } else if named(.pageUp) {
            motion = jump ? .fileStart : .pageUp
        } else if named(.pageDown) || pressed(.space) {
            motion = jump ? .fileEnd : .pageDown
        } else if named(.home) {
            motion = jump ? .fileStart : .rowStart
        } else if named(.end) {
            motion = jump ? .fileEnd : .rowEnd
        } else {
            return false
        }
        pager.perform(motion, extending: shift)
        return true
    }

    // MARK: Options

    internal func setFontSlot(_ slot: FontSlot) {
        fontSlot = slot
        codePage = nil
        if mode == .html {
            // The tags of an HTML file are removed from its bytes: with the new encoding.
            redecodeHTML()
            present()
            return
        }
        relayout()
    }

    /// The Encoding menu: a code page for text mode, or one of the Unicode modes.
    internal func setEncoding(_ encoding: ViewerEncoding?) {
        guard loaded != nil else {
            return
        }
        switch encoding?.kind {
        case .utf8:
            mode = .utf8

        case .utf16LE, .utf16BE:
            codePage = encoding
            mode = .unicode

        default:
            codePage = encoding
            if mode == .utf8 || mode == .unicode { mode = .text }
        }
        redecodeHTML()
        present()
    }

    /// "Other (enter code page manually)": a number is used for now, `Name (number)` is also
    /// added to the menu (spec 10 › Encoding menu).
    internal func askForCodePage() {
        guard
            let answer = kernel.interaction.prompt(
                "Code page",
                value: "",
                detail: "A number such as 866, or \"Name (866)\" to keep it in the menu."
            )
        else { return }
        let digits =
            answer.contains("(")
            ? answer.split(separator: "(").last.map { $0.prefix { $0.isNumber } }.map(String.init) ?? "" : answer
        guard let number = Int(digits.trimmingCharacters(in: .whitespaces)),
            let encoding = ViewerEncoding.codePage(number)
        else {
            kernel.interaction.inform("The code page \(answer) is not available on this Mac.")
            return
        }
        if answer.contains("("), !settings.userCodePages.contains(number) { settings.userCodePages.append(number) }
        setEncoding(encoding)
    }

    private func zoom(_ direction: Int) {
        if let imageView {
            imageView.setZoom(direction == 0 ? 1 : imageView.zoom * (direction > 0 ? 1.25 : 0.8))
        } else {
            changeFontSize(by: Double(direction))
        }
    }

    private func toggleFit(_ fit: ImageFit) {
        if let mediaView {
            mediaView.toggleFit()
            return
        }
        settings.imageFit = settings.imageFit == fit ? .none : fit
        imageView?.fit = settings.imageFit
    }

    // MARK: Going to a place

    /// "Go to position (in %)": decimals with `.` or `,` (spec 10 › Position and zoom item).
    ///
    /// In image mode the same item sets the zoom factor.
    internal func goToPercent() {
        let isImage = imageView != nil
        guard isImage || showsText,
            let answer = kernel.interaction.prompt(
                isImage ? "Zoom (in %)" : "Go to position (in %)",
                value: percentText.replacingOccurrences(of: " %", with: "")
            ),
            let value = Self.number(in: answer)
        else { return }
        if let imageView { imageView.setZoom(CGFloat(value / 100)) } else { pager.scroll(toPercent: value) }
    }

    internal func goToOffset() {
        guard let document = pager.document,
            let answer = kernel.interaction.prompt(
                "Go to offset",
                value: "",
                detail: "Decimal, or hexadecimal as 0x1F40."
            ),
            let offset = Self.offset(in: answer)
        else { return }
        pager.reveal(offset: min(max(0, offset), max(0, document.length - 1)))
    }

    internal func goToLine() {
        guard showsText, let answer = kernel.interaction.prompt("Go to line", value: ""),
            let line = Int(answer.trimmingCharacters(in: .whitespaces))
        else { return }
        pager.scroll(toLine: line) { [weak self] found in
            guard let self, !found else {
                return
            }
            kernel.interaction.inform(
                pager.isIndexing
                    ? "Line \(line) has not been read yet; try again in a moment." : "There is no line \(line)."
            )
        }
    }

    /// The Find dialog (spec 10 › Find dialog).
    internal func find() {
        guard showsText else {
            return
        }
        let options = lastSearch?.options ?? settings.searchOptions
        let history = settings.searchHistory
        var fields: [FormField] = [.text("text", "Enter search text:", lastSearch?.text ?? history.first ?? "")]
        if history.count > 1 {
            fields.append(.choice("history", "Earlier searches:", ["(as typed above)"] + history, selected: 0))
        }
        fields += [
            .checkbox("words", "Whole words only", options.wholeWords),
            .checkbox("case", "Case sensitive", options.caseSensitive),
            .checkbox("backwards", "Search backwards", options.backwards),
            .checkbox("hex", "Search hex string", options.hex),
            .checkbox("regex", "RegEx", options.regex)
        ]
        guard let answer = kernel.interaction.form("Find", detail: "", fields: fields, buttons: ["OK"]) else {
            return
        }
        let picked = answer.index("history")
        let text = picked > 0 && picked <= history.count ? history[picked - 1] : answer.text("text")
        let chosen = SearchOptions(
            wholeWords: answer.flag("words"),
            caseSensitive: answer.flag("case"),
            backwards: answer.flag("backwards"),
            hex: answer.flag("hex"),
            regex: answer.flag("regex")
        )
        guard !text.isEmpty else {
            return
        }
        lastSearch = (text, chosen)
        settings.searchOptions = chosen
        settings.searchHistory = [text] + history.filter { $0 != text }
        search(backwards: chosen.backwards)
    }

    /// F3 / Shift+F3 / Ctrl+F3 (spec 10 › Result and repeating).
    internal func findAgain(_ direction: SearchDirection) {
        guard let lastSearch else {
            find()
            return
        }
        switch direction {
        case .same:
            search(backwards: lastSearch.options.backwards)

        case .backwards:
            search(backwards: true)

        case .reversed:
            search(backwards: !lastSearchWentBackwards)
        }
    }

    /// Searches the whole file from the current place on, off the main thread, with progress
    /// in the status line; Esc or Cancel stops it.
    internal func search(backwards: Bool) {
        guard let lastSearch, let document = pager.document, let loaded, activity == nil else {
            return
        }
        let pattern: SearchPattern
        do {
            pattern = try SearchPattern(lastSearch.text, options: lastSearch.options, encoding: document.encoding)
        } catch {
            kernel.interaction.report(error, title: "Find")
            return
        }
        lastSearchWentBackwards = backwards
        let cancel = CancellationFlag()
        let generation = loadGeneration
        let start = pager.searchStart(backwards: backwards)
        activity = ("Searching for \"\(lastSearch.text)\"…", 0, cancel)
        let parallelism = loaded.parallel ? ProcessInfo.processInfo.activeProcessorCount : 1
        workQueue.async { [weak self] in
            // The tables of a double-byte code page take a moment to build: not on the main thread.
            let boundaries = document.characterBoundaries
            var lastReport = Date.distantPast
            let result = Result {
                try ViewerSearch.find(
                    pattern,
                    in: document.source,
                    content: document.content,
                    from: start,
                    backwards: backwards,
                    encoding: document.encoding,
                    parallelism: parallelism,
                    cancellation: cancel,
                    boundaries: boundaries
                ) { fraction in
                    guard Date().timeIntervalSince(lastReport) > 0.1 else {
                        return
                    }
                    lastReport = Date()
                    DispatchQueue.main.async {
                        guard let self, self.activity?.cancel === cancel else {
                            return
                        }
                        self.activity?.progress = fraction
                    }
                }
            }
            DispatchQueue.main.async {
                self?.searchFinished(result, for: lastSearch.text, in: document, generation: generation, cancel: cancel)
            }
        }
    }

    /// Shows what a search found; nothing when the file or the search changed meanwhile.
    internal func searchFinished(
        _ result: Result<Range<Int64>?, any Error>,
        for text: String,
        in document: TextDocument,
        generation: Int,
        cancel: CancellationFlag
    ) {
        if activity?.cancel === cancel { activity = nil }
        guard loadGeneration == generation, pager.document?.source === document.source, !cancel.isCancelled else {
            return
        }
        switch result {
        case .success(let match?):
            pager.reveal(offset: match.lowerBound, select: match, rowsAbove: settings.searchGoBack)

        case .success(nil):
            kernel.interaction.inform("\"\(text)\" was not found.")

        case .failure(let error):
            kernel.interaction.report(error, title: "Find")
        }
    }

    /// Copies the selection as text or as hexadecimal values (spec 10 › Selection and
    /// clipboard).
    ///
    /// The bytes are read in the background.
    internal func copySelection(asHex: Bool, completion: @escaping @MainActor @Sendable () -> Void = {}) {
        guard let document = pager.document, let selection = pager.selection else {
            return
        }
        // Hex is three characters a byte; the string is made on the main thread for the clipboard.
        let limit = asHex ? Self.copyLimit / 2 : Self.copyLimit
        guard selection.upperBound - selection.lowerBound <= limit else {
            kernel.interaction.inform(
                "The selection is too large for the clipboard (more than \(Format.shortSize(limit)))."
            )
            return
        }
        // Carried through the background and used on the main thread only.
        let pasteboard = Handover(pasteboard)
        let cancellation = cancellation
        workQueue.async {
            let text =
                asHex
                ? (try? document.source.read(selection, cancellation: cancellation)).map(HexFormat.hexString)
                : try? document.text(in: selection, cancellation: cancellation)
            DispatchQueue.main.async {
                if let text {
                    pasteboard.value.clearContents()
                    pasteboard.value.setString(text, forType: .string)
                }
                completion()
            }
        }
    }

    /// The context menu (spec 10 › Context menu rules): with a selection, the copy commands
    /// and what can be done with a link; without one, only on a link.
    internal func makeContextMenu() -> NSMenu? {
        guard showsText, let window else {
            return nil
        }
        var link: URL?
        if pager.selection == nil, let hit = pager.text(at: window.mouseLocationOutsideOfEventStream) {
            link = Self.link(in: hit.text, at: hit.index)
            guard link != nil else {
                return nil
            }
        }
        var entries: [ViewerAction?] = []
        if pager.selection != nil {
            entries += [
                ViewerAction(title: "Copy as text") { [weak self] in self?.copySelection(asHex: false) },
                ViewerAction(title: "Copy as hex") { [weak self] in self?.copySelection(asHex: true) },
                ViewerAction(title: "Search the web for the selection") { [weak self] in
                    self?
                        .withSelectedText { text in
                            var components = URLComponents(string: "https://www.google.com/search")
                            components?.queryItems = [URLQueryItem(name: "q", value: text)]
                            if let url = components?.url { self?.links.open(url) }
                        }
                },
                ViewerAction(title: "Open the selection as a link in the browser") { [weak self] in
                    self?
                        .withSelectedText { text in
                            if let url = HTMLText.url(from: text) { self?.links.open(url) }
                        }
                }
            ]
        }
        if let link {
            let pasteboard = pasteboard
            entries += [
                ViewerAction(title: "Copy URL") {
                    pasteboard.clearContents()
                    pasteboard.setString(link.absoluteString, forType: .string)
                },
                ViewerAction(title: "Open in the default browser") { [weak self] in self?.links.open(link) }
            ]
        }
        if !htmlLinks.isEmpty {
            let pasteboard = pasteboard
            let links = htmlLinks
            entries.append(
                ViewerAction(title: "Copy all URLs") {
                    pasteboard.clearContents()
                    pasteboard.setString(links.joined(separator: "\n"), forType: .string)
                }
            )
        }
        let menu = NSMenu()
        fill(menu, with: entries)
        return menu
    }

    private func withSelectedText(_ action: @escaping @MainActor @Sendable (String) -> Void) {
        guard let document = pager.document, let selection = pager.selection, selection.count <= 4_096 else {
            return
        }
        workQueue.async {
            guard let text = try? document.text(in: selection) else {
                return
            }
            DispatchQueue.main.async { action(text) }
        }
    }

    // MARK: File menu

    private func openFile() {
        guard let url = dialogs.fileToOpen() else {
            return
        }
        load(ViewerItem(source: .file(url), title: kernel.fileSystems.displayPath(url)))
    }

    /// Saves what is shown under another name: meant for files that came out of an archive or
    /// from a server (spec 10 › File menu behaviour).
    ///
    /// Runs as a job with a progress window.
    private func saveAs() {
        guard let loaded else {
            return
        }
        guard let target = dialogs.saveTarget(proposing: loaded.item.url?.lastPathComponent ?? loaded.item.title)
        else { return }
        // The file that is shown is read while the copy is written: it is not replaced.
        guard !ViewerSave.isSameFile(loaded.item.url, target) else {
            kernel.interaction.inform(
                "The file is being shown from the place you chose. Choose another file name or folder."
            )
            return
        }
        let source = loaded.source
        kernel.jobs.run(
            title: "Save as",
            work: { monitor in Self.save(source, to: target, monitor: monitor) },
            completion: { [weak self] error in
                if let error { self?.kernel.interaction.report(error, title: "Save as") }
                self?.kernel.panels.refresh([target.deletingLastPathComponent()])
            }
        )
    }

    private func edit() {
        guard let url = item?.url else {
            return
        }
        kernel.commands.perform(.edit, .location(url))
    }

    private func printInfo() -> NSPrintInfo {
        var attributes: [NSPrintInfo.AttributeKey: Any] = [:]
        for case (let key as String, let value) in NSPrintInfo.shared.dictionary() {
            attributes[NSPrintInfo.AttributeKey(key)] = value
        }
        let info = NSPrintInfo(dictionary: attributes)
        if let margins = settings.printMargins, margins.count == 4 {
            (info.leftMargin, info.rightMargin, info.topMargin, info.bottomMargin) = (
                margins[0], margins[1], margins[2], margins[3]
            )
        }
        info.horizontalPagination = .fit
        info.isVerticallyCentered = false
        return info
    }

    /// File › Page Setup (the specification's Print setup): paper and margins.
    internal func pageSetup() {
        let info = printInfo()
        guard dialogs.pageLayout(info) else {
            return
        }
        NSPrintInfo.shared = info
        settings.printMargins = [info.leftMargin, info.rightMargin, info.topMargin, info.bottomMargin]
    }

    /// File › Print (spec 10 › Printing from Lister): text prints as the current mode shows
    /// it, the selection when there is one and the user wants it; images, PDF and pages print
    /// as themselves.
    ///
    /// The print panel is a sheet of the window the user printed from, taken now: a text is
    /// prepared first, and the pane may have left that window by the time it is ready. A pane in
    /// no window has nothing to print from.
    internal func printContent() {
        guard let window else {
            return
        }
        let info = printInfo()
        let run = { [dialogs] (operation: NSPrintOperation) in dialogs.run(operation, sheetOf: window) }
        if let frame = imageView?.currentFrame {
            let area = info.imageablePageBounds.size
            let size = NSSize(width: frame.width, height: frame.height)
            let fitting = min(area.width / size.width, area.height / size.height)
            // Fit to window enlarges small images to the page too; otherwise an image is only
            // ever shrunk to fit (spec 10 › File › Print).
            let scale = settings.imageFit == .window ? fitting : min(1, fitting)
            let view = NSImageView(frame: NSRect(x: 0, y: 0, width: size.width * scale, height: size.height * scale))
            view.image = NSImage(cgImage: frame, size: size)
            view.imageScaling = .scaleAxesIndependently
            run(NSPrintOperation(view: view, printInfo: info))
        } else if let pdfView {
            dialogs.print(pdfView, with: info)
        } else if let webView {
            run(webView.printOperation(with: info))
        } else if let richText {
            run(NSPrintOperation(view: richText, printInfo: info))
        } else if showsText, let document = pager.document {
            var range = document.content
            if let selection = pager.selection,
                kernel.interaction.choose(
                    "Print",
                    detail: "Print the selected text or the whole file?",
                    buttons: ["Selection", "Whole file"],
                    style: .information
                ) == 0
            {
                range = selection
            }
            let font = currentFont
            let generation = loadGeneration
            let page = TextPrintView.pageSize(for: info)
            let linesPerPage = TextPrintView.linesPerPage(font: font, pageHeight: page.height)
            let cancel = CancellationFlag()
            activity = ("Preparing to print…", nil, cancel)
            // Made on the main thread and used there only, by the block that comes back.
            let held = Handover((font: font, info: info))
            // Weakly: the block must not be the last owner of the window or the pane on its thread
            // (a view goes away on the main thread).
            workQueue.async { [weak self, weak window, range] in
                let text = Self.printableText(
                    of: document,
                    in: range,
                    maxRows: Self.printPageLimit * linesPerPage,
                    cancellation: cancel
                )
                DispatchQueue.main.async {
                    self?
                        .textPrepared(text, generation: generation, cancel: cancel, sheetOf: window) {
                            NSPrintOperation(
                                view: TextPrintView(lines: text.lines, font: held.value.font, pageSize: page),
                                printInfo: held.value.info
                            )
                        }
                }
            }
        }
    }

    /// Prints the text that was prepared (`operation` makes the print operation) with its panel
    /// as a sheet of `window`, telling the user when it was cut short; nothing when the file
    /// changed, printing was stopped or the window has gone.
    private func textPrepared(
        _ text: PrintableText,
        generation: Int,
        cancel: CancellationFlag,
        sheetOf window: NSWindow?,
        operation: () -> NSPrintOperation
    ) {
        if activity?.cancel === cancel { activity = nil }
        guard loadGeneration == generation, !cancel.isCancelled, let window else {
            return
        }
        if text.truncated {
            kernel.interaction.inform(
                "The text is longer than the \(Self.printPageLimit) pages that are printed at most: only its first \(Self.printPageLimit) pages (\(text.lines.count) lines) are printed."
            )
        }
        dialogs.run(operation(), sheetOf: window)
    }
}

/// The rows chosen for printing.
internal struct PrintableText {
    internal var lines: [String]
    internal var truncated: Bool
    /// The rows, each ended by a line end.
    internal var text: String { lines.map { $0 + "\n" }.joined() }
}

/// The pages of a text for printing: the rows are drawn page by page as the print operation asks
/// for them, so nothing is laid out beforehand (a text view would lay out all of it on the main
/// thread before the first page could come out).
internal final class TextPrintView: NSView {
    internal let lines: [String]
    private let font: NSFont
    private let lineHeight: CGFloat
    private let linesPerPage: Int
    private let pageSize: NSSize
    private let attributes: [NSAttributedString.Key: Any]

    internal var pageCount: Int { max(1, (lines.count + linesPerPage - 1) / linesPerPage) }

    override internal var isFlipped: Bool { true }

    internal init(lines: [String], font: NSFont, pageSize: NSSize) {
        self.lines = lines
        self.font = font
        self.pageSize = pageSize
        lineHeight = Self.lineHeight(of: font)
        linesPerPage = Self.linesPerPage(font: font, pageHeight: pageSize.height)
        attributes = [.font: font, .foregroundColor: NSColor.black]
        // Wider than the page when a row is: the print operation then shrinks the page to fit.
        let widest = CGFloat(min(2_000, lines.reduce(0) { max($0, $1.utf16.count) })) * font.maximumAdvancement.width
        let pages = max(1, (lines.count + linesPerPage - 1) / linesPerPage)
        super
            .init(
                frame: NSRect(
                    x: 0,
                    y: 0,
                    width: max(pageSize.width, widest),
                    height: CGFloat(pages * linesPerPage) * lineHeight
                )
            )
    }

    /// Made in code only: an archive gives none.
    internal required init?(coder _: NSCoder) { nil }

    /// The area of a page the text goes on.
    internal static func pageSize(for info: NSPrintInfo) -> NSSize {
        NSSize(
            width: max(100, info.paperSize.width - info.leftMargin - info.rightMargin),
            height: max(100, info.paperSize.height - info.topMargin - info.bottomMargin)
        )
    }

    internal static func lineHeight(of font: NSFont) -> CGFloat {
        max(1, ceil(font.ascender - font.descender + font.leading))
    }

    internal static func linesPerPage(font: NSFont, pageHeight: CGFloat) -> Int {
        max(1, Int(pageHeight / lineHeight(of: font)))
    }

    override internal func knowsPageRange(_ range: NSRangePointer) -> Bool {
        range.pointee = NSRange(location: 1, length: pageCount)
        return true
    }

    override internal func rectForPage(_ page: Int) -> NSRect {
        NSRect(
            x: 0,
            y: CGFloat((page - 1) * linesPerPage) * lineHeight,
            width: frame.width,
            height: CGFloat(linesPerPage) * lineHeight
        )
    }

    override internal func draw(_ dirtyRect: NSRect) {
        guard !lines.isEmpty else {
            return
        }
        let first = max(0, Int(dirtyRect.minY / lineHeight))
        let last = min(lines.count - 1, Int(dirtyRect.maxY / lineHeight))
        guard first <= last else {
            return
        }
        for index in first...last {
            (lines[index] as NSString)
                .draw(
                    at: NSPoint(x: 0, y: CGFloat(index) * lineHeight),
                    withAttributes: attributes
                )
        }
    }
}

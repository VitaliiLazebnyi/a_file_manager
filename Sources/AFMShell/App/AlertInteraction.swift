public import AFMKernel
public import AppKit

/// Asks the user with standard alerts.
final class AlertInteraction: UserInteraction {
    init() {}

    private func alert(_ message: String, _ detail: String, _ style: QuestionStyle) -> NSAlert {
        let alert = NSAlert()
        // Messages name files; a name must not be able to write lines of its own into a
        // question, or to show its letters in another order than they have.
        alert.messageText = DisplayText.clean(message, keepingLines: true)
        alert.informativeText = DisplayText.clean(detail, keepingLines: true)
        switch style {
        case .information: alert.alertStyle = .informational
        case .warning: alert.alertStyle = .warning
        case .critical: alert.alertStyle = .critical
        }
        return alert
    }

    func prompt(_ message: String, value: String, detail: String) -> String? {
        let alert = alert(message, detail, .information)
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(string: value)
        field.frame = NSRect(x: 0, y: 0, width: 460, height: 24)
        field.lineBreakMode = .byTruncatingHead
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        return alert.runModal() == .alertFirstButtonReturn ? field.stringValue : nil
    }

    /// Return presses the first button, except in a critical question (one that destroys
    /// something for good, or trusts somebody): there it presses the last one, the one that
    /// changes nothing, so a reflexive Return never answers it with yes. Esc takes the last
    /// button in every question.
    func choose(_ message: String, detail: String, buttons: [String], style: QuestionStyle) -> Int {
        choose(
            message, detail: detail, buttons: buttons, style: style,
            defaultButton: Self.defaultButton(for: style, of: buttons))
    }

    /// The same with the caller's say in which button Return presses; nil for none, where the
    /// user has to click, or to press Esc for the last one.
    func choose(_ message: String, detail: String, buttons: [String], style: QuestionStyle, defaultButton: Int?)
        -> Int
    {
        let alert = makeQuestion(message, detail: detail, buttons: buttons, style: style, defaultButton: defaultButton)
        // Esc on a last button that is also Return's: a button has one key of its own.
        var monitor: Any?
        if let last = alert.buttons.last, last.keyEquivalent != "\u{1b}" {
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak alert] event in
                guard event.keyCode == 53, let alert, event.window === alert.window else { return event }
                alert.buttons.last?.performClick(nil)
                return nil
            }
        }
        defer { monitor.map(NSEvent.removeMonitor) }
        return alert.runModal().rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
    }

    /// The button Return presses when the question does not say: the last one for a critical
    /// question with a choice, the first one otherwise.
    static func defaultButton(for style: QuestionStyle, of buttons: [String]) -> Int? {
        guard !buttons.isEmpty else { return nil }
        return style == .critical && buttons.count > 1 ? buttons.count - 1 : 0
    }

    /// Builds a question without showing it. The keys are set here for every button, whatever
    /// the system would give them by their titles: Return for `defaultButton` and for no
    /// other, Esc for the last one (unless that is Return's already; `choose` sees to Esc then).
    func makeQuestion(_ message: String, detail: String, buttons: [String], style: QuestionStyle, defaultButton: Int?)
        -> NSAlert
    {
        let alert = alert(message, detail, style)
        buttons.forEach { alert.addButton(withTitle: DisplayText.clean($0)) }
        let wanted = defaultButton.flatMap { alert.buttons.indices.contains($0) ? $0 : nil }
        for (index, button) in alert.buttons.enumerated() {
            if index == wanted {
                button.keyEquivalent = "\r"
            } else {
                button.keyEquivalent = index == alert.buttons.count - 1 ? "\u{1b}" : ""
            }
            button.keyEquivalentModifierMask = []
        }
        // Without a button for Return, none is drawn as the one Return would press, and the
        // keyboard starts on the last one (Space presses it), not on a destructive first.
        if wanted == nil { alert.window.initialFirstResponder = alert.buttons.last }
        return alert
    }

    func inform(_ message: String, detail: String, style: QuestionStyle) {
        alert(message, detail, style).runModal()
    }

    /// A message near the bottom of the main window that goes away by itself; clicks go
    /// through it to what lies below.
    func notice(_ message: String) {
        Notice.show(message, over: NSApp.mainWindow ?? NSApp.keyWindow)
    }

    func form(_ title: String, detail: String, fields: [FormField], buttons: [String]) -> FormValues? {
        FormDialog(fields: fields).run(title: title, detail: detail, buttons: buttons)
    }
}

/// Settings kept in the macOS preferences.
///
/// A value that may be large (`setLarge`: a long history, megabytes of it) is not kept there:
/// the preferences are one file that is read whole at the start and written whole after every
/// change. Each such value has a file of its own in `largeFolder`, written on a background
/// thread, newest value last, however often it is set; what is read comes from memory once it
/// was read or set. Safe to use from any thread: the large values are guarded by `lock`, and
/// `UserDefaults` is thread-safe.
public final class UserDefaultsSettings: SettingsStore, @unchecked Sendable {
    private let defaults: UserDefaults
    /// Where the large values are kept; nil keeps them with the rest.
    public let largeFolder: URL?
    private let lock = NSCondition()
    /// The large values that were read or set, by key; `.some(nil)` for one that is not there.
    private var large: [String: Data?] = [:]
    /// The keys whose files are behind what `large` says.
    private var unwritten: Set<String> = []
    private var isWriting = false

    /// The standard preferences keep their large values in the program's folder in
    /// Application Support; any other store keeps them with the rest unless it is given a folder.
    public init(defaults: UserDefaults = .standard, largeFolder: URL? = nil) {
        self.defaults = defaults
        self.largeFolder =
            largeFolder ?? (defaults === UserDefaults.standard ? Self.standardLargeFolder : nil)
    }

    static var standardLargeFolder: URL? {
        let name = Bundle.main.bundleIdentifier ?? ProcessInfo.processInfo.processName
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent(name, isDirectory: true).appendingPathComponent("Settings", isDirectory: true)
    }

    public func data(forKey key: String) -> Data? { defaults.data(forKey: key) }
    public func set(_ data: Data?, forKey key: String) { defaults.set(data, forKey: key) }

    /// The file of a key: its name written with letters, digits and `-._` alone, everything
    /// else as `%XX` of its bytes, so no key can name a file outside the folder.
    func largeFile(forKey key: String) -> URL? {
        guard let largeFolder else { return nil }
        var name = ""
        for byte in key.utf8 {
            let isPlain =
                (0x30...0x39).contains(byte) || (0x41...0x5A).contains(byte) || (0x61...0x7A).contains(byte)
                || byte == 0x2D || byte == 0x5F
                || (byte == 0x2E && !name.isEmpty)
            name += isPlain ? String(UnicodeScalar(byte)) : String(format: "%%%02X", byte)
        }
        return largeFolder.appendingPathComponent(String(name.prefix(200)) + ".data", isDirectory: false)
    }

    public func largeData(forKey key: String) -> Data? {
        guard let file = largeFile(forKey: key) else { return data(forKey: key) }
        lock.lock()
        if let known = large[key] {
            lock.unlock()
            return known
        }
        lock.unlock()
        // Read outside the lock; a value that was stored with the rest before is still found there.
        let read = (try? Data(contentsOf: file)) ?? defaults.data(forKey: key)
        lock.lock()
        defer { lock.unlock() }
        // Set meanwhile: that is the value.
        if let known = large[key] { return known }
        large[key] = .some(read)
        return read
    }

    public func setLarge(_ data: Data?, forKey key: String) {
        guard largeFile(forKey: key) != nil else {
            set(data, forKey: key)
            return
        }
        lock.lock()
        large[key] = .some(data)
        unwritten.insert(key)
        let starts = !isWriting
        if starts { isWriting = true }
        lock.unlock()
        // One writer at a time, on a thread that may wait for the disk as long as it has to.
        if starts { BlockingCalls.run { [self] in writeLargeValues() } }
    }

    private func writeLargeValues() {
        lock.lock()
        while let key = unwritten.first {
            unwritten.remove(key)
            let value = large[key] ?? nil
            lock.unlock()
            if let file = largeFile(forKey: key) {
                if let value {
                    try? FileManager.default.createDirectory(
                        at: file.deletingLastPathComponent(), withIntermediateDirectories: true,
                        attributes: [.posixPermissions: 0o700])
                    // A history may hold what nobody else should read.
                    if (try? value.write(to: file, options: .atomic)) != nil {
                        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
                    }
                } else {
                    try? FileManager.default.removeItem(at: file)
                }
                // The copy that was kept with the rest before is not needed any more.
                if defaults.object(forKey: key) != nil { defaults.removeObject(forKey: key) }
            }
            lock.lock()
        }
        isWriting = false
        lock.broadcast()
        lock.unlock()
    }

    /// Waits until every large value that was set is in its file, for at most `timeout`
    /// seconds (the program quits). Returns false when the time ran out.
    @discardableResult
    public func waitForWrites(atMost timeout: TimeInterval) -> Bool {
        let deadline = Date(timeIntervalSinceNow: timeout)
        lock.lock()
        defer { lock.unlock() }
        while isWriting {
            if !lock.wait(until: deadline) { return !isWriting }
        }
        return true
    }
}

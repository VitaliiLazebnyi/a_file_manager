import AFMKernel
import AFMShell
import AppKit

/// The Options window (spec 13 › The dialog framework): the pages on the left, the selected
/// page on the right, OK, Cancel and Apply below.
///
/// Main thread only.
///
/// Unlike Total Commander's dialog it is not modal, as is usual on the Mac; what is pending on
/// its pages reaches the program only with Apply or OK.
internal final class OptionsWindowController: NSWindowController, NSWindowDelegate {
    /// The page the window opens on.
    internal enum Section {
        /// The page selected last (the first page when none was).
        case first
        /// The key bindings.
        case keyboard
        /// The button bar.
        case buttonBar
        /// The Start menu.
        case startMenu
        /// Export, import and reset of the settings.
        case settingsFile
    }

    private unowned let center: ConfigurationCenter
    private let pages: [any OptionsPage]
    private let firstOwnPage: Int
    private let pageList = RowsTable(columns: [("", 150)])
    private let caption = NSTextField(labelWithString: "")
    private let container = NSView()
    private var applyButton = NSButton()

    /// The titles of the pages, in the order of the list: the plugins' pages, then the configuration's own.
    internal var pageTitles: [String] { pages.map(\.title) }
    /// The title of the page shown.
    internal var shownPage: String { caption.stringValue }

    /// Makes the window (not yet on screen) with a page for every plugin page that has
    /// preferences, then the keyboard, button bar, Start menu and settings file pages.
    internal init(center: ConfigurationCenter) {
        self.center = center
        let registered: [any OptionsPage] = center.kernel.preferences.pages.filter { !$0.preferences.isEmpty }
            .map { page in
                PreferencesPage(model: PreferencePageModel(page: page, settings: center.kernel.settings))
            }
        firstOwnPage = registered.count
        pages =
            registered + [
                KeyboardPage(center: center), ButtonBarPage(center: center), StartMenuPage(center: center),
                SettingsFilePage(center: center)
            ]
        let window = ToolWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 560),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Options"
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 760, height: 420)
        window.center()
        super.init(window: window)
        window.delegate = self
        for page in pages { page.onEdit = { [weak self] in self?.updateApply() } }
        buildContent(in: window)
    }

    /// Not used: the window is made in code.
    @available(*, unavailable)
    internal required init?(coder _: NSCoder) { fatalError("not used") }

    private func buildContent(in window: NSWindow) {
        pageList.onSelect = { [weak self] in self?.showSelectedPage() }
        pageList.widthAnchor.constraint(equalToConstant: 170).isActive = true
        caption.font = .boldSystemFont(ofSize: 14)
        container.translatesAutoresizingMaskIntoConstraints = false
        let top = filledStack(
            [pageList, filledStack([caption, container], vertical: true, spacing: 10)],
            vertical: false,
            spacing: 14
        )

        let okButton = ActionButton("OK") { [weak self] in self?.applyAndClose() }
        okButton.keyEquivalent = "\r"
        applyButton = ActionButton("Apply") { [weak self] in self?.apply() }
        let bottom = filledStack(
            [spacer(), ActionButton("Cancel") { [weak self] in self?.window?.close() }, applyButton, okButton],
            vertical: false,
            spacing: 8
        )
        window.contentView = padded(filledStack([top, bottom], vertical: true, spacing: 12), by: 14)
    }

    /// Opens the window on a page.
    ///
    /// A window that was closed shows what is stored now.
    internal func show(_ section: Section) {
        prepare(section)
        center.effects.present(self)
    }

    /// Everything `show` does short of putting the window on screen.
    internal func prepare(_ section: Section) {
        if window?.isVisible != true {
            for page in pages {
                page.discard()
            }
            pageList.show(pages.map { [$0.title] }, symbols: [], selecting: nil)
        }
        let index: Int
        switch section {
        case .first:
            index = pageList.selectedRow ?? 0

        case .keyboard:
            index = firstOwnPage

        case .buttonBar:
            index = firstOwnPage + 1

        case .startMenu:
            index = firstOwnPage + 2

        case .settingsFile:
            index = firstOwnPage + 3
        }
        pageList.selectedRow = index
        showSelectedPage()
        updateApply()
    }

    private func showSelectedPage() {
        // (The list has a row for every page.)
        guard let page = pageList.selectedRow.flatMap({ pages.dropFirst($0).first }) else {
            return
        }
        caption.stringValue = page.title
        for shown in container.subviews {
            shown.removeFromSuperview()
        }
        let view = page.view
        view.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(view)
        NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: container.topAnchor),
            view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            view.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])
    }

    /// Apply is offered once something was changed (spec 13 › Buttons, applying changes).
    private func updateApply() {
        applyButton.isEnabled = pages.contains(where: \.isChanged)
    }

    private func apply() {
        window?.makeFirstResponder(nil)
        // Each page stores what was changed on it, if anything.
        for page in pages { page.commit() }
        updateApply()
    }

    /// OK: applies, then closes.
    private func applyAndClose() {
        apply()
        window?.close()
    }

    /// Closing by Cancel, Esc or the close button drops what was not applied.
    internal func windowWillClose(_: Notification) {
        for page in pages {
            page.discard()
        }
    }
}

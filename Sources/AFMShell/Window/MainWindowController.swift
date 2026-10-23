import AFMKernel
import AppKit

/// The main window (spec 02 › Window composition).
///
/// From top to bottom the button bar, the drive buttons, the two panels, the command line and
/// the function-key bar. Which of them are shown and how the panels are arranged is in
/// `WindowLayout`; what the buttons, keys and menus do is decided by the plugins. Main thread
/// only.
internal final class MainWindowController: NSWindowController, NSMenuItemValidation, CommandResponder {
    /// How soon the bars follow something that changed.
    internal static let validationDelay: TimeInterval = 0.1
    /// How often the bars are checked while events arrive and nothing the window knows of changed.
    internal static let quietValidationInterval: TimeInterval = 1
    /// A check is not repeated before this many times its own duration has passed.
    internal static let validationRest: Double = 20

    /// The bar of command buttons at the top.
    internal let buttonBar: ButtonBarView
    /// The buttons of the places and drives, below the button bar.
    internal let driveBar: DriveBarView
    /// The command line below the panels.
    internal let commandLine: CommandLineView
    /// The bar of function keys at the bottom.
    internal let functionKeyBar: FunctionKeyBar
    /// True while a check of the bars is on its way.
    internal private(set) var isValidationPending = false
    /// Puts the window on screen and in front, and into full-screen mode when the second
    /// argument says so; the system's way unless told otherwise.
    internal var present: (NSWindow, Bool) -> Void = { window, fullScreen in
        window.makeKeyAndOrderFront(nil)
        if fullScreen {
            window.toggleFullScreen(nil)
        }
    }
    /// The window this controller made, which it keeps for its whole life.
    private let mainWindow: NSWindow
    /// The kernel whose commands the window's bars and menus run.
    private let kernel: Kernel
    /// The two panels the window shows.
    private let panels: PanelCoordinator
    /// What is shown and how it is arranged.
    private let layout: WindowLayout
    /// The panels and the divider between them.
    private let split: PanelSplit
    /// The panel events listened to; the kernel stops calling once they are let go of.
    private var subscriptions: [AnyObject] = []
    /// When the bars were last checked (in the system's uptime), and how long that took.
    private var lastValidation: (at: TimeInterval, cost: TimeInterval) = (0, 0)
    /// Set when the state was saved for the next start.
    ///
    /// What happens to the window while the program quits is not the user's doing.
    private var stateIsFinal = false

    /// The title of spec 01 › Window title, with the program's own name and version.
    internal var title: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        return WindowLayout.title(productName: kernel.productName, version: version, extra: layout.titleExtra)
    }

    /// The two panels, side by side or one above the other.
    internal var splitView: NSSplitView { split.view }

    /// The system's uptime now.
    private var uptime: TimeInterval { ProcessInfo.processInfo.systemUptime }

    /// The window of `kernel` with `panels`, arranged as `layout` says; not shown yet.
    internal init(kernel: Kernel, panels: PanelCoordinator, layout: WindowLayout) {
        self.kernel = kernel
        self.panels = panels
        self.layout = layout
        buttonBar = ButtonBarView(kernel: kernel)
        driveBar = DriveBarView(kernel: kernel, places: panels.places)
        commandLine = CommandLineView(kernel: kernel, panels: panels)
        functionKeyBar = FunctionKeyBar(kernel: kernel)
        split = PanelSplit(left: panels.leftPanel.view, right: panels.rightPanel.view, layout: layout)
        mainWindow = Self.makeWindow()
        super.init(window: mainWindow)
        arrangeParts()
        if let frame = layout.frame {
            window?.setFrame(from: frame)
        } else {
            window?.center()
        }
        applyLayout()
        // The panel that was the source when the program was left is the source again.
        (layout.sourceIsRight ? panels.rightPanel : panels.leftPanel).focus()
        followChanges()
        observe()
    }

    /// Not used: the window is made in code.
    @available(*, unavailable)
    internal required init?(coder _: NSCoder) {
        fatalError("not used")
    }

    /// The empty window, at its default size.
    private static func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1_180, height: 700),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.minSize = NSSize(width: 640, height: 360)
        window.isReleasedWhenClosed = false
        window.collectionBehavior.insert(.fullScreenPrimary)
        return window
    }

    /// Makes the window show what `WindowLayout` says.
    internal func applyLayout() {
        if !layout.isVisible(.commandLine), commandLine.hasFocus {
            panels.sourcePanel.focus()
        }
        // A bar without a single button would be an empty stripe.
        buttonBar.isHidden = !layout.isVisible(.buttonBar) || buttonBar.entries.isEmpty
        driveBar.isHidden = !layout.isVisible(.driveButtons)
        commandLine.isHidden = !layout.isVisible(.commandLine)
        functionKeyBar.isHidden = !layout.isVisible(.functionKeys)
        split.apply()
        window?.title = title
        validateBars()
    }

    /// Checks the bars soon, once for any number of requests: something they show may have changed.
    ///
    /// Checking runs the `enabled` and `checked` functions of every command on the bars, which
    /// are the plugins' and may be slow whatever they are meant to be. So a check that took
    /// long buys a rest in proportion (`validationRest` times its own duration): the bars then
    /// follow a little later, and the main thread keeps all but a twentieth of its time.
    @objc
    internal func scheduleValidation() {
        guard !isValidationPending else {
            return
        }
        isValidationPending = true
        let earliest = lastValidation.at + Self.validationRest * lastValidation.cost
        let delay = max(Self.validationDelay, earliest - uptime)
        MainLoop.after(delay) { [weak self] in
            self?.isValidationPending = false
            self?.validateBars()
        }
    }

    /// Greys out the buttons of the shown bars whose commands cannot run now, and notes how long that took.
    internal func validateBars() {
        let began = uptime
        if !buttonBar.isHidden {
            buttonBar.validate()
        }
        if !driveBar.isHidden {
            driveBar.validate()
        }
        if !functionKeyBar.isHidden {
            functionKeyBar.validate()
        }
        let ended = uptime
        lastValidation = (ended, ended - began)
    }

    /// Shows on the function-key bar what the function keys do with the modifiers held.
    ///
    /// While Shift, Option or Control is held, the bar shows what the function keys do with it
    /// (spec 02 › Function-key bar). Not while text is typed: capital letters would make the
    /// bar flicker.
    internal func modifiersChanged(to flags: NSEvent.ModifierFlags) {
        let isTyping = window?.firstResponder is NSText
        functionKeyBar.show(isTyping ? [] : KeyModifiers(flags))
    }

    /// A modifier key was pressed or released.
    override internal func flagsChanged(with event: NSEvent) {
        modifiersChanged(to: event.modifierFlags)
    }

    /// Remembers the window for the next start.
    ///
    /// The panel that is the source and the layout are kept as they change.
    internal func saveState() {
        rememberFrame()
        stateIsFinal = true
    }

    /// Shows the window; one that was left in full-screen mode comes back that way.
    override internal func showWindow(_: Any?) {
        present(mainWindow, layout.isFullScreen && !mainWindow.styleMask.contains(.fullScreen))
    }

    /// Runs the command of a menu item; the bars are checked after it.
    internal func performCommand(_ sender: NSMenuItem) {
        if let id = MenuBuilder.command(of: sender) {
            kernel.commands.perform(id)
        }
        scheduleValidation()
    }

    /// Whether a menu item's command can run now; its check mark follows the command.
    internal func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        guard let id = MenuBuilder.command(of: menuItem) else {
            return true
        }
        menuItem.state = kernel.commands.isChecked(id) ? .on : .off
        return kernel.commands.isEnabled(id)
    }

    /// Stacks the bars and the panels in the window, from top to bottom.
    private func arrangeParts() {
        let stack = NSStackView(views: [buttonBar, driveBar, splitView, commandLine, functionKeyBar])
        stack.orientation = .vertical
        stack.spacing = 0
        stack.alignment = .leading
        for part in stack.arrangedSubviews {
            part.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
            if part !== splitView {
                part.setContentHuggingPriority(.required, for: .vertical)
            }
        }
        window?.contentView = stack
    }

    /// Follows the layout, the button bar's contents and the panels.
    private func followChanges() {
        layout.onChange = { [weak self] in
            // The size of the bar's pictures is one of the layout's settings.
            self?.buttonBar.rebuild()
            self?.applyLayout()
        }
        kernel.toolbar.onChange = { [weak self] in
            self?.buttonBar.rebuild()
            self?.applyLayout()
        }
        // The window keeps the subscription, so it hears of the panels for as long as it lives.
        let subscription = kernel.panelEvents.subscribe { [weak self] event, panel in
            self?.panelDid(event, panel)
        }
        subscriptions.append(subscription)
    }

    /// A panel became the source, changed its folder or its selection: the bars follow.
    private func panelDid(_ event: PanelEvent, _ panel: any PanelHandle) {
        if event == .becameSource {
            layout.sourceIsRight = panel === panels.rightPanel
        }
        scheduleValidation()
    }

    /// Listens to the program and the window becoming active, moving and changing size.
    private func observe() {
        let center = NotificationCenter.default
        center.addObserver(
            self,
            selector: #selector(appBecameActive),
            name: NSApplication.didBecomeActiveNotification,
            object: nil
        )
        // Reading ahead follows whether this window is the one in use.
        for name in [NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification] {
            center.addObserver(self, selector: #selector(activityChanged), name: name, object: nil)
        }
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
            center.addObserver(self, selector: #selector(activityChanged), name: name, object: window)
        }
        for name in [
            NSWindow.didMoveNotification, NSWindow.didEndLiveResizeNotification, NSWindow.willCloseNotification
        ] {
            center.addObserver(self, selector: #selector(rememberFrame), name: name, object: window)
        }
        for name in [NSWindow.didEnterFullScreenNotification, NSWindow.didExitFullScreenNotification] {
            center.addObserver(self, selector: #selector(fullScreenChanged), name: name, object: window)
        }
        // The buttons follow their commands. What can change them is known to the window for the
        // most part (the panels, the jobs, a command that ran), and then they are checked at
        // once (`scheduleValidation`). For the rest (a plugin's own state, the pasteboard) they
        // are looked at now and then while events arrive, not after every single event.
        center.addObserver(
            self,
            selector: #selector(windowUpdated),
            name: NSWindow.didUpdateNotification,
            object: window
        )
    }

    /// The window handled an event.
    ///
    /// Nothing says that anything changed, so the bars are only looked at if that was not done
    /// for a while.
    @objc
    private func windowUpdated() {
        if uptime - lastValidation.at >= Self.quietValidationInterval {
            scheduleValidation()
        }
    }

    /// Remembers where the window is, unless it fills the screen.
    @objc
    private func rememberFrame() {
        guard !stateIsFinal, let window, !window.styleMask.contains(.fullScreen) else {
            return
        }
        layout.frame = window.frameDescriptor
    }

    /// Remembers whether the window fills the screen.
    @objc
    private func fullScreenChanged() {
        guard !stateIsFinal, let window else {
            return
        }
        layout.isFullScreen = window.styleMask.contains(.fullScreen)
    }

    /// The program or the window became active or stopped being so.
    @objc
    private func activityChanged() {
        panels.updateReadAhead()
        // A modifier released while another program was in front never arrives here.
        modifiersChanged(to: window?.isKeyWindow == true ? NSEvent.modifierFlags : [])
    }

    /// The program became active: the panels are checked again (spec 03 › On activation and restart).
    @objc
    private func appBecameActive() {
        if window?.attachedSheet == nil {
            panels.reloadChangedPanels()
        }
        // What another program did meanwhile (the pasteboard) may have changed what the buttons offer.
        scheduleValidation()
    }
}

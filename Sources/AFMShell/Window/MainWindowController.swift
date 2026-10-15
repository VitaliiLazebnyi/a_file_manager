import AFMContracts
import AFMKernel
import AppKit

/// The main window (spec 02 › Window composition): from top to bottom the button bar, the
/// drive buttons, the two panels, the command line and the function-key bar. Which of them
/// are shown and how the panels are arranged is in `WindowLayout`; what the buttons, keys and
/// menus do is decided by the plugins. Main thread only.
final class MainWindowController: NSWindowController, NSMenuItemValidation, NSSplitViewDelegate, CommandResponder {
    private let kernel: Kernel
    private let panels: PanelCoordinator
    private let layout: WindowLayout
    let splitView = NSSplitView()
    let buttonBar: ButtonBarView
    let driveBar: DriveBarView
    let commandLine: CommandLineView
    let functionKeyBar: FunctionKeyBar
    /// The panel events listened to; the kernel stops calling once they are let go of.
    private var subscriptions: [AnyObject] = []
    /// True while a check of the bars is on its way.
    private(set) var isValidationPending = false
    /// When the bars were last checked (in the system's uptime), and how long that took.
    private var lastValidation: (at: TimeInterval, cost: TimeInterval) = (0, 0)
    /// How soon the bars follow something that changed.
    static let validationDelay: TimeInterval = 0.1
    /// How often the bars are checked while events arrive and nothing the window knows of changed.
    static let quietValidationInterval: TimeInterval = 1
    /// A check is not repeated before this many times its own duration has passed.
    static let validationRest: Double = 20
    /// True while the divider is moved by the window itself, not by the user.
    private var isPositioningDivider = false
    /// Set when the state was saved for the next start; what happens to the window while the
    /// program quits is not the user's doing.
    private var stateIsFinal = false

    init(kernel: Kernel, panels: PanelCoordinator, layout: WindowLayout) {
        self.kernel = kernel
        self.panels = panels
        self.layout = layout
        buttonBar = ButtonBarView(kernel: kernel)
        driveBar = DriveBarView(kernel: kernel, places: panels.places)
        commandLine = CommandLineView(kernel: kernel, panels: panels)
        functionKeyBar = FunctionKeyBar(kernel: kernel)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1_180, height: 700),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.minSize = NSSize(width: 640, height: 360)
        window.isReleasedWhenClosed = false
        window.collectionBehavior.insert(.fullScreenPrimary)
        super.init(window: window)

        splitView.dividerStyle = .thin
        splitView.delegate = self
        splitView.addArrangedSubview(panels.leftPanel.view)
        splitView.addArrangedSubview(panels.rightPanel.view)
        splitView.setContentHuggingPriority(.defaultLow, for: .vertical)

        let stack = NSStackView(views: [buttonBar, driveBar, splitView, commandLine, functionKeyBar])
        stack.orientation = .vertical
        stack.spacing = 0
        stack.alignment = .leading
        for part in stack.arrangedSubviews {
            part.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
            if part !== splitView { part.setContentHuggingPriority(.required, for: .vertical) }
        }
        window.contentView = stack
        if let frame = layout.frame { window.setFrame(from: frame) } else { window.center() }
        applyLayout()
        // The panel that was the source when the program was left is the source again.
        (layout.sourceIsRight ? panels.rightPanel : panels.leftPanel).focus()

        layout.onChange = { [weak self] in
            // The size of the bar's pictures is one of the layout's settings.
            self?.buttonBar.rebuild()
            self?.applyLayout()
        }
        kernel.toolbar.onChange = { [weak self] in
            self?.buttonBar.rebuild()
            self?.applyLayout()
        }
        let subscription = kernel.panelEvents.subscribe { [weak self] event, panel in
            guard let self else { return }
            if event == .becameSource { self.layout.sourceIsRight = panel === self.panels.rightPanel }
            scheduleValidation()
        }
        subscriptions.append(subscription)
        observe()
    }

    required init?(coder _: NSCoder) { fatalError("not used") }

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

    // MARK: Layout

    /// The title of spec 01 › Window title, with the program's own name and version.
    var title: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        return WindowLayout.title(productName: kernel.productName, version: version, extra: layout.titleExtra)
    }

    /// Makes the window show what `WindowLayout` says.
    func applyLayout() {
        if !layout.isVisible(.commandLine), commandLine.hasFocus { panels.sourcePanel.focus() }
        // A bar without a single button would be an empty stripe.
        buttonBar.isHidden = !layout.isVisible(.buttonBar) || buttonBar.entries.isEmpty
        driveBar.isHidden = !layout.isVisible(.driveButtons)
        commandLine.isHidden = !layout.isVisible(.commandLine)
        functionKeyBar.isHidden = !layout.isVisible(.functionKeys)
        if splitView.isVertical == layout.isStacked {
            splitView.isVertical = !layout.isStacked
            splitView.adjustSubviews()
        }
        positionDivider()
        window?.title = title
        validateBars()
    }

    private var splitExtent: CGFloat {
        (splitView.isVertical ? splitView.bounds.width : splitView.bounds.height) - splitView.dividerThickness
    }

    private func positionDivider() {
        guard splitExtent > 0 else { return }
        isPositioningDivider = true
        splitView.setPosition((splitExtent * CGFloat(layout.divider) / 1_000).rounded(), ofDividerAt: 0)
        isPositioningDivider = false
    }

    func splitView(_ splitView: NSSplitView, resizeSubviewsWithOldSize _: NSSize) {
        // Both panels keep their share of the window.
        splitView.adjustSubviews()
        positionDivider()
    }

    func splitView(
        _: NSSplitView,
        constrainSplitPosition proposedPosition: CGFloat,
        ofSubviewAt _: Int
    ) -> CGFloat {
        guard splitExtent > 0 else { return proposedPosition }
        return min(splitExtent * 0.9, max(splitExtent * 0.1, proposedPosition))
    }

    func splitViewDidResizeSubviews(_ notification: Notification) {
        // Only a divider the user dragged changes the stored position (spec 02 › Panel divider);
        // the same notification follows every resizing of the window.
        let isDragging = NSApp.currentEvent?.type == .leftMouseDragged
        guard isDragging, !isPositioningDivider, notification.userInfo?["NSSplitViewDividerIndex"] != nil,
            splitExtent > 0
        else { return }
        let first = splitView.isVertical ? panels.leftPanel.view.frame.width : panels.leftPanel.view.frame.height
        layout.rememberDivider(Int((first / splitExtent * 1_000).rounded()))
    }

    // MARK: Buttons that follow their commands

    private var uptime: TimeInterval { ProcessInfo.processInfo.systemUptime }

    /// Checks the bars soon, once for any number of requests: something they show may have changed.
    ///
    /// Checking runs the `enabled` and `checked` functions of every command on the bars, which
    /// are the plugins' and may be slow whatever they are meant to be. So a check that took
    /// long buys a rest in proportion (`validationRest` times its own duration): the bars then
    /// follow a little later, and the main thread keeps all but a twentieth of its time.
    @objc func scheduleValidation() {
        guard !isValidationPending else { return }
        isValidationPending = true
        let earliest = lastValidation.at + Self.validationRest * lastValidation.cost
        let delay = max(Self.validationDelay, earliest - uptime)
        MainLoop.after(delay) { [weak self] in
            self?.isValidationPending = false
            self?.validateBars()
        }
    }

    /// The window handled an event. Nothing says that anything changed, so the bars are only
    /// looked at if that was not done for a while.
    @objc private func windowUpdated() {
        if uptime - lastValidation.at >= Self.quietValidationInterval { scheduleValidation() }
    }

    func validateBars() {
        let began = uptime
        if !buttonBar.isHidden { buttonBar.validate() }
        if !driveBar.isHidden { driveBar.validate() }
        if !functionKeyBar.isHidden { functionKeyBar.validate() }
        let ended = uptime
        lastValidation = (ended, ended - began)
    }

    /// While Shift, Option or Control is held, the function-key bar shows what the function
    /// keys do with it (spec 02 › Function-key bar). Not while text is typed: capital letters
    /// would make the bar flicker.
    func modifiersChanged(to flags: NSEvent.ModifierFlags) {
        let isTyping = window?.firstResponder is NSText
        functionKeyBar.show(isTyping ? [] : KeyModifiers(flags))
    }

    override func flagsChanged(with event: NSEvent) {
        modifiersChanged(to: event.modifierFlags)
    }

    // MARK: State

    /// Remembers the window for the next start. The panel that is the source and the layout
    /// are kept as they change.
    func saveState() {
        rememberFrame()
        stateIsFinal = true
    }

    @objc private func rememberFrame() {
        guard !stateIsFinal, let window, !window.styleMask.contains(.fullScreen) else { return }
        layout.frame = window.frameDescriptor
    }

    @objc private func fullScreenChanged() {
        guard !stateIsFinal, let window else { return }
        layout.isFullScreen = window.styleMask.contains(.fullScreen)
    }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        // A window that was left in full-screen mode comes back that way.
        if layout.isFullScreen, let window, !window.styleMask.contains(.fullScreen) { window.toggleFullScreen(nil) }
    }

    @objc private func activityChanged() {
        panels.updateReadAhead()
        // A modifier released while another program was in front never arrives here.
        modifiersChanged(to: window?.isKeyWindow == true ? NSEvent.modifierFlags : [])
    }

    @objc private func appBecameActive() {
        // Panels are checked again when the program is activated (spec 03 › On activation and restart).
        if window?.attachedSheet == nil { panels.reloadChangedPanels() }
        // What another program did meanwhile (the pasteboard) may have changed what the buttons offer.
        scheduleValidation()
    }

    // MARK: Commands from menus

    func performCommand(_ sender: NSMenuItem) {
        if let id = MenuBuilder.command(of: sender) { kernel.commands.perform(id) }
        scheduleValidation()
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        guard let id = MenuBuilder.command(of: menuItem) else { return true }
        menuItem.state = kernel.commands.isChecked(id) ? .on : .off
        return kernel.commands.isEnabled(id)
    }
}

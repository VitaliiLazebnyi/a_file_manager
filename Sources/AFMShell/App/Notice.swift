import AppKit

/// A short message that shows for a few seconds near the bottom of a window.
///
/// It has no button and does not take the keyboard (`UserInteraction.notice`); clicks go
/// through it to what lies below. A newer one replaces the one on screen. Main thread only.
@MainActor
internal enum Notice {
    /// How long a message stays before it fades.
    internal static let duration: TimeInterval = 3
    /// The message on screen, until it has faded.
    internal private(set) static var shown: NSPanel?
    /// Counts the messages, so that the fading of one that was replaced leaves the new one alone.
    private static var generation = 0

    /// Shows `message` over `window`, or at the bottom of the main screen without one.
    internal static func show(_ message: String, over window: NSWindow?) {
        if let shown {
            shown.parent?.removeChildWindow(shown)
            shown.orderOut(nil)
        }
        generation += 1
        let panel = makePanel(message, maximumWidth: max((window?.frame.width ?? 600) - 80, 200))
        let area = window?.frame ?? NSScreen.main?.visibleFrame ?? panel.frame
        panel.setFrameOrigin(NSPoint(x: area.midX - panel.frame.width / 2, y: area.minY + 70))
        panel.alphaValue = 0
        if let window {
            window.addChildWindow(panel, ordered: .above)
        } else {
            panel.orderFrontRegardless()
        }
        shown = panel
        NSAccessibility.post(
            element: panel,
            notification: .announcementRequested,
            userInfo: [.announcement: message, .priority: NSAccessibilityPriorityLevel.high.rawValue]
        )
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            panel.animator().alphaValue = 1
        }
        let current = generation
        MainLoop.after(duration) { fade(panel, generation: current) }
    }

    /// The window of a message: a rounded, translucent plate with one line of text.
    private static func makePanel(_ message: String, maximumWidth: CGFloat) -> NSPanel {
        let label = NSTextField(labelWithString: message)
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.textColor = .labelColor
        label.lineBreakMode = .byTruncatingMiddle
        label.maximumNumberOfLines = 1
        let size = label.intrinsicContentSize
        let frame = NSRect(x: 0, y: 0, width: min(size.width, maximumWidth) + 32, height: size.height + 18)
        let background = NSVisualEffectView(frame: frame)
        background.material = .hudWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 10
        background.layer?.masksToBounds = true
        label.frame = NSRect(x: 16, y: 9, width: frame.width - 32, height: size.height)
        background.addSubview(label)
        let panel = NSPanel(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.level = .floating
        panel.isReleasedWhenClosed = false
        panel.contentView = background
        panel.setAccessibilityLabel(message)
        return panel
    }

    /// Fades the message out and takes it away, unless a newer one has replaced it meanwhile.
    private static func fade(_ panel: NSPanel, generation current: Int) {
        guard current == generation else {
            return
        }
        NSAnimationContext.runAnimationGroup(
            { context in
                context.duration = 0.4
                panel.animator().alphaValue = 0
            },
            completionHandler: {
                // AppKit calls the completion handler on the main thread.
                MainActor.assumeIsolated { remove(panel, generation: current) }
            }
        )
    }

    /// Takes the faded message off the screen, unless a newer one has replaced it meanwhile.
    private static func remove(_ panel: NSPanel, generation current: Int) {
        guard current == generation else {
            return
        }
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
        shown = nil
    }
}

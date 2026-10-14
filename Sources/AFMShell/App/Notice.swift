import AppKit

/// A short message that shows for a few seconds near the bottom of a window, without a button
/// and without taking the keyboard (`UserInteraction.notice`). A newer one replaces the one on
/// screen. Main thread only.
enum Notice {
    private static var shown: NSPanel?
    private static var generation = 0
    static let duration: TimeInterval = 3

    static func show(_ message: String, over window: NSWindow?) {
        if let shown {
            shown.parent?.removeChildWindow(shown)
            shown.orderOut(nil)
        }
        generation += 1
        let current = generation

        let label = NSTextField(labelWithString: message)
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.textColor = .labelColor
        label.lineBreakMode = .byTruncatingMiddle
        label.maximumNumberOfLines = 1
        let size = label.intrinsicContentSize
        let maximum = max((window?.frame.width ?? 600) - 80, 200)
        let frame = NSRect(x: 0, y: 0, width: min(size.width, maximum) + 32, height: size.height + 18)

        let background = NSVisualEffectView(frame: frame)
        background.material = .hudWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 10
        background.layer?.masksToBounds = true
        label.frame = NSRect(x: 16, y: 9, width: frame.width - 32, height: size.height)
        background.addSubview(label)

        let panel = NSPanel(
            contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.level = .floating
        panel.isReleasedWhenClosed = false
        panel.contentView = background
        panel.setAccessibilityLabel(message)

        let area = window?.frame ?? NSScreen.main?.visibleFrame ?? frame
        panel.setFrameOrigin(NSPoint(x: area.midX - frame.width / 2, y: area.minY + 70))
        panel.alphaValue = 0
        if let window { window.addChildWindow(panel, ordered: .above) } else { panel.orderFrontRegardless() }
        shown = panel
        NSAccessibility.post(
            element: panel, notification: .announcementRequested,
            userInfo: [.announcement: message, .priority: NSAccessibilityPriorityLevel.high.rawValue])
        NSAnimationContext.runAnimationGroup {
            $0.duration = 0.15
            panel.animator().alphaValue = 1
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + duration) {
            guard current == generation else { return }
            NSAnimationContext.runAnimationGroup(
                {
                    $0.duration = 0.4
                    panel.animator().alphaValue = 0
                },
                completionHandler: {
                    guard current == generation else { return }
                    panel.parent?.removeChildWindow(panel)
                    panel.orderOut(nil)
                    shown = nil
                })
        }
    }
}

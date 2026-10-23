public import AppKit

/// Finding the controls of a window that keeps them to itself, and pressing keys on them.
@preconcurrency
@MainActor
public enum Controls {
    /// The key codes of the named keys the tests press.
    public enum Code {
        /// F2.
        public static let functionKey2: UInt16 = 120
        /// F3.
        public static let functionKey3: UInt16 = 99
        /// F4.
        public static let functionKey4: UInt16 = 118
        /// F5.
        public static let functionKey5: UInt16 = 96
        /// F10.
        public static let functionKey10: UInt16 = 109
        /// Return.
        public static let returnKey: UInt16 = 36
        /// Space.
        public static let space: UInt16 = 49
        /// Backspace.
        public static let backspace: UInt16 = 51
        /// Forward delete.
        public static let forwardDelete: UInt16 = 117
        /// Page up.
        public static let pageUp: UInt16 = 116
        /// Page down.
        public static let pageDown: UInt16 = 121
        /// Arrow up.
        public static let upArrow: UInt16 = 126
        /// Arrow down.
        public static let downArrow: UInt16 = 125
        /// A key that types a character (its code is not a named key's).
        public static let character: UInt16 = 0
    }

    /// Every view of the given type in `view` and below, in the order of the view tree.
    public static func all<View: NSView>(_ type: View.Type, in view: NSView?) -> [View] {
        guard let view else {
            return []
        }
        return [view as? View].compactMap(\.self) + view.subviews.flatMap { all(type, in: $0) }
    }

    /// The button with this title.
    public static func button(_ title: String, in view: NSView?) -> NSButton? {
        all(NSButton.self, in: view).first { $0.title == title }
    }

    /// Sends a control's action to its target, as a click or a choice does.
    public static func send(_ control: NSControl) {
        if let action = control.action {
            NSApp.sendAction(action, to: control.target, from: control)
        }
    }

    /// A key press: `keyCode` names the key, `characters` what it types.
    public static func key(
        _ keyCode: UInt16,
        _ characters: String = "",
        _ flags: NSEvent.ModifierFlags = [],
        window: NSWindow? = nil
    ) -> NSEvent {
        // Every argument is valid, so there is an event.
        NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: flags,
            timestamp: 0,
            windowNumber: window?.windowNumber ?? 0,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: characters,
            isARepeat: false,
            keyCode: keyCode
        ) ?? NSEvent()
    }
}

import AppKit
import TestSupport
import Testing

/// Helpers for the tests of the Places windows: letting the main thread work, finding views,
/// making key presses.
@MainActor
internal enum CoveragePlacesLoop {
    /// Lets the main thread go round a few times, for what has nothing to wait for.
    internal static func settle() async {
        for _ in 0..<5 {
            RunLoopWait.runPendingBlocks()
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
    }

    /// The views of `type` inside `view`, in the order they are laid out.
    internal static func views<View: NSView>(_ type: View.Type, in view: NSView?) -> [View] {
        var found: [View] = []
        for subview in view?.subviews ?? [] {
            if let match = subview as? View {
                found.append(match)
            }
            found += views(type, in: subview)
        }
        return found
    }

    /// The button titled `title` inside `view`.
    internal static func button(_ title: String, in view: NSView?) -> NSButton? {
        views(NSButton.self, in: view).first { $0.title == title }
    }

    /// A key press as AppKit hands it to a view; throws only if AppKit makes no event of it.
    internal static func key(_ characters: String, code: UInt16, modifiers: NSEvent.ModifierFlags) throws -> NSEvent {
        try #require(
            NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: modifiers,
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                characters: characters,
                charactersIgnoringModifiers: characters,
                isARepeat: false,
                keyCode: code
            )
        )
    }
}

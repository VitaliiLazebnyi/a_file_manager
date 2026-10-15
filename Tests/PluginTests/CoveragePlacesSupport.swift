import AppKit
import Foundation
import TestSupport

/// Lets the main thread work while a test waits: blocks of the main queue run while the test is
/// suspended, blocks of the main run loop and events in between.
@MainActor
enum CoveragePlacesLoop {
    /// Waits until `condition` holds; false when it still does not after `seconds` (a hang).
    static func spin(seconds: TimeInterval = 60, until condition: () -> Bool) async -> Bool {
        let end = Date(timeIntervalSinceNow: seconds)
        while !condition() {
            if Date() > end { return false }
            turn()
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
        return true
    }

    /// Lets the main thread go round a few times, for what has nothing to wait for.
    static func settle() async {
        for _ in 0..<5 {
            turn()
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
    }

    /// One turn of the main run loop, for the blocks handed to it.
    private static func turn() {
        RunLoop.main.run(mode: .default, before: Date())
    }

    /// The views of `type` inside `view`, in the order they are laid out.
    static func views<View: NSView>(_ type: View.Type, in view: NSView?) -> [View] {
        var found: [View] = []
        for subview in view?.subviews ?? [] {
            if let match = subview as? View { found.append(match) }
            found += views(type, in: subview)
        }
        return found
    }

    /// The button titled `title` inside `view`.
    static func button(_ title: String, in view: NSView?) -> NSButton? {
        views(NSButton.self, in: view).first { $0.title == title }
    }

    /// A key press as AppKit hands it to a view.
    static func key(
        _ characters: String,
        code: UInt16 = 0,
        modifiers: NSEvent.ModifierFlags = [],
        ignoringModifiers: String? = nil
    ) -> NSEvent {
        // A made-up event of a valid kind is never nil.
        NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: modifiers,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: ignoringModifiers ?? characters,
            isARepeat: false,
            keyCode: code
        )!
    }
}

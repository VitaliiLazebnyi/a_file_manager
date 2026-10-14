import AFMContracts
import AFMKernel
import AppKit
import StressKit
import TestSupport

@testable import AFMShell

/// Scenario 2, step B: what a user does while the provider is silent.
extension StalledScenario {
    /// B, first half: moving, refreshing, entering and leaving folders, tabs.
    internal func actInTheShare() {
        act("cursor moves over 40 folders (read-ahead)") {
            for row in 1...40 {
                left.model.moveCursor(to: row)
                pump(for: 0.05)
            }
        }
        act("refresh (Cmd+R)") { app.commands.perform(.reread) }
        act("validation x5") {
            for _ in 0..<5 {
                _ = app.validateEverything(menu: menu)
            }
        }
        act("enter folder under cursor (Return)") {
            left.model.moveCursor(to: 3)
            app.commands.perform(.open)
        }
        act("go to parent") { app.commands.perform(.goToParent) }
        act("go back") { app.commands.perform(.goBack) }
        act("new tab") { app.commands.perform(.newTab) }
        act("navigate the new tab to another stalled folder") {
            left.show(stall.inner.url("/other/place"), focus: nil, history: .record, completion: nil)
        }
        act("previous tab") { app.commands.perform(.previousTab) }
        act("next tab") { app.commands.perform(.nextTab) }
        act("quick filter typed") {
            left.showQuickFilter()
            left.quickFilterEdited("doc1")
            pump(for: 0.3)
            left.removeQuickFilter()
        }
        act("sort by size") { app.commands.perform(.sortBySize) }
        act("select all + status line") {
            app.commands.perform(.selectAll)
            left.updateStatus()
        }
        act("space on a folder (size calculation)") {
            left.model.moveCursor(to: 2)
            app.commands.perform(.toggleSelectionWithSize)
        }
    }

    /// B, second half: activation, focus, drawing, validation, closing and leaving.
    internal func actAround() {
        act("application deactivates / activates") {
            NotificationCenter.default.post(name: NSApplication.didResignActiveNotification, object: NSApp)
            pump(for: 0.2)
            NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: NSApp)
        }
        act("switch panel (Tab) and back") {
            app.commands.perform(.focusTarget)
            pump(for: 0.1)
            app.commands.perform(.focusTarget)
        }
        act("right panel: target = source") {
            app.commands.perform(.focusTarget)
            app.commands.perform(.targetEqualsSource)
            pump(for: 0.2)
            app.commands.perform(.focusTarget)
        }
        act("draw list") { app.draw(left) }
        act("validation x5 again") {
            for _ in 0..<5 {
                _ = app.validateEverything(menu: menu)
            }
        }
        act("close tab") { app.commands.perform(.closeTab) }
        act("navigate away to a local folder (both panels)", wait: 1.0) {
            left.show(small, focus: nil, history: .record, completion: nil)
            app.right.show(small, focus: nil, history: .record, completion: nil)
            closeOtherTabs()
        }
    }

    /// Closes every tab of the left panel but the active one, from the last.
    internal func closeOtherTabs() {
        for index in stride(from: left.tabs.count - 1, through: 0, by: -1) {
            let isOther = left.tabs.count > 1 && left.tabs.tabs[index] !== left.model
            if isOther {
                _ = left.tabs.closeTab(at: index)
            }
        }
    }
}

import AFMKernel
import AppKit

/// Runs the entries of the Start menu after the menu was rebuilt while the program runs.
@MainActor
internal final class StartMenuTarget: NSObject, NSMenuItemValidation {
    private unowned let kernel: Kernel

    /// A target that runs the entries' commands through the kernel.
    internal init(kernel: Kernel) {
        self.kernel = kernel
    }

    private func command(of item: NSMenuItem) -> CommandID? {
        (item.representedObject as? String).map(CommandID.init(rawValue:))
    }

    /// Runs the command of a Start-menu entry.
    @objc
    internal func runEntry(_ sender: NSMenuItem) {
        if let id = command(of: sender) { kernel.commands.perform(id) }
    }

    /// An entry is enabled when its command may run now.
    internal func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        command(of: menuItem).map(kernel.commands.isEnabled) ?? false
    }
}

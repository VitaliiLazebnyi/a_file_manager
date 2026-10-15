import AFMContracts
import AFMKernel
import AppKit
import Foundation
import TestSupport
import Testing

@testable import AFMShell

/// What the shell registers with the kernel does not keep alive what keeps the kernel: a
/// window that closes, or a test that ends, lets go of its panels and its kernel.
@MainActor
@Suite(.serialized)
internal struct AppLifetimeTests {
    /// A kernel without plugins, as the shell's own registrations see it.
    private static func makeKernel() -> Kernel {
        Kernel(productName: "Test", settings: MemorySettings(), interaction: ScriptedInteraction())
    }

    /// Makes sure AppKit is there for the views the panels build.
    internal init() {
        _ = NSApplication.shared
    }

    /// The commands of the file list hold the panels weakly: the kernel keeps the commands,
    /// and the panels keep the kernel.
    @Test
    internal func theFileListCommandsDoNotKeepThePanelsAlive() async {
        let kernel = Self.makeKernel()
        weak var released: PanelCoordinator?
        do {
            let panels = PanelCoordinator(kernel: kernel, home: URL(fileURLWithPath: "/"))
            ShellCommands.register(in: kernel, panels: panels)
            panels.shutDown()
            released = panels
        }
        #expect(await AppWait.until { released == nil })
        #expect(kernel.commands[.focusTarget] != nil)
    }

    /// The commands of the window around the panels hold the kernel weakly.
    @Test
    internal func theWindowCommandsDoNotKeepTheKernelAlive() async {
        weak var released: Kernel?
        do {
            let kernel = Self.makeKernel()
            WindowCommands.register(in: kernel, layout: WindowLayout(settings: kernel.settings)) { nil }
            #expect(kernel.commands[.resetButtonBar] != nil)
            released = kernel
        }
        #expect(await AppWait.until { released == nil })
    }
}

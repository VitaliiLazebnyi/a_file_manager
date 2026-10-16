import AFMShell
import AppKit
import StandardPlugins

// Before anything opens files: the program may have as many open as the system allows.
DescriptorLimit.raise()

/// The program: the window shell with the standard plugins, run until the user quits.
private let kApplication = ShellApplication(
    productName: StandardPlugins.productName,
    plugins: StandardPlugins.make()
)

// The application object keeps its delegate weakly; `kApplication` keeps it for the whole run.
NSApplication.shared.delegate = kApplication
NSApplication.shared.setActivationPolicy(.regular)
NSApplication.shared.run()

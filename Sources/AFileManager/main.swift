import AFMShell
import StandardPlugins

/// The program: the window shell with the standard plugins, run until the user quits.
private let kApplication = ShellApplication(
    productName: StandardPlugins.productName,
    plugins: StandardPlugins.make()
)

kApplication.run()

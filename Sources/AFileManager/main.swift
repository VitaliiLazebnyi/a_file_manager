import AFMShell
import StandardPlugins

let application = ShellApplication(productName: StandardPlugins.productName, plugins: StandardPlugins.make())
application.run()

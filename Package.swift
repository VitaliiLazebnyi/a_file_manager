// swift-tools-version:5.10
import PackageDescription

// A small kernel, a window shell, and plugins that provide every feature.
//
//   AFMKernel   no UI: the plugin interface, the command and menu registries, the file-system
//               provider interface and the panel model.
//   AFMContracts  the vocabulary plugins share: command names, menu sections, service
//               protocols, number and date formats. Names only, no behaviour.
//   AFMShell    AppKit: the main window, panels, dialogs and progress, built from what the
//               plugins registered.
//   Plugins     one module per feature. A plugin depends on the kernel and the contracts (and
//               on the shell only when it opens windows of its own), never on another plugin.
//   StandardPlugins  the list of plugins that make up the program.
//   AFileManager  the program: starts the shell with the standard plugins.

import Foundation

/// With the Command Line Tools alone (no Xcode), incremental test builds lose the path to the
/// Swift Testing macro plugin; it is passed explicitly where that toolchain is installed.
let commandLineToolsTesting = "/Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing"
let testingPlugin: [SwiftSetting] = FileManager.default.fileExists(atPath: commandLineToolsTesting)
    ? [.unsafeFlags(["-plugin-path", commandLineToolsTesting])] : []

func plugin(_ name: String, needsShell: Bool = false) -> Target {
    .target(name: name + "Plugin", dependencies: ["AFMKernel", "AFMContracts"] + (needsShell ? ["AFMShell"] : []), path: "Sources/Plugins/" + name)
}

let plugins = [
    plugin("LocalFileSystem"),
    plugin("FileOperations"),
    plugin("Navigation"),
    plugin("FolderTabs"),
    plugin("Selection"),
    plugin("ViewOptions"),
    plugin("Clipboard"),
    plugin("Viewer", needsShell: true),
    plugin("FindFiles", needsShell: true),
    plugin("MacIntegration"),
    plugin("Archives"),
    plugin("Network", needsShell: true),
    plugin("MultiRename", needsShell: true),
    plugin("FileTools"),
    plugin("DirectorySync", needsShell: true),
    plugin("CompareContent", needsShell: true),
    plugin("Places", needsShell: true),
    plugin("VirtualFolders"),
    plugin("FileProperties", needsShell: true),
    plugin("SystemTools", needsShell: true),
    plugin("Configuration", needsShell: true),
]
let pluginDependencies = plugins.map { Target.Dependency(stringLiteral: $0.name) }

let package = Package(
    name: "AFileManager",
    platforms: [.macOS(.v13)],
    targets: [
        .target(name: "AFMKernel"),
        .target(name: "AFMContracts", dependencies: ["AFMKernel"]),
        .target(name: "AFMShell", dependencies: ["AFMKernel", "AFMContracts"]),
        .target(name: "StandardPlugins", dependencies: ["AFMKernel"] + pluginDependencies),
        .executableTarget(name: "AFileManager", dependencies: ["AFMKernel", "AFMShell", "StandardPlugins"]),

        .target(name: "TestSupport", dependencies: ["AFMKernel"], path: "Tests/TestSupport"),
        .testTarget(name: "KernelTests", dependencies: ["AFMKernel", "TestSupport"], swiftSettings: testingPlugin),
        .testTarget(name: "PluginTests", dependencies: ["AFMKernel", "AFMContracts", "TestSupport"] + pluginDependencies,
                    swiftSettings: testingPlugin),
        .testTarget(name: "ShellTests", dependencies: ["AFMKernel", "AFMContracts", "AFMShell", "StandardPlugins", "TestSupport"],
                    swiftSettings: testingPlugin),
    ] + plugins
)

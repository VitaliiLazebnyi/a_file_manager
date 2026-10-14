// swift-tools-version:6.2
import Foundation
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

/// Every target is compiled in the Swift 6 language mode (data races are errors), with every
/// warning an error and the upcoming features that make code more explicit.
let strict: [SwiftSetting] = [
    .treatAllWarnings(as: .error),
    .enableUpcomingFeature("ExistentialAny"),
    .enableUpcomingFeature("MemberImportVisibility"),
    .enableUpcomingFeature("InternalImportsByDefault")
]

/// With the Command Line Tools alone (no Xcode), incremental test builds lose the path to the
/// Swift Testing macro plugin; it is passed explicitly where that toolchain is the active one.
let commandLineToolsTesting: String = "/Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing"
let usesCommandLineTools: Bool =
    ProcessInfo.processInfo.environment["DEVELOPER_DIR"] == nil
    && FileManager.default.fileExists(atPath: commandLineToolsTesting)
let testSettings: [SwiftSetting] =
    strict
    + (usesCommandLineTools
        ? [.unsafeFlags(["-plugin-path", commandLineToolsTesting])] : [])

func plugin(_ name: String, needsShell: Bool = false) -> Target {
    var dependencies: [Target.Dependency] = ["AFMKernel", "AFMContracts"]
    if needsShell {
        dependencies.append("AFMShell")
    }
    return .target(
        name: name + "Plugin", dependencies: dependencies, path: "Sources/Plugins/" + name,
        swiftSettings: strict)
}

let plugins: [Target] = [
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
    plugin("Configuration", needsShell: true)
]
let pluginDependencies: [Target.Dependency] = plugins.map { Target.Dependency(stringLiteral: $0.name) }

let kernel: [Target.Dependency] = ["AFMKernel"]
let kernelAndContracts: [Target.Dependency] = ["AFMKernel", "AFMContracts"]

let coreTargets: [Target] = [
    .target(name: "AFMKernel", swiftSettings: strict),
    .target(name: "AFMContracts", dependencies: kernel, swiftSettings: strict),
    .target(name: "AFMShell", dependencies: kernelAndContracts, swiftSettings: strict),
    .target(name: "StandardPlugins", dependencies: kernel + pluginDependencies, swiftSettings: strict),
    .executableTarget(
        name: "AFileManager", dependencies: ["AFMKernel", "AFMShell", "StandardPlugins"],
        swiftSettings: strict)
]

let testTargets: [Target] = [
    .target(name: "TestSupport", dependencies: kernel, path: "Tests/TestSupport", swiftSettings: strict),
    .testTarget(name: "KernelTests", dependencies: ["AFMKernel", "TestSupport"], swiftSettings: testSettings),
    .testTarget(
        name: "PluginTests", dependencies: kernelAndContracts + ["TestSupport"] + pluginDependencies,
        swiftSettings: testSettings),
    .testTarget(
        name: "ShellTests",
        dependencies: ["AFMKernel", "AFMContracts", "AFMShell", "StandardPlugins", "TestSupport"],
        swiftSettings: testSettings),
    // The benchmarks of the hot paths with their limits; run by Scripts/benchmarks.sh, in release.
    .executableTarget(
        name: "Benchmarks",
        dependencies: ["AFMKernel", "TestSupport", "LocalFileSystemPlugin", "FileOperationsPlugin", "ArchivesPlugin"],
        path: "Tests/Benchmarks", swiftSettings: strict)
]

let package = Package(
    name: "AFileManager",
    platforms: [.macOS(.v14)],
    dependencies: [
        // `swift package generate-documentation`, used by the docs gate of Scripts/check.sh.
        .package(url: "https://github.com/swiftlang/swift-docc-plugin", from: "1.4.0")
    ],
    targets: coreTargets + testTargets + plugins
)

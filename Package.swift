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
private let kStrict: [SwiftSetting] = [
    .treatAllWarnings(as: .error),
    .enableUpcomingFeature("ExistentialAny"),
    .enableUpcomingFeature("MemberImportVisibility"),
    .enableUpcomingFeature("InternalImportsByDefault")
]

/// With the Command Line Tools alone (no Xcode), incremental test builds lose the path to the
/// Swift Testing macro plugin; it is passed explicitly where that toolchain is the active one.
private let kCommandLineToolsTesting: String = "/Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing"
private let kUsesCommandLineTools: Bool =
    ProcessInfo.processInfo.environment["DEVELOPER_DIR"] == nil
    && FileManager.default.fileExists(atPath: kCommandLineToolsTesting)
private let kTestSettings: [SwiftSetting] =
    kStrict
    + (kUsesCommandLineTools
        ? [.unsafeFlags(["-plugin-path", kCommandLineToolsTesting])] : [])

private func plugin(_ name: String, needsShell: Bool = false) -> Target {
    var dependencies: [Target.Dependency] = ["AFMKernel", "AFMContracts"]
    if needsShell {
        dependencies.append("AFMShell")
    }
    return .target(
        name: name + "Plugin",
        dependencies: dependencies,
        path: "Sources/Plugins/" + name,
        swiftSettings: kStrict
    )
}

private let kPlugins: [Target] = [
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
private let kPluginDependencies: [Target.Dependency] = kPlugins.map { Target.Dependency(stringLiteral: $0.name) }

private let kKernel: [Target.Dependency] = ["AFMKernel"]
private let kKernelAndContracts: [Target.Dependency] = ["AFMKernel", "AFMContracts"]

private let kCoreTargets: [Target] = [
    .target(name: "AFMKernel", swiftSettings: kStrict),
    .target(name: "AFMContracts", dependencies: kKernel, swiftSettings: kStrict),
    .target(name: "AFMShell", dependencies: kKernelAndContracts, swiftSettings: kStrict),
    .target(name: "StandardPlugins", dependencies: kKernel + kPluginDependencies, swiftSettings: kStrict),
    .executableTarget(
        name: "AFileManager",
        dependencies: ["AFMShell", "StandardPlugins"],
        swiftSettings: kStrict
    )
]

private let kTestTargets: [Target] = [
    .target(name: "TestSupport", dependencies: kKernel, path: "Tests/TestSupport", swiftSettings: kStrict),
    .testTarget(name: "KernelTests", dependencies: ["AFMKernel", "TestSupport"], swiftSettings: kTestSettings),
    .testTarget(
        name: "PluginTests",
        dependencies: kKernelAndContracts + ["TestSupport"] + kPluginDependencies,
        swiftSettings: kTestSettings
    ),
    .testTarget(
        name: "ShellTests",
        dependencies: ["AFMKernel", "AFMContracts", "AFMShell", "ConfigurationPlugin", "StandardPlugins", "TestSupport"],
        swiftSettings: kTestSettings
    ),
    // The benchmarks of the hot paths with their limits; run by Scripts/benchmarks.sh, in release.
    .executableTarget(
        name: "Benchmarks",
        dependencies: ["AFMKernel", "TestSupport", "LocalFileSystemPlugin", "FileOperationsPlugin", "ArchivesPlugin"],
        path: "Tests/Benchmarks",
        exclude: ["limits.json"],
        swiftSettings: kStrict
    )
]

private let kPackage = Package(
    name: "AFileManager",
    platforms: [.macOS(.v14)],
    dependencies: [
        // `swift package generate-documentation`, used by the docs gate of Scripts/check.sh.
        .package(url: "https://github.com/swiftlang/swift-docc-plugin", from: "1.4.0")
    ],
    targets: kCoreTargets + kTestTargets + kPlugins
)

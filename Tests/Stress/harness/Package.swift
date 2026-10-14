// swift-tools-version:6.2
import PackageDescription

// The stress harnesses, built against the project's own sources: `Sources` and `TestSupport` in
// this directory are symbolic links to `../../../Sources` and `../../../Tests/TestSupport`.
// The target list mirrors the root Package.swift (without its test targets and the program), and
// every target is compiled as there: Swift 6 language mode, every warning an error, the same
// upcoming features.

/// The Swift settings of every target of the root package.
internal let kStrict: [SwiftSetting] = [
    .treatAllWarnings(as: .error),
    .enableUpcomingFeature("ExistentialAny"),
    .enableUpcomingFeature("MemberImportVisibility"),
    .enableUpcomingFeature("InternalImportsByDefault")
]

/// A plugin module of the project, as the root package declares it.
internal func plugin(_ name: String, needsShell: Bool) -> Target {
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

/// The plugins that need the kernel and the contracts only.
internal let kKernelPlugins: [String] = [
    "LocalFileSystem", "FileOperations", "Navigation", "FolderTabs", "Selection", "ViewOptions", "Clipboard",
    "MacIntegration", "Archives", "FileTools", "VirtualFolders"
]

/// The plugins that also open windows of their own.
internal let kShellPlugins: [String] = [
    "Viewer", "FindFiles", "Network", "MultiRename", "DirectorySync", "CompareContent", "Places", "FileProperties",
    "SystemTools", "Configuration"
]

/// Every plugin module.
internal let kPlugins: [Target] =
    kKernelPlugins.map { plugin($0, needsShell: false) } + kShellPlugins.map { plugin($0, needsShell: true) }

/// What every harness depends on: the whole program, the test helpers and the measuring tools.
internal let kEverything: [Target.Dependency] =
    ["AFMKernel", "AFMContracts", "AFMShell", "StandardPlugins", "TestSupport", "StressKit"]
    + kPlugins.map { Target.Dependency(stringLiteral: $0.name) }

/// One stress harness: `Stress/<name>`, built as the program `<name>`.
internal func stress(_ name: String) -> Target {
    .executableTarget(name: name, dependencies: kEverything, path: "Stress/" + name, swiftSettings: kStrict)
}

// The package: the project's modules, the measuring tools and the harnesses. SwiftPM keeps the value that
// `Package(...)` makes; nothing refers to it by name.
_ = Package(
    name: "AFMStress",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "AFMKernel", swiftSettings: kStrict),
        .target(name: "AFMContracts", dependencies: ["AFMKernel"], swiftSettings: kStrict),
        .target(name: "AFMShell", dependencies: ["AFMKernel", "AFMContracts"], swiftSettings: kStrict),
        .target(
            name: "StandardPlugins",
            dependencies: ["AFMKernel"] + kPlugins.map { Target.Dependency(stringLiteral: $0.name) },
            swiftSettings: kStrict
        ),
        .target(name: "TestSupport", dependencies: ["AFMKernel"], path: "TestSupport", swiftSettings: kStrict),
        .target(name: "StressKit", path: "Stress/StressKit", swiftSettings: kStrict),
        stress("StressPanel"),
        stress("StressParallel"),
        stress("StressJobs"),
        stress("StressArchives"),
        stress("StressFind"),
        stress("StressViewer")
    ] + kPlugins
)

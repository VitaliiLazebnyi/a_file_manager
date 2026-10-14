// swift-tools-version:6.2
import PackageDescription

// The fuzz drivers, built against the project's own sources: `Sources` and `TestSupport` in this
// directory are symbolic links to `../../../Sources` and `../../../Tests/TestSupport`. Every target
// is compiled as in the root package: Swift 6 language mode, every warning an error, the same
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

/// One fuzz driver: `Fuzz/fuzz-<name>`, built as the program `fuzz-<name>`.
internal func fuzz(_ name: String, _ plugins: [Target.Dependency]) -> Target {
    let common: [Target.Dependency] = ["FuzzCore", "AFMKernel", "AFMContracts", "TestSupport"]
    return .executableTarget(
        name: "fuzz-" + name,
        dependencies: common + plugins,
        path: "Fuzz/fuzz-" + name,
        swiftSettings: kStrict
    )
}

/// The fuzz drivers and the plugins each one fuzzes.
internal let kDrivers: [Target] = [
    fuzz("arch", ["ArchivesPlugin", "LocalFileSystemPlugin"]),
    fuzz("net", ["NetworkPlugin"]),
    fuzz("tools", ["FileToolsPlugin", "LocalFileSystemPlugin"]),
    fuzz("kernel", []),
    fuzz(
        "misc",
        ["FilePropertiesPlugin", "FolderTabsPlugin", "SelectionPlugin", "ConfigurationPlugin", "PlacesPlugin"]
    ),
    fuzz("viewer", ["ViewerPlugin"]),
    fuzz("diff", ["CompareContentPlugin", "MultiRenamePlugin", "FileOperationsPlugin"])
]

/// The package: the project's modules, the fuzzer and its drivers.
internal let kPackage = Package(
    name: "AFMFuzz",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "AFMKernel", swiftSettings: kStrict),
        .target(name: "AFMContracts", dependencies: ["AFMKernel"], swiftSettings: kStrict),
        .target(name: "AFMShell", dependencies: ["AFMKernel", "AFMContracts"], swiftSettings: kStrict),
        .target(name: "TestSupport", dependencies: ["AFMKernel"], path: "TestSupport", swiftSettings: kStrict),
        .target(name: "FuzzC", path: "Fuzz/FuzzC", cSettings: [.treatAllWarnings(as: .error)]),
        .target(name: "FuzzCore", dependencies: ["FuzzC"], path: "Fuzz/FuzzCore", swiftSettings: kStrict)
    ] + kDrivers + kPlugins
)

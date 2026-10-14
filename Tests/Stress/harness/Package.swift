// swift-tools-version:5.10
import PackageDescription

// The stress harnesses, built against the project's own sources: `Sources` and `TestSupport` in
// this directory are symbolic links to `../../../Sources` and `../../../Tests/TestSupport`.
// The target list mirrors the root Package.swift (without its test targets and the program).

func plugin(_ name: String, needsShell: Bool = false) -> Target {
    .target(
        name: name + "Plugin", dependencies: ["AFMKernel", "AFMContracts"] + (needsShell ? ["AFMShell"] : []),
        path: "Sources/Plugins/" + name)
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
    plugin("Configuration", needsShell: true)
]
let pluginDependencies = plugins.map { Target.Dependency(stringLiteral: $0.name) }

let package = Package(
    name: "AFMStress",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "AFMKernel"),
        .target(name: "AFMContracts", dependencies: ["AFMKernel"]),
        .target(name: "AFMShell", dependencies: ["AFMKernel", "AFMContracts"]),
        .target(name: "StandardPlugins", dependencies: ["AFMKernel"] + pluginDependencies),

        .target(name: "TestSupport", dependencies: ["AFMKernel"], path: "TestSupport")
    ] + plugins
)

let everything: [Target.Dependency] =
    ["AFMKernel", "AFMContracts", "AFMShell", "StandardPlugins", "TestSupport", "StressKit"] + pluginDependencies
func stress(_ name: String) -> Target {
    .executableTarget(name: name, dependencies: everything, path: "Stress/" + name)
}
package.targets += [
    .target(name: "StressKit", path: "Stress/StressKit"),
    stress("StressPanel"), stress("StressParallel"), stress("StressJobs"), stress("StressArchives"),
    stress("StressFind"), stress("StressViewer")
]

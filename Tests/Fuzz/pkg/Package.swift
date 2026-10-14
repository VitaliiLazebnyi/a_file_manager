// swift-tools-version:5.10
import PackageDescription

// The fuzz drivers, built against the project's own sources: `Sources` and `TestSupport` in this
// directory are symbolic links to `../../../Sources` and `../../../Tests/TestSupport`.

func plugin(_ name: String, needsShell: Bool = false) -> Target {
    .target(
        name: name + "Plugin", dependencies: ["AFMKernel", "AFMContracts"] + (needsShell ? ["AFMShell"] : []),
        path: "Sources/Plugins/" + name)
}
let plugins = [
    plugin("LocalFileSystem"), plugin("FileOperations"), plugin("Navigation"), plugin("FolderTabs"),
    plugin("Selection"), plugin("ViewOptions"), plugin("Clipboard"), plugin("Viewer", needsShell: true),
    plugin("FindFiles", needsShell: true), plugin("MacIntegration"), plugin("Archives"),
    plugin("Network", needsShell: true), plugin("MultiRename", needsShell: true), plugin("FileTools"),
    plugin("DirectorySync", needsShell: true), plugin("CompareContent", needsShell: true),
    plugin("Places", needsShell: true), plugin("VirtualFolders"), plugin("FileProperties", needsShell: true),
    plugin("SystemTools", needsShell: true), plugin("Configuration", needsShell: true)
]
func fuzz(_ name: String, _ deps: [String]) -> Target {
    .executableTarget(
        name: "fuzz-" + name,
        dependencies: ["FuzzCore", "AFMKernel", "AFMContracts", "TestSupport"]
            + deps.map { Target.Dependency(stringLiteral: $0) },
        path: "Fuzz/fuzz-" + name)
}
let package = Package(
    name: "AFMFuzz",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "AFMKernel"),
        .target(name: "AFMContracts", dependencies: ["AFMKernel"]),
        .target(name: "AFMShell", dependencies: ["AFMKernel", "AFMContracts"]),
        .target(name: "TestSupport", dependencies: ["AFMKernel"], path: "TestSupport"),
        .target(name: "FuzzC", path: "Fuzz/FuzzC"),
        .target(name: "FuzzCore", dependencies: ["FuzzC"], path: "Fuzz/FuzzCore"),
        fuzz("arch", ["ArchivesPlugin", "LocalFileSystemPlugin"]),
        fuzz("net", ["NetworkPlugin"]),
        fuzz("tools", ["FileToolsPlugin", "LocalFileSystemPlugin"]),
        fuzz("kernel", []),
        fuzz(
            "misc",
            ["FilePropertiesPlugin", "FolderTabsPlugin", "SelectionPlugin", "ConfigurationPlugin", "PlacesPlugin"]),
        fuzz("viewer", ["ViewerPlugin"]),
        fuzz("diff", ["CompareContentPlugin", "MultiRenamePlugin", "FileOperationsPlugin"])
    ] + plugins
)

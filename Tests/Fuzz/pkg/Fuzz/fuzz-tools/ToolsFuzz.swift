import AFMKernel
import Foundation
import FuzzCore
import LocalFileSystemPlugin

/// What the FileTools targets share: the file systems, the work folder with its canary, and the
/// check that nothing was written outside the target folder.
internal enum ToolsFuzz {
    /// What the canary file holds; it must stay as it is.
    internal static let canaryText = Data("canary: must stay as it is\n".utf8)

    /// The names a checksum file is tried under (the name chooses the method).
    internal static let checksumNames = [
        "x.sfv", "x.md5", "x.sha1", "x.sha256", "x.sha512", "x.sha224", "x.sha384", "x.sha3", "x.b3", "x.bk3",
        "SHA256SUMS",
        "x.sha", "x.txt"
    ]

    /// The local file system, made by `setUp`.
    @MainActor private static var localStorage: LocalFileSystem?

    /// The registry holding the local file system, made by `setUp`.
    @MainActor private static var registryStorage: FileSystemRegistry?

    /// The local file system.
    @MainActor internal static var local: LocalFileSystem {
        guard let localStorage else {
            preconditionFailure("setUp makes the local file system before the first run")
        }
        return localStorage
    }

    /// The registry holding the local file system.
    @MainActor internal static var registry: FileSystemRegistry {
        guard let registryStorage else {
            preconditionFailure("setUp makes the registry before the first run")
        }
        return registryStorage
    }

    /// Makes the local file system and a registry that holds it.
    @MainActor
    internal static func setUp() {
        let made = LocalFileSystem()
        let madeRegistry = FileSystemRegistry()
        madeRegistry.register(made)
        localStorage = made
        registryStorage = madeRegistry
    }

    /// The bytes as UTF-8 text; what is not UTF-8 becomes U+FFFD, as `String(decoding:as:)` does it.
    ///
    /// - Parameter bytes: The bytes.
    /// - Returns: The text.
    internal static func text(_ bytes: [UInt8]) -> String {
        fzText(bytes)
    }

    /// The names in a folder, sorted; none when it cannot be read.
    ///
    /// - Parameter path: The folder.
    /// - Returns: The names.
    internal static func names(_ path: String) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: path)) ?? []).sorted()
    }

    /// Makes `<work>/x/in` (the inputs), `<work>/x/out/target` (where results go) and
    /// `<work>/x/out/canary/keep.txt`.
    ///
    /// - Returns: `<work>/x`.
    @MainActor
    internal static func prepare() -> String {
        let manager = FileManager.default
        let root = fzWorkDir + "/x"
        try? manager.removeItem(atPath: root)
        try? manager.createDirectory(atPath: root + "/in", withIntermediateDirectories: true)
        try? manager.createDirectory(atPath: root + "/out/target", withIntermediateDirectories: true)
        try? manager.createDirectory(atPath: root + "/out/canary", withIntermediateDirectories: true)
        manager.createFile(atPath: root + "/out/canary/keep.txt", contents: canaryText)
        return root
    }

    /// Checks that nothing was written but plain files in the target, and the canary is untouched.
    ///
    /// - Parameters:
    ///   - root: The folder `prepare` made.
    ///   - inputs: The names the input folder may hold.
    ///   - what: What ran, for the finding.
    internal static func checkContainment(_ root: String, inputs: Set<String>, what: String) {
        fzCheck(names(root) == ["in", "out"], "escape-work-root", "\(what): \(names(root))")
        fzCheck(
            names(root + "/out") == ["canary", "target"],
            "escape-next-to-target",
            "\(what): \(names(root + "/out"))"
        )
        fzCheck(
            names(root + "/out/canary") == ["keep.txt"],
            "escape-into-canary",
            "\(what): \(names(root + "/out/canary"))"
        )
        fzCheck(
            FileManager.default.contents(atPath: root + "/out/canary/keep.txt") == canaryText,
            "escape-canary-changed",
            what
        )
        fzCheck(
            Set(names(root + "/in")).isSubset(of: inputs),
            "stray-next-to-input",
            "\(what): \(names(root + "/in"))"
        )
        // What was written is plain files directly in the target.
        for name in names(root + "/out/target") {
            var status = stat()
            if lstat(root + "/out/target/" + name, &status) == 0 {
                fzCheck(status.st_mode & S_IFMT == S_IFREG, "target-not-a-plain-file", "\(what): \(name)")
            }
        }
    }

    /// The item of a local path.
    ///
    /// - Parameter path: The path.
    /// - Returns: The item, nil when there is none.
    @MainActor
    internal static func item(_ path: String) -> FileItem? {
        registry.item(at: URL(fileURLWithPath: path))
    }
}

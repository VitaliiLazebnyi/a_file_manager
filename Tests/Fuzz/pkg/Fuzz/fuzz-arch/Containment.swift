import Foundation
import FuzzCore

@testable import ArchivesPlugin

// The folder each full round works in:
//
//   <work>/x/in/<archive>          the input
//   <work>/x/out/target/           where it is unpacked
//   <work>/x/out/canary/keep.txt   must stay as it is; nothing else may appear in out/ or x/

/// What the canary file holds.
internal let kCanaryText = Data("canary: must stay as it is\n".utf8)

/// The names in a folder, sorted; none when it cannot be read.
internal func names(_ path: String) -> [String] {
    ((try? FileManager.default.contentsOfDirectory(atPath: path)) ?? []).sorted()
}

/// Nothing appeared next to the target, the canary is untouched and nothing lies next to the archive.
internal func checkContainment(_ root: String, archiveName: String, what: String) {
    let out = root + "/out"
    fzCheck(names(root) == ["in", "out"], "escape-work-root", "\(what): \(names(root))")
    fzCheck(
        names(out).allSatisfy { $0 == "canary" || $0 == "target" },
        "escape-next-to-target",
        "\(what): \(names(out))"
    )
    fzCheck(names(out + "/canary") == ["keep.txt"], "escape-into-canary", "\(what): \(names(out + "/canary"))")
    fzCheck(
        FileManager.default.contents(atPath: out + "/canary/keep.txt") == kCanaryText,
        "escape-canary-changed",
        what
    )
    var info = stat()
    if lstat(out + "/canary/keep.txt", &info) == 0 {
        fzCheck(info.st_nlink == 1, "escape-hardlink-to-canary", what)
        fzCheck(info.st_mode & 0o7777 == 0o644, "escape-canary-mode", "\(what): \(String(info.st_mode, radix: 8))")
    }
    let inside = names(root + "/in")
    fzCheck(inside.allSatisfy { $0 == archiveName }, "stray-next-to-archive", "\(what): \(inside)")
}

/// No link below `target` may be a way out that something was written through: every regular
/// file must really lie below the target.
internal func checkTree(_ target: String) {
    guard let real = realpath(target, nil) else {
        return
    }
    let base = String(cString: real)
    free(real)
    guard let walker = FileManager.default.enumerator(atPath: target) else {
        return
    }
    var seen = 0
    for case let relative as String in walker {
        seen += 1
        if seen > 5_000 {
            break
        }
        let path = target + "/" + relative
        var info = stat()
        guard lstat(path, &info) == 0, info.st_mode & S_IFMT == S_IFREG else {
            continue
        }
        fzCheck(info.st_mode & 0o6000 == 0, "unpacked-setuid", "\(relative) \(String(info.st_mode, radix: 8))")
        if let resolvedPointer = realpath(path, nil) {
            let resolved = String(cString: resolvedPointer)
            free(resolvedPointer)
            // By bytes: a name may begin with a mark that joins the `/` before it into one character.
            fzCheck(
                Array(resolved.utf8).starts(with: Array((base + "/").utf8)),
                "escape-through-link",
                "\(relative) -> \(resolved)"
            )
        }
    }
}

/// Makes the folder of a full round anew and writes the input into it.
@MainActor
internal func prepare(_ bytes: [UInt8], name: String) -> (root: String, archive: URL) {
    let fileManager = FileManager.default
    let root = fzWorkDir + "/x"
    try? fileManager.removeItem(atPath: root)
    // What the last input left may be unremovable as it is (folders without write permission).
    if fileManager.fileExists(atPath: root) {
        _ = try? Process.run(URL(fileURLWithPath: "/bin/chmod"), arguments: ["-R", "u+rwx", root]).waitUntilExit()
        try? fileManager.removeItem(atPath: root)
    }
    try? fileManager.createDirectory(atPath: root + "/in", withIntermediateDirectories: true)
    try? fileManager.createDirectory(atPath: root + "/out/canary", withIntermediateDirectories: true)
    fileManager.createFile(
        atPath: root + "/out/canary/keep.txt",
        contents: kCanaryText,
        attributes: [.posixPermissions: 0o644]
    )
    let archive = URL(fileURLWithPath: root + "/in/" + name)
    fileManager.createFile(atPath: archive.path, contents: Data(bytes))
    return (root, archive)
}

/// Whether bsdtar reads the input: a process per input, and somebody else's parser; skipped.
internal func isForeign(_ bytes: [UInt8], name: String) -> Bool {
    ArchiveFormat.detect(head: Data(bytes.prefix(512)), name: name) { _ in true } == .foreign
}

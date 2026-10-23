import AFMKernel
import Foundation
import FuzzCore
import TestSupport

@testable import FilePropertiesPlugin

/// The `descript-store` target: the store on top of a file system, as the Comment column and the
/// Comment dialog use it.
@MainActor
internal enum DescriptStoreTarget {
    /// The target.
    internal static func make() -> FuzzTarget {
        let fileSystem = MemoryFileSystem()
        let registry = FileSystemRegistry()
        return FuzzTarget(
            "descript-store",
            maxLen: 4_096,
            dict: ["\"", "\r\n", " ", "\u{04}\u{C2}", "\\n"],
            rawDict: [[0xFF, 0xFE], [0xFE, 0xFF], [0xEF, 0xBB, 0xBF]],
            seeds: { seedTexts(["a.txt hello\r\n\"b c.txt\" world\r\n"]) },
            setUp: { registry.register(fileSystem) },
            run: { bytes in run(bytes, fileSystem: fileSystem, registry: registry) }
        )
    }

    /// Writes the input as the folder's descript.ion and sets one comment through the store.
    private static func run(_ bytes: [UInt8], fileSystem: MemoryFileSystem, registry: FileSystemRegistry) {
        fileSystem.removeTree("/d")
        let dir = fileSystem.addDirectory("/d")
        do {
            let writer = try fileSystem.write(dir.appending(name: DescriptIon.fileName))
            try writer.write(Data(bytes))
            try writer.close(attributes: FileAttributes())
        } catch {
            return
        }
        let store = CommentStore(fileSystems: registry)
        let comments = store.comments(in: dir, cancellation: CancellationFlag())
        _ = store.comment(
            for: FileItem(url: dir.appending(name: "a.txt"), name: "a.txt"),
            cancellation: CancellationFlag()
        )
        do {
            try store.setComment(
                "fresh\ncomment",
                for: "new.txt",
                in: dir,
                hidden: false,
                cancellation: CancellationFlag()
            )
        } catch {
            return
        }
        checkEdit(before: comments, after: store.comments(in: dir, cancellation: CancellationFlag()))
    }

    /// The new comment is stored, and every other comment stays as it was.
    private static func checkEdit(before comments: [String: String], after: [String: String]) {
        if !DescriptChecks.checksAll, comments.keys.contains(where: DescriptChecks.readsLikeMark) {
            return
        }
        fzCheck(after["new.txt"] == "fresh\ncomment", "descript-store-set-lost", "\(after["new.txt"] ?? "nil")")
        let known = comments.contains { entry in
            DescriptChecks.readsLikeMark(entry.key) || DescriptChecks.isGlued(entry.key + " " + entry.value + "\r\n")
                || DescriptChecks.isGlued("\"" + entry.key + "\" ")
        }
        if known, !DescriptChecks.checksAll {
            return
        }
        // A comment that ends with the text of the multi-line marker itself (U+0004 Â) cannot be told from a
        // marked one once it is written: the format has no way to say so. Left out, as in `descript-line`.
        for (name, comment) in comments where name != "new.txt" && !comment.hasSuffix("\u{04}\u{C2}") {
            let now = after[name] ?? "nil"
            fzCheck(
                after[name] == comment,
                "descript-store-other-comment-changed",
                "name \(name.debugDescription) before \(comment.debugDescription) after \(now.debugDescription)"
            )
        }
    }
}

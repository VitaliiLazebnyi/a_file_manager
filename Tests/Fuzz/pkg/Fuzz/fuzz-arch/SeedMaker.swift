import AFMKernel
import Foundation

@testable import ArchivesPlugin

// MARK: - seeds made by the program's own Packer

/// Packs a small tree into every format the Packer writes, into the seed folders below `dir`,
/// and prints one line per archive.
@MainActor
internal func makeOwnSeeds(_ dir: String) {
    let tree = dir + "/work.tmp/tree"
    makeSeedTree(tree)
    let store = ArchiveStore(environment: ArchiveRig.environment)
    let maker = SeedMaker(dir: dir, tree: tree, store: store, registry: ArchiveRig.registry(for: store))
    for seed in SeedArchive.all {
        maker.pack(seed)
    }
    maker.packNested()
    store.close()
    try? FileManager.default.removeItem(atPath: dir + "/work.tmp")
}

/// A file, an empty file, a long name in a subfolder, an empty folder and a link.
private func makeSeedTree(_ tree: String) {
    let fileManager = FileManager.default
    try? fileManager.createDirectory(atPath: tree + "/sub/hollow", withIntermediateDirectories: true)
    fileManager.createFile(atPath: tree + "/a.txt", contents: Data("hello from the packer\n".utf8))
    fileManager.createFile(atPath: tree + "/empty", contents: Data())
    fileManager.createFile(
        atPath: tree + "/sub/übung – 日本.txt",
        contents: Data(String(repeating: "jack ", count: 200).utf8)
    )
    try? fileManager.createSymbolicLink(atPath: tree + "/link", withDestinationPath: "a.txt")
}

/// Packs the seeds of `mkseeds` with the program's own Packer.
internal struct SeedMaker {
    /// The seeds directory.
    internal let dir: String
    /// The tree that is packed.
    internal let tree: String
    /// The store the Packer writes through.
    internal let store: ArchiveStore
    /// The local disk and the archive file systems.
    internal let registry: FileSystemRegistry

    /// Packs one archive and prints its name and "ok", or "FAILED" and why.
    internal func pack(_ seed: SeedArchive) {
        var options = PackOptions()
        options.format = seed.format
        options.password = seed.password
        // The program's default is AES-256; the seed of the old encryption is kept beside it.
        if seed.name == "own-crypt.zip" {
            options.encryption = .legacy
        }
        let packer = Packer(fileSystems: registry, store: store, monitor: QuietMonitor(), options: options)
        guard let item = registry.item(at: URL(fileURLWithPath: seed.isSingleFile ? tree + "/a.txt" : tree)) else {
            print("no item")
            return
        }
        let result = packer.run([item], archive: URL(fileURLWithPath: dir + "/" + seed.folder + "/" + seed.name))
        print(seed.name, result.failure.map { "FAILED \($0)" } ?? "ok")
    }

    /// A ZIP holding another archive, by the packer as well.
    internal func packNested() {
        guard let tarSeed = registry.item(at: URL(fileURLWithPath: dir + "/tar/own.tar")),
            let text = registry.item(at: URL(fileURLWithPath: tree + "/a.txt"))
        else {
            return
        }
        let packer = Packer(fileSystems: registry, store: store, monitor: QuietMonitor(), options: PackOptions())
        let result = packer.run([tarSeed, text], archive: URL(fileURLWithPath: dir + "/zip/own-nested.zip"))
        print("own-nested.zip", result.failure.map { "FAILED \($0)" } ?? "ok")
    }
}

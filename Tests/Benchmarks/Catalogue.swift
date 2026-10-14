import AFMKernel
import FileOperationsPlugin
import Foundation
import LocalFileSystemPlugin
import TestSupport

@testable import ArchivesPlugin

/// The hot paths whose time and memory have limits: the work on a folder of a million entries
/// (sorting, resorting, collecting in batches, filtering, marking), the order of names, the
/// spreading of work over the cores, reading a large folder on the disk, copying a large file
/// as a job does, and listing a large archive.
@MainActor
internal enum Catalogue {
    /// Entries of the large in-memory folder.
    private static let million = 1_000_000
    /// Files in the folder on the disk and the archive, and names in the collation benchmark.
    private static let large = 100_000
    /// Bytes of the file the copy benchmark copies.
    private static let copySize = 512 << 20

    /// Every benchmark, in the order they run.
    internal static let all: [Benchmark] = [
        sorting("sort-name-1m", ListOrder(key: .name)),
        sorting("sort-ext-1m", ListOrder(key: .ext)),
        sorting("sort-size-1m", ListOrder(key: .size, descending: true)),
        Benchmark(name: "resort-reverse-1m", summary: "turning the order of a sorted list round") {
            let sorted = Sorter.sort(Fixtures.items(million), by: ListOrder(key: .name))
            return {
                _ = Sorter.resort(sorted, from: ListOrder(key: .name), to: ListOrder(key: .name, descending: true))
            }
        },
        Benchmark(name: "batches-1m", summary: "a folder arriving in batches of 10,000, merged in order") {
            let items = Fixtures.items(million)
            let batches = stride(from: 0, to: million, by: 10_000).map { Array(items[$0..<min($0 + 10_000, million)]) }
            return {
                var list = SortedFileList(order: ListOrder(key: .name))
                for batch in batches {
                    list.add(batch)
                }
            }
        },
        Benchmark(name: "filter-1m", summary: "a display filter of two masks") {
            let items = Fixtures.items(million)
            return {
                _ = PanelModel.filtered(items, by: .mask("*.jpg *.txt"))
            }
        },
        marking(),
        Benchmark(name: "collation-100k", summary: "names in the order of names, keys made once") {
            let names = (0..<large).map(Fixtures.name)
            return {
                _ = Sorter.sorted(names) { $0 }
            }
        },
        Benchmark(name: "parallel-map-1m", summary: "a million small pieces of work spread over the cores") {
            let values = Array(0..<million)
            return {
                _ = Parallel.map(values) { Fixtures.name($0).utf8.count }
            }
        },
        localListing(),
        copying(),
        archiveListing()
    ]

    /// Sorting the million entries.
    private static func sorting(_ name: String, _ order: ListOrder) -> Benchmark {
        Benchmark(name: name, summary: "sorting a folder of a million entries") {
            let items = Fixtures.items(million)
            return {
                _ = Sorter.sort(items, by: order)
            }
        }
    }

    /// Marking in a panel that shows the million entries.
    private static func marking() -> Benchmark {
        Benchmark(name: "mark-1m", summary: "marking by mask, all, the opposite, nothing") {
            let order = ListOrder(key: .name)
            let directory = URL(fileURLWithPath: "/bench", isDirectory: true)
            let model = PanelModel(directory: directory, sort: order, showHidden: true)
            let listing = Listing(
                directory: directory,
                items: Sorter.sort(Fixtures.items(million), by: order),
                parent: nil,
                root: URL(fileURLWithPath: "/")
            )
            model.show(listing, presorted: order)
            return {
                model.select(mask: "*.pdf *.JPG")
                model.selectAll()
                model.invertSelection()
                model.clearSelection()
            }
        }
    }

    /// Reading a folder on the disk with the local file system, as a panel does.
    private static func localListing() -> Benchmark {
        Benchmark(name: "load-local-100k", summary: "reading a folder of 100,000 files on the disk") {
            let folder = try Fixtures.localFolder(large)
            let fileSystems = FileSystemRegistry()
            fileSystems.register(LocalFileSystem())
            return {
                _ = try PanelLoader.load(folder, showHidden: true, fileSystems: fileSystems)
            }
        }
    }

    /// Copying a large file as a job does, between two folders of the in-memory file system.
    private static func copying() -> Benchmark {
        Benchmark(name: "copy-memory-512mb", summary: "a 512 MB file copied by a file job") {
            let memory = MemoryFileSystem()
            // Read and written in blocks, as between two file systems, not handed over whole.
            memory.refusesInternalCopy = true
            let fileSystems = FileSystemRegistry()
            fileSystems.register(memory)
            let source = memory.addFile("/from/large.bin", String(repeating: "x", count: copySize))
            let target = memory.addDirectory("/to")
            return {
                let result = FileJob(
                    kind: .copy,
                    sources: [source],
                    target: TargetSpec(directory: target),
                    fileSystems: fileSystems
                )
                .run()
                guard result.failureCount == 0, memory.exists("/to/large.bin") else {
                    throw CocoaError(.fileWriteUnknown)
                }
            }
        }
    }

    /// Opening a ZIP archive of 100,000 entries and listing its folder.
    private static func archiveListing() -> Benchmark {
        Benchmark(name: "archive-list-100k", summary: "opening a ZIP of 100,000 entries and listing them") {
            let archive = try Fixtures.archive(large)
            let environment = ArchiveEnvironment()
            environment.flushDelay = nil
            let fileSystems = FileSystemRegistry()
            fileSystems.register(LocalFileSystem())
            let store = ArchiveStore(environment: environment)
            let provider = ArchiveFileSystem(scheme: ArchiveURL.writableScheme, store: store)
            fileSystems.register(provider)
            environment.fileSystems = { [fileSystems] in fileSystems }
            let folder = ArchiveURL.make(
                scheme: ArchiveURL.writableScheme,
                archive: archive,
                innerPath: "folder-\(large)"
            )
            return {
                let items = try provider.list(folder, showHidden: true)
                guard items.count == large else {
                    throw CocoaError(.fileReadCorruptFile)
                }
            }
        }
    }
}

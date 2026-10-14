import AFMKernel
import Foundation
import FuzzCore
import LocalFileSystemPlugin

@testable import ArchivesPlugin

/// What every target shares: the plugin's environment and the local disk, made once per worker.
@MainActor
internal enum ArchiveRig {
    /// The environment, once `setUp` or `setUpForSeeds` made it.
    private static var madeEnvironment: ArchiveEnvironment?
    /// The local disk, once `setUp` or `setUpForSeeds` made it.
    private static var madeLocal: LocalFileSystem?

    /// The surroundings that every archive of the worker shares.
    internal static var environment: ArchiveEnvironment {
        guard let madeEnvironment else {
            preconditionFailure("the archives are not set up")
        }
        return madeEnvironment
    }

    /// The local disk, where the inputs and the unpacked files lie.
    internal static var local: LocalFileSystem {
        guard let madeLocal else {
            preconditionFailure("the archives are not set up")
        }
        return madeLocal
    }

    /// Prepares a worker.
    ///
    /// The plugin's scratch folder goes below the work folder as well.
    internal static func setUp() {
        let tmp = fzWorkDir + "/tmp"
        try? FileManager.default.createDirectory(atPath: tmp, withIntermediateDirectories: true)
        setenv("TMPDIR", tmp, 1)
        let made = ArchiveEnvironment()
        made.flushDelay = nil
        made.unpackedLimit = 8 << 20
        made.askPassword = { _, retry in retry ? nil : "secret" }
        madeEnvironment = made
        madeLocal = LocalFileSystem()
    }

    /// Prepares `mkseeds`, which has no worker and so no work folder: the scratch folder is `scratch`.
    internal static func setUpForSeeds(scratch: String) {
        try? FileManager.default.createDirectory(atPath: scratch, withIntermediateDirectories: true)
        setenv("TMPDIR", scratch, 1)
        let made = ArchiveEnvironment()
        made.flushDelay = nil
        madeEnvironment = made
        madeLocal = LocalFileSystem()
    }

    /// A registry of the local disk and both archive file systems over `store`; the environment finds it.
    internal static func registry(for store: ArchiveStore) -> FileSystemRegistry {
        let registry = FileSystemRegistry()
        let providers: [any FileSystemProvider] = [
            local,
            ArchiveFileSystem(scheme: ArchiveURL.writableScheme, store: store),
            ArchiveFileSystem(scheme: ArchiveURL.readOnlyScheme, store: store)
        ]
        for provider in providers {
            registry.register(provider)
        }
        environment.fileSystems = { registry }
        return registry
    }
}

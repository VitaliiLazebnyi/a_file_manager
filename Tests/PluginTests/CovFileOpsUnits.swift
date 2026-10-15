import AFMKernel
import Foundation
import LocalFileSystemPlugin
import TestSupport
import Testing

@testable import FileOperationsPlugin

/// The small parts of the file operations: places and files on the disk, filters, settings, switches and checksums,
/// with the inputs the other tests do not give them.
@Suite
internal struct CovFileOpsUnits {
    private let box: Sandbox

    /// A sandbox; throws when the disk refuses.
    internal init() throws {
        box = try Sandbox()
    }

    /// The root of a file system written with its slash takes names after it.
    @Test
    internal func theRootOfAFileSystemTakesNames() {
        let memory = MemoryFileSystem()
        let fileSystems = FileSystemRegistry()
        fileSystems.register(memory)
        #expect(RealLocation.takesNames(memory.url("/"), in: fileSystems))
    }

    /// Special nodes are told through links too; what is not on the disk, or not there, has no lock to tell.
    @Test
    internal func specialNodesAndLocksOfWhatIsNotThere() throws {
        let pipe = box.url("pipe")
        #expect(mkfifo(pipe.path, 0o600) == 0)
        try FileManager.default.createSymbolicLink(at: box.url("link"), withDestinationURL: pipe)
        #expect(FileIdentity.isSpecialNode(box.url("link"), followingLinks: true))
        #expect(!FileIdentity.isSpecialNode(box.url("link"), followingLinks: false))
        #expect(!FileIdentity.isSpecialNode(box.url("none"), followingLinks: false))
        #expect(FileIdentity.isLocked(URL(string: "mem:/x")!) == nil)
        #expect(FileIdentity.isLocked(box.url("none")) == nil)
    }

    /// The grain of a volume's times goes by its type, and a share's is not known.
    @Test
    internal func theGrainOfAVolumesTimes() {
        #expect(FileIdentity.timestampGrain(ofType: "apfs", isLocal: true) == 0)
        #expect(FileIdentity.timestampGrain(ofType: "hfs", isLocal: true) == 1)
        #expect(FileIdentity.timestampGrain(ofType: "msdos", isLocal: true) == 2)
        #expect(FileIdentity.timestampGrain(ofType: "apfs", isLocal: false) == 2)
        #expect(FileIdentity.timestampGrain(of: box.url("not/there/yet.txt")) == 0)
    }

    /// A folder pattern of slashes only is a file name; `*.` takes names without an extension.
    @Test
    internal func patternsOfSlashesAndDots() {
        let filter = CopyFilter("//")
        #expect(filter.admitsFile("//", at: filter.base) && !filter.admitsFile("a", at: filter.base))
        #expect(Wildcard.matches("*.", "README") && !Wildcard.matches("*.", "a.txt"))
    }

    /// A device the registry does not know is not a spinning disk; a volume of no device is not either.
    @Test
    internal func unknownDevicesDoNotSpin() {
        #expect(!StorageMedium.mediumIsRotational(bsdName: "afm-no-such-disk"))
        #expect(!StorageMedium.isRotational(URL(fileURLWithPath: "/dev")))
    }

    /// Settings out of range fall back to the usual ones; the log's rotation and limits are read.
    @Test
    @MainActor
    internal func settingsOutOfRangeFallBack() {
        let settings = MemorySettings()
        settings.set(99, forKey: OperationSettings.overwrite)
        settings.set(99, forKey: OperationSettings.links)
        let options = OperationSettings.options(from: settings)
        #expect(options.overwrite == .ask && options.links == .copyLinks)
        settings.set("  ", forKey: OperationSettings.logFile)
        settings.set(1, forKey: OperationSettings.logRotation)
        settings.set("many", forKey: OperationSettings.logKeepCount)
        var configuration = OperationSettings.logConfiguration(from: settings)
        #expect(configuration.rotation == .daily && configuration.keepCount == 30)
        #expect(configuration.file.path.hasSuffix("Library/Logs/A File Manager/operations.log"))
        settings.set(2, forKey: OperationSettings.logRotation)
        settings.set("big", forKey: OperationSettings.logSizeLimit)
        configuration = OperationSettings.logConfiguration(from: settings)
        #expect(configuration.rotation == .size(1_000 * 1_024))
    }

    /// A switch's value without quotes ends at a blank or a slash.
    @Test
    internal func aSwitchValueWithoutQuotes() {
        #expect(CommandSwitches.parse("W=*.txt /V1") == ["W": "*.txt", "V": "1"])
    }

    /// A pipe has no contents to compare; a read that a flag ends gives no checksum.
    @Test
    internal func pipesAndCancelledReadsGiveNoChecksum() throws {
        let fileSystems = FileSystemRegistry()
        fileSystems.register(LocalFileSystem())
        let pipe = box.url("pipe")
        #expect(mkfifo(pipe.path, 0o600) == 0)
        let file = try box.file("file", "x")
        #expect(throws: FileJobError.self) { try Checksum.sameContents(pipe, file, in: fileSystems) }
        let hooked = CoverageArchivesFSHookedMemory()
        let registry = FileSystemRegistry()
        registry.register(hooked)
        let url = try CoverageArchivesFSHookedMemory.put(Data("contents".utf8), at: "/f", on: hooked.base)
        let flag = CancellationFlag()
        hooked.onNextRead { flag.cancel() }
        #expect(try Checksum.sha256(of: url, in: registry, flags: [flag]) == nil)
    }
}

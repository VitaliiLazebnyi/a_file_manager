import AFMKernel
import Foundation
import TestSupport
import Testing

@testable import DirectorySyncPlugin

/// What Synchronize directories keeps in the settings, when part of it cannot be read.
@MainActor
@Suite
struct CoverageSyncSettings {
    /// A saved set without its options (written by another version) is left out; the others load.
    @Test
    func aDamagedSetLeavesTheOthers() {
        let settings = MemorySettings()
        SettingsJSON.store(
            #"""
            [{"name":"Broken","left":"\/a"},\#
            {"name":"Backup","left":"\/Users\/me\/Documents","right":"\/Volumes\/Backup\/Documents",\#
            "options":{"subdirectories":true,"byContent":false,"ignoreDate":false,"asymmetric":true,\#
            "emptyDirectories":true,"mask":"*.*","toleranceSeconds":3,"timeOffsetHours":0,\#
            "ignoreOneHourDifference":false,"includeHidden":false},"show":63}]
            """#,
            forKey: "directorySync.sets",
            in: settings
        )
        let memory = MemoryFileSystem()
        let bench = TestBench(
            plugins: [],
            fileSystems: [memory],
            left: memory.url("/"),
            right: memory.url("/"),
            settings: settings
        )
        let session = SyncSession(kernel: bench.kernel)
        #expect(session.savedSets.map(\.name) == ["Backup"])
        // Saving keeps the good set and drops the one that could not be read.
        session.leftPath = "/x"
        session.saveSet(named: "New")
        #expect(session.savedSets.map(\.name) == ["Backup", "New"])
    }
}

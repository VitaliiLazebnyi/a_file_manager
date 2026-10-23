import AFMKernel
import Foundation
import LocalFileSystemPlugin
import TestSupport
import Testing

@testable import DirectorySyncPlugin

/// What Synchronize directories remembers, as earlier versions wrote it: the options, the show
/// filter and the saved sets load as they were meant, and are written again in the same shape.
@MainActor
@Suite
internal struct DirectorySyncSettingsMigration {
    /// What earlier versions wrote, one fixture per format.
    internal enum Fixture {
        /// The compare options as commit 16d647d (2026-10-14) wrote them.
        ///
        /// `directorySync.options`: the boxes of the window. Compared by content, the right side
        /// to become a copy of the left, only Swift and Markdown files, dates 2 seconds apart
        /// counting as equal, the right side an hour ahead and one-hour differences ignored.
        /// The names to compare (`onlyNames`) are never stored.
        internal static let options = #"""
            {"subdirectories":true,"byContent":true,"ignoreDate":false,"asymmetric":true,"emptyDirectories":false,\#
            "mask":"*.swift *.md","toleranceSeconds":2,"timeOffsetHours":1,"ignoreOneHourDifference":true,\#
            "includeHidden":false}
            """#

        /// The show filter as commit 16d647d (2026-10-14) wrote it.
        ///
        /// `directorySync.show`: the buttons that are down, as bits: 1 copy to the right,
        /// 2 equal, 4 not equal, 8 copy to the left, 16 duplicates, 32 singles. 45 hides the
        /// equal files and the duplicates.
        internal static let show = "45"

        /// A show filter with both duplicates and singles up, which nothing could ever pass.
        ///
        /// 15: an earlier window let it be stored; both come back down when it is read.
        internal static let showNothing = "15"

        /// The saved sets as commit 16d647d (2026-10-14) wrote them.
        ///
        /// `directorySync.sets`: the two directories as typed, the options and the show filter
        /// under a name. "Backup" mirrors the documents to a disk, showing everything (63).
        internal static let sets = #"""
            [{"name":"Backup","left":"\/Users\/me\/Documents","right":"\/Volumes\/Backup\/Documents",\#
            "options":{"subdirectories":true,"byContent":false,"ignoreDate":false,"asymmetric":true,\#
            "emptyDirectories":true,"mask":"*.*|*.tmp","toleranceSeconds":3,"timeOffsetHours":0,\#
            "ignoreOneHourDifference":false,"includeHidden":false},"show":63}]
            """#
    }

    /// A session of the window on the settings, with two real folders for the panels.
    ///
    /// A session on a bench of its own. The bench is returned with it: it owns the kernel, which
    /// the session needs for as long as it is used.
    private static func session(
        on settings: any SettingsStore,
        in box: Sandbox
    ) throws -> (bench: TestBench, session: SyncSession) {
        let bench = TestBench(
            plugins: [],
            fileSystems: [LocalFileSystem()],
            left: try box.folder("A"),
            right: try box.folder("B"),
            settings: settings
        )
        let session = SyncSession(kernel: bench.kernel)
        session.runsInline = true
        return (bench, session)
    }

    /// The options and the show filter load with every box.
    @Test
    internal func theOptionsLoad() throws {
        let settings = MemorySettings()
        SettingsJSON.store(Fixture.options, forKey: "directorySync.options", in: settings)
        SettingsJSON.store(Fixture.show, forKey: "directorySync.show", in: settings)
        let (bench, session) = try Self.session(on: settings, in: try Sandbox())
        defer {
            withExtendedLifetime(bench) {
                // The bench owns the kernel the session uses, up to here.
            }
        }
        let options = session.options
        #expect(options.subdirectories && options.byContent && !options.ignoreDate && options.asymmetric)
        #expect(!options.emptyDirectories && options.mask == "*.swift *.md" && options.toleranceSeconds == 2)
        #expect(options.timeOffsetHours == 1 && options.ignoreOneHourDifference && !options.includeHidden)
        #expect(options.onlyNames.isEmpty)
        #expect(session.show == [.copyToRight, .notEqual, .copyToLeft, .singles])
    }

    /// A filter that would show nothing has duplicates and singles put down again.
    @Test
    internal func aFilterThatShowsNothingIsMended() throws {
        let settings = MemorySettings()
        SettingsJSON.store(Fixture.showNothing, forKey: "directorySync.show", in: settings)
        let (bench, session) = try Self.session(on: settings, in: try Sandbox())
        defer {
            withExtendedLifetime(bench) {
                // The bench owns the kernel the session uses, up to here.
            }
        }
        #expect(session.show == .all)
    }

    /// A saved set loads with its directories, options and filter.
    @Test
    internal func theSavedSetsLoad() throws {
        let settings = MemorySettings()
        SettingsJSON.store(Fixture.sets, forKey: "directorySync.sets", in: settings)
        let (bench, session) = try Self.session(on: settings, in: try Sandbox())
        defer {
            withExtendedLifetime(bench) {
                // The bench owns the kernel the session uses, up to here.
            }
        }
        #expect(session.savedSets.map(\.name) == ["Backup"])
        #expect(session.loadSet(named: "Backup"))
        #expect(session.leftPath == "/Users/me/Documents" && session.rightPath == "/Volumes/Backup/Documents")
        #expect(session.options.asymmetric && session.options.emptyDirectories && session.options.mask == "*.*|*.tmp")
        #expect(!session.options.byContent && session.options.toleranceSeconds == 3 && session.show == .all)
    }

    /// Comparing stores the options and the filter, and saving a set under its own name
    /// replaces it, all in the shape they were read in.
    @Test
    internal func everythingIsSavedInTheSameShape() throws {
        let settings = MemorySettings()
        SettingsJSON.store(Fixture.options, forKey: "directorySync.options", in: settings)
        SettingsJSON.store(Fixture.show, forKey: "directorySync.show", in: settings)
        SettingsJSON.store(Fixture.sets, forKey: "directorySync.sets", in: settings)
        let box = try Sandbox()
        let (bench, session) = try Self.session(on: settings, in: box)
        defer {
            withExtendedLifetime(bench) {
                // The bench owns the kernel the session uses, up to here.
            }
        }
        session.leftPath = box.url("A").path
        session.rightPath = box.url("B").path
        session.compare()
        #expect(SettingsJSON.matches(settings.data(forKey: "directorySync.options"), Fixture.options))
        #expect(SettingsJSON.matches(settings.data(forKey: "directorySync.show"), Fixture.show))
        #expect(session.loadSet(named: "Backup"))
        session.saveSet(named: "Backup")
        #expect(SettingsJSON.matches(settings.data(forKey: "directorySync.sets"), Fixture.sets))
    }
}

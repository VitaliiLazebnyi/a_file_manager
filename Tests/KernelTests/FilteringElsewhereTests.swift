import Foundation
import TestSupport
import Testing

@testable import AFMKernel

/// A filter worked out on another thread and applied on the main thread, as a panel does with
/// long lists.
@MainActor
@Suite
internal struct FilteringElsewhereTests {
    private let directory = URL(fileURLWithPath: "/work", isDirectory: true)

    /// The list filtered on another thread is the list `setFilter` shows: marks, cursor, totals
    /// and the version of the list included; taking the filter off works the same way.
    @Test(arguments: [300, 40_000])
    internal func aListFilteredElsewhereIsWhatSetFilterShows(count: Int) throws {
        let filter = PanelFilter(title: "3") { $0.isFolder || $0.name.contains("3") }
        let all = items(count)
        let (direct, handed) = (Fixture.panel(all, at: directory), Fixture.panel(all, at: directory))
        for model in [direct, handed] {
            model.setSelected(true, names: ["file3.txt", "file5.txt", "dir7", "file13.txt"])
            model.moveCursor(to: try #require(model.row(ofName: "file23.txt")))
        }
        #expect(PanelModel.filtered(all, by: nil).count == count)
        let version = handed.listVersion
        var announced = 0
        handed.onChange = { change in announced += change == .contents ? 1 : 0 }
        // Worked out on another thread, as a panel does it, and applied here.
        let listed = handed.listedItems
        let shown = try #require(OtherThread.result { PanelModel.filtered(listed, by: filter) })
        #expect(handed.setFilter(filter, prefiltered: shown, listVersion: version))
        direct.setFilter(filter)
        // A filter is not another list: the version of the list stays.
        #expect(PanelFigures.state(direct) == PanelFigures.state(handed))
        #expect(announced == 1)
        #expect(handed.listVersion == version)
        #expect(handed.selection == ["file3.txt", "dir7", "file13.txt"])
        #expect(handed.cursorItem?.name == "file23.txt")
        // Taking the filter off again, the same way.
        let off = handed.listVersion
        #expect(
            handed.setFilter(nil, prefiltered: PanelModel.filtered(handed.listedItems, by: nil), listVersion: off)
        )
        direct.setFilter(nil)
        #expect(PanelFigures.state(direct) == PanelFigures.state(handed))
        #expect(handed.items.count == count)
    }

    /// A filtered list that was worked out for a list read before the latest reading is refused,
    /// and the filter is then applied here.
    @Test
    internal func aListThatChangedMeanwhileIsFilteredHere() {
        let filter = PanelFilter(title: "1") { $0.name.contains("1") }
        let all = items(200)
        let (direct, handed) = (Fixture.panel(all, at: directory), Fixture.panel(all, at: directory))
        let version = handed.listVersion
        let stale = PanelModel.filtered(handed.listedItems, by: filter)
        // The directory was read again before the filtered list came back.
        let fresh = Fixture.listing(Array(all.dropFirst(20)), at: directory)
        handed.update(with: fresh)
        direct.update(with: fresh)
        #expect(!handed.setFilter(filter, prefiltered: stale, listVersion: version))
        direct.setFilter(filter)
        #expect(PanelFigures.state(direct) == PanelFigures.state(handed))
        #expect(handed.items.count < stale.count)
    }

    /// Free and total space are announced when they change, not when the same figure comes again.
    @Test
    internal func aNewVolumeFigureIsAnnounced() {
        let model = Fixture.panel(items(3), at: directory)
        var changes = 0
        model.onChange = { _ in changes += 1 }
        model.setVolume(VolumeInfo(name: "Disk", freeBytes: 10, totalBytes: 20))
        model.setVolume(VolumeInfo(name: "Disk", freeBytes: 10, totalBytes: 20))
        #expect(changes == 1)
        #expect(model.volume?.freeBytes == 10)
    }

    /// `count` entries in `/work`: every seventh a folder `dir<n>`, the others files `file<n>.txt` of n bytes.
    private func items(_ count: Int) -> [FileItem] {
        (0..<count)
            .map { index in
                let isFolder = index.isMultiple(of: 7)
                return FileItem(
                    url: directory.appending(name: "n\(index)"),
                    name: isFolder ? "dir\(index)" : "file\(index).txt",
                    kind: .init(isDirectory: isFolder),
                    stat: .init(size: Int64(index))
                )
            }
    }
}

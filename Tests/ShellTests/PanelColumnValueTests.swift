import AFMKernel
import Foundation
import TestSupport
import Testing

@testable import AFMShell

/// The values of plugin columns (spec 03 › Custom columns): computed in the background on
/// several cores, the rows asked for last first, and forgotten with the folder.
@MainActor
@Suite(.serialized)
internal struct PanelColumnValueTests {
    /// The URL `text` writes.
    private func url(_ text: String) throws -> URL {
        try #require(URL(string: text))
    }

    /// An entry of `size` bytes at `/x`.
    private func item(_ name: String, size: Int64) -> FileItem {
        FileItem(url: URL(fileURLWithPath: "/x/" + name), name: name, stat: .init(size: size))
    }

    /// Whether the store computes or has requests waiting.
    private func isBusy(_ store: ColumnValueStore) -> Bool {
        !store.working.isEmpty || store.hasWaiting
    }

    /// Asking returns at once with nothing, and nothing is computed on the main thread; the
    /// values arrive, and the calls of a batch run on several cores at the same time.
    @Test
    internal func columnValuesAreComputedInTheBackgroundOnSeveralCores() async {
        let probe = PanelProbe()
        // The first request goes out alone, in a batch of its own (nothing else waits when it is
        // made); the batch after it holds many, and its first call waits for a second one beside it.
        if ProcessInfo.processInfo.activeProcessorCount > 1 {
            probe.waitForCompany(atCall: 2)
        }
        let column = ContentColumn(id: "probe", title: "Probe") { item in
            probe.enter(item.name)
            probe.leave()
            return "v:" + item.name
        }
        let store = ColumnValueStore()
        var arrived: Set<String> = []
        store.onArrival = { arrived.formUnion($0) }
        let items = (0..<300).map { item("f\($0)", size: 1) }
        #expect(items.allSatisfy { store.text(of: column, for: $0) == nil })
        #expect(isBusy(store))
        #expect(await PanelWait.until { !isBusy(store) })
        #expect(arrived.count == 300 && items.allSatisfy { store.text(of: column, for: $0) == "v:" + $0.name })
        #expect(probe.callCount == 300 && probe.callsOnMain == 0)
        #expect(probe.mostCallsAtOnce > 1 || ProcessInfo.processInfo.activeProcessorCount == 1)
    }

    /// Of what waits, the end of the line (the rows scrolled to last) comes first.
    @Test
    internal func theRowsAskedForLastAreComputedFirst() async {
        let probe = PanelProbe()
        let column = ContentColumn(id: "order", title: "Order") { item in
            probe.enter(item.name)
            probe.leave()
            return item.name
        }
        let store = ColumnValueStore()
        let count = ColumnValueStore.batchSize * 3
        for index in 0..<count {
            _ = store.text(of: column, for: item(String(format: "f%04d", index), size: 1))
        }
        #expect(await PanelWait.until { !isBusy(store) })
        // The first batch started with the first request, when nothing else was waiting.
        let second = Set(probe.noted[1...ColumnValueStore.batchSize])
        #expect(second.contains(String(format: "f%04d", count - 1)) && !second.contains("f0001"))
        #expect(probe.noted.count == count)
    }

    /// Another folder forgets the values, a value that arrives for a folder that was left is
    /// dropped, and a changed file gets a new value.
    @Test
    internal func anotherFolderForgetsTheValuesAndAChangedFileGetsANewOne() async {
        let probe = PanelProbe()
        let column = ContentColumn(id: "c", title: "C") { item in
            probe.enter(item.name)
            probe.leave()
            return "\(item.size)"
        }
        let store = ColumnValueStore()
        var arrivals = 0
        store.onArrival = { _ in arrivals += 1 }
        _ = store.text(of: column, for: item("a", size: 1))
        #expect(await PanelWait.until { !isBusy(store) })
        #expect(store.text(of: column, for: item("a", size: 1)) == "1" && arrivals == 1)
        // The same name with another size is another value.
        #expect(store.text(of: column, for: item("a", size: 2)) == nil)
        #expect(await PanelWait.until { !isBusy(store) })
        #expect(store.text(of: column, for: item("a", size: 2)) == "2")
        // A value that arrives for a folder that was left is dropped; one that had not been
        // started on when the folder was left is not worked out at all.
        _ = store.text(of: column, for: item("b", size: 5))
        store.reset(folder: nil)
        #expect(await PanelWait.until { !isBusy(store) })
        let callsForTheFolderLeft = probe.callCount
        #expect(arrivals == 2 && (2...3).contains(callsForTheFolderLeft))
        #expect(store.text(of: column, for: item("b", size: 5)) == nil)
        #expect(await PanelWait.until { !isBusy(store) })
        #expect(store.text(of: column, for: item("b", size: 5)) == "5" && probe.callCount == callsForTheFolderLeft + 1)
    }

    /// Rows that went out of sight are not computed any more; one that comes back is asked again.
    @Test
    internal func rowsThatWentOutOfSightAreNotComputedAnyMore() async {
        let probe = PanelProbe()
        let column = ContentColumn(id: "slow", title: "Slow") { item in
            probe.enter(item.name)
            Thread.sleep(forTimeInterval: 0.005)
            probe.leave()
            return item.name
        }
        let store = ColumnValueStore()
        store.dropWaiting(except: [])
        let count = ColumnValueStore.batchSize * 4
        let items = (0..<count).map { item(String(format: "f%04d", $0), size: 1) }
        for one in items {
            _ = store.text(of: column, for: one)
        }
        // The panel scrolled: only the rows on screen now are wanted.
        #expect(store.hasWaiting)
        store.dropWaiting(except: Set(items.suffix(3).map(\.name)))
        #expect(await PanelWait.until { !isBusy(store) })
        #expect(probe.callCount < count && items.suffix(3).allSatisfy { store.text(of: column, for: $0) != nil })
        // A row that comes back into sight is asked for again, and arrives.
        #expect(store.text(of: column, for: items[count / 2]) == nil || probe.callCount >= count / 2)
        #expect(await PanelWait.until { !isBusy(store) })
        #expect(store.text(of: column, for: items[count / 2]) == items[count / 2].name)
    }

    /// A column that reads its file is told through its flag when the panel has left the folder.
    @Test
    internal func aColumnIsToldWhenThePanelHasLeftTheFolder() async throws {
        let flags = Shared<[CancellationFlag]>([])
        let gate = DispatchSemaphore(value: 0)
        let column = ContentColumn(id: "slow", title: "Slow") { item, flag in
            flags.modify { $0.append(flag) }
            gate.wait()
            return item.name
        }
        let store = ColumnValueStore()
        store.reset(folder: try url("cols://host/a"))
        _ = store.text(of: column, for: FileItem(url: try url("cols://host/a/x"), name: "x"))
        #expect(await PanelWait.until { !flags.value.isEmpty })
        #expect(flags.value.count == 1 && flags.value.first?.isCancelled == false)
        store.reset(folder: try url("cols://host/b"))
        #expect(flags.value.first?.isCancelled == true)
        gate.signal()
        #expect(await PanelWait.until { !isBusy(store) })
    }
}

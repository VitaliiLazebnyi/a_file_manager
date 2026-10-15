import AFMKernel
import AppKit
import TestSupport
import Testing

@testable import AFMShell

/// The own icons of local files: fetched in the background, kept in a store that forgets what
/// was not used for a while and never everything at once.
@MainActor
@Suite(.serialized)
internal struct PanelIconTests {
    /// Icons are fetched off the main thread, posted when they arrive, kept, and fetched again for
    /// a file that changed.
    @Test
    internal func ownIconsAreFetchedInTheBackgroundAndKept() async {
        let store = IconStore()
        let asked = Shared<[String]>([])
        let image = NSImage(size: NSSize(width: 16, height: 16))
        store.source = { path in
            asked.modify { $0.append("\(path) on main: \(Thread.isMainThread)") }
            return image
        }
        let arrived = Shared<Set<String>>([])
        let observer = NotificationCenter.default.addObserver(forName: IconStore.didArrive, object: store, queue: nil) {
            note in
            arrived.modify { $0.formUnion(note.userInfo?[IconStore.pathsKey] as? Set<String> ?? []) }
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        let date = Date(timeIntervalSince1970: 5)
        // Not there yet: the caller shows the icon of the type, and nothing was asked on this thread.
        #expect(store.icon(forPath: "/icons/a.app", modified: date) == nil)
        #expect(store.icon(forPath: "/icons/a.app", modified: date) == nil)
        #expect(await PanelWait.until { arrived.value == ["/icons/a.app"] })
        #expect(asked.value == ["/icons/a.app on main: false"])
        #expect(store.icon(forPath: "/icons/a.app", modified: date) === image && asked.value.count == 1)
        // A changed file is asked again.
        #expect(store.icon(forPath: "/icons/a.app", modified: Date(timeIntervalSince1970: 6)) == nil)
        #expect(await PanelWait.until { asked.value.count == 2 })
    }

    /// Of very many icons asked for in one folder, those asked for longest ago are dropped; the
    /// rest come in trips of a batch each.
    @Test
    internal func aLongLineOfIconsKeepsTheNewestAndComesInBatches() async {
        let store = IconStore()
        let gate = DispatchSemaphore(value: 0)
        let asked = Shared<[String]>([])
        store.source = { path in
            if path == "/many/first" {
                gate.wait()
            }
            asked.modify { $0.append(path) }
            return NSImage(size: NSSize(width: 16, height: 16))
        }
        _ = store.icon(forPath: "/many/first", modified: .distantPast)
        let count = IconStore.waitingLimit + 10
        for index in 0..<count {
            _ = store.icon(forPath: "/many/f\(index)", modified: .distantPast)
        }
        gate.signal()
        #expect(await PanelWait.until { asked.value.count == 1 + IconStore.waitingLimit })
        await PanelWait.pause(0.1)
        #expect(asked.value.count == 1 + IconStore.waitingLimit && !asked.value.contains("/many/f0"))
        #expect(asked.value[1] == "/many/f\(count - 1)")
    }

    /// The store keeps at most its limit and carries what is in use over to the newer generation.
    @Test
    internal func aFullStoreLosesWhatWasNotUsedAndNeverEverything() {
        var cache = TwoGenerationCache<Int, String>(limit: 10)
        for number in 0..<100 {
            cache[number] = "v\(number)"
            // One entry is asked for all the time, like the icons on screen.
            #expect(cache[0] == "v0")
            #expect(cache.recent.count + cache.older.count <= 10)
        }
        #expect(cache[99] == "v99" && cache[50] == nil)
        cache[99] = nil
        #expect(cache[99] == nil && TwoGenerationCache<Int, Int>(limit: 0).limit == 2)
    }

    /// A file of a local disk shows its own icon once it has been fetched; elsewhere, and until
    /// then, the icon of its type.
    @Test
    internal func aLocalFileShowsItsOwnIconOnceFetched() async throws {
        let box = try Sandbox()
        let url = try box.file("own.txt")
        let item = FileItem(url: url, name: "own.txt")
        let typeIcon = FileListColumn.icon(for: item, own: false)
        #expect(FileListColumn.icon(for: item, own: false) === typeIcon)
        _ = FileListColumn.icon(for: item, own: true)
        #expect(await PanelWait.until { IconStore.shared.icon(forPath: url.path, modified: item.modified) != nil })
        #expect(FileListColumn.icon(for: item, own: true) !== typeIcon)
        let folder = FileItem(url: box.root, name: "box", kind: .directory)
        #expect(FileListColumn.icon(for: folder, own: false) === FileListColumn.icon(for: folder, own: false))
    }
}

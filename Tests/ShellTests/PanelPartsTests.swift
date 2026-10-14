import AFMContracts
import AFMKernel
@testable import AFMShell
import AppKit
import TestSupport
import Testing

/// The parts of the file panel that can be checked without a window: where the cells of the
/// Brief and Thumbnails views are, finding by typing, the quick filter's matching, colours,
/// the path bar's parts, tab dragging, and the rules of drag and drop.
@Suite struct PanelParts {
    func item(_ name: String, folder: Bool = false, size: Int64 = 0) -> FileItem {
        FileItem(url: URL(fileURLWithPath: "/x/" + name), name: name, isDirectory: folder, size: size)
    }

    // MARK: Grid

    @Test func briefFillsColumnsFromTopToBottom() {
        let grid = GridGeometry(flow: .columns, count: 23, cell: CGSize(width: 100, height: 20), viewport: CGSize(width: 250, height: 105))
        #expect(grid.perLine == 5 && grid.lines == 5)
        #expect(grid.contentSize == CGSize(width: 500, height: 105))
        #expect(grid.frame(of: 0) == CGRect(x: 0, y: 0, width: 100, height: 20))
        #expect(grid.frame(of: 7) == CGRect(x: 100, y: 40, width: 100, height: 20))
        #expect(grid.index(at: CGPoint(x: 150, y: 45)) == 7)
        // Below the last full row of a column, and behind the last entry, is empty space.
        #expect(grid.index(at: CGPoint(x: 150, y: 102)) == nil && grid.index(at: CGPoint(x: 450, y: 70)) == nil)
        #expect(grid.index(at: CGPoint(x: 450, y: 45)) == 22)
        #expect(grid.indexes(in: CGRect(x: 120, y: 0, width: 100, height: 105)) == 5..<15)
        #expect(grid.indexes(in: CGRect(x: 420, y: 0, width: 500, height: 105)) == 20..<23)
        #expect(grid.pageSize == 9)
    }

    @Test func arrowKeysInBrief() {
        let grid = GridGeometry(flow: .columns, count: 23, cell: CGSize(width: 100, height: 20), viewport: CGSize(width: 250, height: 100))
        #expect(grid.index(from: 7, moving: .down) == 8 && grid.index(from: 7, moving: .up) == 6)
        #expect(grid.index(from: 7, moving: .right) == 12 && grid.index(from: 7, moving: .left) == 2)
        // ← in the first column and → in the last go to the first and the last entry.
        #expect(grid.index(from: 3, moving: .left) == 0 && grid.index(from: 19, moving: .right) == 22)
        #expect(grid.index(from: 22, moving: .down) == 22 && grid.index(from: 0, moving: .up) == 0)
    }

    @Test func thumbnailsFillRowsAndScrollVertically() {
        let grid = GridGeometry(flow: .rows, count: 10, cell: CGSize(width: 100, height: 120), viewport: CGSize(width: 450, height: 200))
        #expect(grid.perLine == 4 && grid.lines == 3 && grid.contentSize == CGSize(width: 450, height: 360))
        #expect(grid.frame(of: 5) == CGRect(x: 100, y: 120, width: 100, height: 120))
        #expect(grid.index(at: CGPoint(x: 150, y: 130)) == 5 && grid.index(at: CGPoint(x: 420, y: 10)) == nil)
        #expect(grid.index(at: CGPoint(x: 250, y: 250)) == nil)
        #expect(grid.indexes(in: CGRect(x: 0, y: 100, width: 450, height: 50)) == 0..<8)
        #expect(grid.index(from: 5, moving: .right) == 6 && grid.index(from: 5, moving: .up) == 1 && grid.index(from: 5, moving: .down) == 9)
        // No tile straight below in the shorter last row: the last tile; none above the first row: stay.
        #expect(grid.index(from: 7, moving: .down) == 9 && grid.index(from: 9, moving: .down) == 9 && grid.index(from: 2, moving: .up) == 2)
        #expect(grid.pageSize == 4)
    }

    @Test func anEmptyOrTinyGridDoesNotBreak() {
        let empty = GridGeometry(flow: .columns, count: 0, cell: CGSize(width: 100, height: 20), viewport: .zero)
        #expect(empty.perLine == 1 && empty.lines == 0 && empty.indexes(in: CGRect(x: 0, y: 0, width: 50, height: 50)).isEmpty)
        #expect(empty.index(from: 0, moving: .right) == 0 && empty.index(at: .zero) == nil && empty.pageSize == 1)
    }

    @Test func aBriefColumnIsAsWideAsTheLongestNameUpToTheLimit() {
        let short = [item("a.txt"), item("bb.txt")]
        let long = short + [item(String(repeating: "w", count: 120) + ".txt")]
        let narrow = FileGridView.briefColumnWidth(for: short, limit: 200, viewport: 600)
        #expect(narrow == 80)
        #expect(FileGridView.briefColumnWidth(for: long, limit: 200, viewport: 600) == 200)
        // Without a limit the panel's width is the limit.
        #expect(FileGridView.briefColumnWidth(for: long, limit: nil, viewport: 600) == 600)
        let medium = FileGridView.briefColumnWidth(for: short + [item("a-name-of-middling-length.txt")], limit: 400, viewport: 600)
        #expect(medium > 150 && medium < 300)
        #expect(FileGridView.briefColumnWidth(for: [], limit: 200, viewport: 600) == 80)
    }

    // MARK: Finding by typing

    @Test func typingFindsTheNextNameWithThatStart() {
        let names = ["alpha", "beta", "Bravo", "report_01", "report_02"]
        #expect(TypeSelect.row(matching: "b", in: names, from: 0) == 1)
        // The same letter again moves on; a longer prefix may stay where it is.
        #expect(TypeSelect.row(matching: "b", in: names, from: 1) == 2 && TypeSelect.row(matching: "b", in: names, from: 2) == 1)
        #expect(TypeSelect.row(matching: "rep", in: names, from: 3) == 3 && TypeSelect.row(matching: "report_02", in: names, from: 3) == 4)
        #expect(TypeSelect.row(matching: "x", in: names, from: 0) == nil && TypeSelect.row(matching: "a", in: [], from: 0) == nil)
        // From the `[..]` row, which is before the first name.
        #expect(TypeSelect.row(matching: "a", in: names, from: -1) == 0)
    }

    @Test func whatWasTypedIsForgottenAfterAPause() {
        var typing = TypeSelect()
        #expect(typing.add("r", at: 10) == "r" && typing.add("e", at: 10.4) == "re")
        #expect(typing.add("n", at: 12) == "n")
    }

    // MARK: Quick filter

    @Test func theQuickFilterMatchesPartsOfNamesOrMasks() {
        let part = QuickFilter.matcher(for: "Port")
        #expect(part("report.txt") && part("PORTS") && !part("notes.txt"))
        let mask = QuickFilter.matcher(for: "*.TXT")
        #expect(mask("a.txt") && !mask("a.txt.bak"))
        let single = QuickFilter.matcher(for: "r?p*")
        #expect(single("report") && !single("grep"))
    }

    @Test func theQuickFilterOfPlainTextAgreesWithFoundationForEveryKindOfName() {
        let names = ["report.txt", "REPORT.TXT", "Übung.txt", "ÜBUNG", "naïve cafe", "café", "K.txt", "\u{212A}elvin", "日本語.md", "a", "", "ab", "tx"]
        for text in ["Port", "t", "txt", "ung", "ÜB", "café", "k", "日本", "xt", "ab", "TX"] {
            let matches = QuickFilter.matcher(for: text)
            for name in names {
                #expect(matches(name) == (name.range(of: text.lowercased(), options: .caseInsensitive) != nil), "\(text) in \(name)")
            }
        }
    }

    @Test func onlyTextTypedOnIsTakenToNarrowTheList() {
        #expect(QuickFilter.narrows(from: "re", to: "rep") && QuickFilter.narrows(from: "re", to: "xre") && QuickFilter.narrows(from: "Re", to: "rEp"))
        // Fewer letters, other letters, a mask, or no text before: the whole list is filtered again.
        #expect(!QuickFilter.narrows(from: "rep", to: "re") && !QuickFilter.narrows(from: "re", to: "ro") && !QuickFilter.narrows(from: "", to: "a"))
        #expect(!QuickFilter.narrows(from: "re", to: "re*") && !QuickFilter.narrows(from: "r?", to: "r?a") && !QuickFilter.narrows(from: "*", to: "*a"))
        #expect(!QuickFilter.narrows(from: "ü", to: "üb") && !QuickFilter.narrows(from: "u", to: "uü"))
        // The narrowed list is the one the full filter gives, over the names that make a trap of "contains".
        let names = ["report.txt", "Reprint", "bare", "a.rep", "REP", "", "r", "xrex", "Übung", "ré"]
        for (old, new) in [("r", "re"), ("re", "rep"), ("e", "re"), ("p", "rep")] {
            let before = names.filter(QuickFilter.matcher(for: old))
            #expect(QuickFilter.narrows(from: old, to: new))
            #expect(before.filter(QuickFilter.matcher(for: new)) == names.filter(QuickFilter.matcher(for: new)))
        }
    }

    @Test func theQuickFilterLiesOverTheDisplayFilter() {
        let base = PanelFilter.mask("*.txt")
        var filter = QuickFilter(text: "", base: base, directory: URL(fileURLWithPath: "/x"))
        #expect(filter.combined?.title == "*.txt" && filter.title == "*.txt")
        filter.text = "re"
        #expect(filter.title.hasPrefix("*.txt") && filter.title.hasSuffix("re"))
        let combined = filter.combined!
        #expect(combined.matches(item("report.txt")) && !combined.matches(item("report.pdf")) && !combined.matches(item("notes.txt")))
        // Folders are filtered by name too; the display filter below lets them all through.
        #expect(combined.matches(item("recent", folder: true)) && !combined.matches(item("docs", folder: true)))
        #expect(QuickFilter(text: "", base: nil, directory: URL(fileURLWithPath: "/x")).combined == nil)
    }

    @Test func findingByTypingCanLookAtAListWithoutCopyingItsNames() {
        let names = ["alpha", "Beta", "bravo", "charlie"]
        #expect(TypeSelect.row(matching: "b", count: names.count, from: 0) { names[$0] } == 1)
        #expect(TypeSelect.row(matching: "b", count: names.count, from: 1) { names[$0] } == 2)
        #expect(TypeSelect.row(matching: "br", count: names.count, from: 1) { names[$0] } == 2)
        #expect(TypeSelect.row(matching: "z", count: names.count, from: 1) { names[$0] } == nil)
        #expect(TypeSelect.row(matching: "b", count: 0, from: 0) { _ in "" } == nil)
    }

    @MainActor @Test func theTabStripIsChangedInPlaceWhileTheNumberOfTabsStays() {
        let bar = TabBarView()
        bar.update(titles: ["a", "b"], paths: ["/a", "/b"], active: 0)
        let stack = bar.subviews.compactMap { $0 as? NSStackView }.first
        let before = stack?.arrangedSubviews ?? []
        bar.update(titles: ["a", "c"], paths: ["/a", "/c"], active: 1)
        #expect(before.count == 2 && stack?.arrangedSubviews.elementsEqual(before, by: ===) == true)
        #expect(bar.titles == ["a", "c"] && (before[1] as? NSButton)?.state == .on && (before[0] as? NSButton)?.state == .off)
        // Another number of tabs builds the strip anew.
        bar.update(titles: ["a", "c", "d"], paths: ["/a", "/c", "/d"], active: 1)
        #expect(bar.titles == ["a", "c", "d"] && bar.isHidden == false)
        bar.update(titles: ["a"], paths: ["/a"], active: 0)
        #expect(bar.isHidden)
    }

    @Test func aDragIsLookedAtOnceAndNotAtEveryMoveOfTheMouse() {
        let sources = (0..<1000).map { URL(fileURLWithPath: "/x/f\($0).txt") }
        let session = DropSession(sequence: 7, sources: sources)
        let (inside, elsewhere) = (URL(fileURLWithPath: "/x"), URL(fileURLWithPath: "/y"))
        #expect(session.isPointless(.move, into: inside) && !session.isPointless(.copy, into: inside) && !session.isPointless(.move, into: elsewhere))
        #expect(session.isPointless(.move, into: inside) && session.mountPoints.contains("/") && session.mountPoints == session.mountPoints)
        #expect(DropSession(sequence: 8, sources: []).isPointless(.copy, into: elsewhere))
    }

    // MARK: Colours

    @Test func colourEntriesAreReadFromText() {
        let rules = ColorRule.parse("*.zip *.gz = purple\n-.tmp = red\nnonsense\n*.swift=#FF8000;;*.md = nocolour;;* = gray")
        #expect(rules.map(\.maskText) == ["*.zip *.gz", "*.swift", "*"])
        #expect(ColorRule.color(for: "a.GZ", in: rules) == .systemPurple)
        #expect(ColorRule.color(for: "a.swift", in: rules) == NSColor(srgbRed: 1, green: CGFloat(0x80) / 255, blue: 0, alpha: 1))
        // The first entry that matches decides.
        #expect(ColorRule.color(for: "a.txt", in: rules) == .systemGray && ColorRule.color(for: "a.txt", in: Array(rules.prefix(2))) == nil)
        #expect(ColorRule.color(named: "#12345") == nil && ColorRule.color(named: " Red ") == .systemRed)
        #expect(!ColorRule.parse(PanelSettings.defaultColorRules).isEmpty)
    }

    @Test func theOptionsOfTheListsComeFromTheSettings() {
        let store = MemorySettings()
        var settings = PanelSettings(from: store)
        #expect(settings.briefWidthLimit == 200 && settings.thumbnailSide == 96 && settings.confirmsDrops && settings.colorRules.isEmpty)
        store.set(false, forKey: PanelSettings.limitsBriefWidthKey)
        store.set(3, forKey: PanelSettings.thumbnailSizeKey)
        store.set(false, forKey: PanelSettings.confirmsDropsKey)
        store.set(true, forKey: PanelSettings.colorsByTypeKey)
        settings = PanelSettings(from: store)
        #expect(settings.briefWidthLimit == nil && settings.thumbnailSide == 192 && !settings.confirmsDrops && settings.colorRules.count == 2)
        store.set(99, forKey: PanelSettings.thumbnailSizeKey)
        #expect(PanelSettings(from: store).thumbnailSide == 256)
        #expect(PanelSettings.page(onChange: {}).preferences.count == 6)
    }

    // MARK: Path bar and tabs

    @Test func thePathIsCutIntoItsFolders() {
        func ancestors(_ paths: [String]) -> [(location: URL, path: String)] { paths.map { (URL(fileURLWithPath: $0), $0) } }
        let segments = PathBarView.segments(of: "/Users/me/docs", ancestors: ancestors(["/", "/Users", "/Users/me", "/Users/me/docs"]))
        #expect(segments.map(\.range) == [NSRange(location: 0, length: 1), NSRange(location: 1, length: 5), NSRange(location: 7, length: 2),
                                         NSRange(location: 10, length: 4)])
        #expect(segments.map(\.location.path) == ["/", "/Users", "/Users/me", "/Users/me/docs"])
        // A file system with a notation of its own, whose writings do not build on each other.
        #expect(PathBarView.segments(of: "archive: sub", ancestors: ancestors(["/a.zip", "/a.zip/sub"])).isEmpty)
        let memory = PathBarView.segments(of: "mem:/A/b", ancestors: [(URL(string: "mem:///")!, "mem:/"), (URL(string: "mem:///A")!, "mem:/A"),
                                                                    (URL(string: "mem:///A/b")!, "mem:/A/b")])
        #expect(memory.map(\.range) == [NSRange(location: 0, length: 5), NSRange(location: 5, length: 1), NSRange(location: 7, length: 1)])
    }

    @MainActor @Test func aClickOnAPartOfThePathGoesThere() {
        let bar = PathBarView(frame: NSRect(x: 0, y: 0, width: 400, height: 22))
        var visited: [String] = [], clicks: [Int] = []
        bar.onNavigate = { visited.append($0.path) }
        bar.onClick = { clicks.append($0) }
        let paths = ["/", "/Users", "/Users/me"]
        bar.update(text: "/Users/me/*.*", segments: PathBarView.segments(of: "/Users/me", ancestors: paths.map { (URL(fileURLWithPath: $0), $0) }))
        bar.click(at: bar.center(ofSegment: 1), count: 1)
        #expect(visited == ["/Users"] && clicks.isEmpty)
        // The folder that is shown, and the space behind the text, are the bar itself.
        bar.click(at: bar.center(ofSegment: 2), count: 2)
        bar.click(at: NSPoint(x: 390, y: 10), count: 1)
        #expect(visited == ["/Users"] && clicks == [2, 1])
        // The second click of a double click on a part does not go there twice.
        bar.click(at: bar.center(ofSegment: 0), count: 1)
        bar.click(at: bar.center(ofSegment: 0), count: 2)
        #expect(visited == ["/Users", "/"])
    }

    @Test func aDraggedTabLandsWhereItsNeighboursMiddleWasPassed() {
        let frames = (0..<4).map { NSRect(x: CGFloat($0) * 100, y: 0, width: 100, height: 20) }
        #expect(TabBarView.destination(forX: 120, dragging: 1, frames: frames) == 1)
        #expect(TabBarView.destination(forX: 260, dragging: 1, frames: frames) == 2)
        #expect(TabBarView.destination(forX: 240, dragging: 1, frames: frames) == 1)
        #expect(TabBarView.destination(forX: 900, dragging: 1, frames: frames) == 3)
        #expect(TabBarView.destination(forX: 40, dragging: 3, frames: frames) == 0)
        #expect(TabBarView.destination(forX: 160, dragging: 3, frames: frames) == 2)
        #expect(TabBarView.destination(forX: 10, dragging: 9, frames: frames) == 9)
    }

    // MARK: Drag and drop

    @Test func aDropCopiesBetweenVolumesAndMovesWithinOne() {
        let all: NSDragOperation = [.copy, .move, .generic, .link]
        #expect(PanelDrop.kind(modifiers: [], sameVolume: true, allowed: all) == .move)
        #expect(PanelDrop.kind(modifiers: [], sameVolume: false, allowed: all) == .copy)
        #expect(PanelDrop.kind(modifiers: .option, sameVolume: true, allowed: all) == .copy)
        #expect(PanelDrop.kind(modifiers: .command, sameVolume: false, allowed: all) == .move)
        // What the source does not allow is not done: a copy instead of a move, never the reverse on request.
        #expect(PanelDrop.kind(modifiers: [], sameVolume: true, allowed: .copy) == .copy)
        #expect(PanelDrop.kind(modifiers: .command, sameVolume: true, allowed: .copy) == nil)
        #expect(PanelDrop.kind(modifiers: .option, sameVolume: false, allowed: .generic) == nil)
        #expect(PanelDrop.kind(modifiers: [], sameVolume: false, allowed: .generic) == .move)
        #expect(PanelDrop.kind(modifiers: [], sameVolume: false, allowed: []) == nil)
    }

    @Test func pointlessDropsAreRefused() {
        let a = URL(fileURLWithPath: "/x/a"), file = URL(fileURLWithPath: "/x/a/f.txt")
        #expect(PanelDrop.isPointless(.copy, [], into: a))
        #expect(PanelDrop.isPointless(.move, [file], into: a) && !PanelDrop.isPointless(.copy, [file], into: a))
        // A folder into itself or into one of its subfolders.
        #expect(PanelDrop.isPointless(.copy, [a], into: a) && PanelDrop.isPointless(.move, [a], into: URL(fileURLWithPath: "/x/a/sub/deep")))
        #expect(!PanelDrop.isPointless(.move, [file], into: URL(fileURLWithPath: "/x/b")))
        #expect(!PanelDrop.isPointless(.move, [URL(fileURLWithPath: "/x/ab")], into: URL(fileURLWithPath: "/x/a")))
    }

    @Test func volumesAreToldApartByTheirMountPoints() {
        let mounts = ["/", "/Volumes/Stick", "/Volumes/Stick 2", "/System/Volumes/Data"]
        #expect(PanelDrop.mountPoint(of: "/Volumes/Stick/a/b", among: mounts) == "/Volumes/Stick")
        #expect(PanelDrop.mountPoint(of: "/Volumes/Stick 2/a", among: mounts) == "/Volumes/Stick 2")
        #expect(PanelDrop.mountPoint(of: "/Volumes/Sticky/a", among: mounts) == "/" && PanelDrop.mountPoint(of: "/Users/me", among: mounts) == "/")
        func file(_ path: String) -> URL { URL(fileURLWithPath: path) }
        #expect(PanelDrop.areOnSameVolume(file("/Users/a"), file("/tmp/b"), mountPoints: mounts))
        #expect(!PanelDrop.areOnSameVolume(file("/Users/a"), file("/Volumes/Stick/b"), mountPoints: mounts))
        #expect(PanelDrop.areOnSameVolume(URL(string: "ftp://host/a")!, URL(string: "ftp://host/b/c")!, mountPoints: mounts))
        #expect(!PanelDrop.areOnSameVolume(URL(string: "ftp://host/a")!, URL(string: "ftp://other/a")!, mountPoints: mounts))
        #expect(!PanelDrop.areOnSameVolume(URL(string: "mem:///a")!, file("/a"), mountPoints: mounts))
        #expect(PanelDrop.mountPoints().contains("/"))
    }

    @MainActor @Test func draggedItemsTravelOnThePasteboard() {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let local = item("a.txt"), remote = FileItem(url: URL(string: "mem:///A/one.txt")!, name: "one.txt", isDirectory: false)
        pasteboard.clearContents()
        // The drag carries a ticket; what is dragged stays in the program for as long as the drag lasts.
        pasteboard.writeObjects(PanelDrop.beginDrag(of: [local, remote]))
        defer { PanelDrop.endDrag() }
        #expect(PanelDrop.locations(on: pasteboard).map(\.absoluteString) == ["file:///x/a.txt", "mem:///A/one.txt"])
        // Only the item of the local disk is there for other programs.
        let files = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]
        #expect(files?.map(\.path) == ["/x/a.txt"])
        // Files dragged in from Finder carry file URLs only.
        pasteboard.clearContents()
        pasteboard.writeObjects([URL(fileURLWithPath: "/x/from-finder.txt") as NSURL])
        #expect(PanelDrop.locations(on: pasteboard).map(\.path) == ["/x/from-finder.txt"])
        #expect(PanelDrop.question(.move, count: 1) == "Move 1 item to" && PanelDrop.question(.copy, count: 3) == "Copy 3 items to")
    }

    // MARK: Status line

    @Test func theBriefViewsStatusLineDescribesTheItemUnderTheCursor() {
        let file = FileItem(url: URL(fileURLWithPath: "/x/win.ini"), name: "win.ini", isDirectory: false, size: 1234,
                            modified: Date(timeIntervalSince1970: 0), permissions: 0o644)
        let text = PanelViewController.detailText(for: file)
        #expect(text.hasPrefix("win  ini  1,234  ") && text.hasSuffix("  rw-r--r--"))
        #expect(PanelViewController.detailText(for: item("docs", folder: true)).hasPrefix("[docs]  <DIR>  "))
    }
}

/// The two stores that work in the background for a panel.
@MainActor @Suite(.serialized) struct PanelStores {
    func wait(upTo seconds: TimeInterval = 10, until condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition() && Date() < deadline { try? await Task.sleep(nanoseconds: 2_000_000) }
        return condition()
    }

    func item(_ name: String, size: Int64 = 1) -> FileItem {
        FileItem(url: URL(fileURLWithPath: "/x/" + name), name: name, isDirectory: false, size: size)
    }

    /// Counts calls and notes whether any came on the main thread or several ran at once.
    final class Probe: @unchecked Sendable {
        private let lock = NSLock()
        private var calls = 0, onMain = 0, running = 0, mostAtOnce = 0
        /// The first call waits for a second one beside it; for the test of calls that overlap.
        var firstWaitsForCompany = false

        func enter() {
            lock.lock()
            calls += 1
            let isFirst = calls == 1 && firstWaitsForCompany
            if Thread.isMainThread { onMain += 1 }
            running += 1
            mostAtOnce = max(mostAtOnce, running)
            lock.unlock()
            // The very first call stays until a second one has begun beside it (or gives up
            // after a good while): whether calls overlap must not depend on how fast a busy
            // machine starts the second thread.
            guard isFirst else { return }
            let deadline = Date().addingTimeInterval(20)
            while Date() < deadline {
                lock.lock()
                let hasCompany = calls > 1
                lock.unlock()
                if hasCompany { return }
                Thread.sleep(forTimeInterval: 0.001)
            }
        }

        func leave() {
            lock.lock(); running -= 1; lock.unlock()
        }

        var counts: (calls: Int, onMain: Int, mostAtOnce: Int) {
            lock.lock(); defer { lock.unlock() }
            return (calls, onMain, mostAtOnce)
        }
    }

    @Test func columnValuesAreComputedInTheBackgroundOnSeveralCores() async {
        let probe = Probe()
        probe.firstWaitsForCompany = ProcessInfo.processInfo.activeProcessorCount > 1
        let column = ContentColumn(id: "probe", title: "Probe") { item in
            probe.enter()
            Thread.sleep(forTimeInterval: 0.002)
            probe.leave()
            return "v:" + item.name
        }
        let store = ColumnValueStore()
        var arrived: Set<String> = []
        store.onArrival = { arrived.formUnion($0) }
        let items = (0..<300).map { item("f\($0)") }
        // Asking returns with nothing and computes nothing here (no call is made on the main
        // thread, checked below; how long the asking took says nothing on a busy machine).
        #expect(items.allSatisfy { store.text(of: column, for: $0) == nil })
        #expect(store.isBusy)
        let done = await wait(upTo: 60) { !store.isBusy }
        #expect(done && arrived.count == 300)
        #expect(items.allSatisfy { store.text(of: column, for: $0) == "v:" + $0.name })
        let counts = probe.counts
        #expect(counts.calls == 300 && counts.onMain == 0)
        #expect(counts.mostAtOnce > 1 || ProcessInfo.processInfo.activeProcessorCount == 1)
    }

    @Test func theRowsAskedForLastAreComputedFirst() async {
        let order = Probe.Order()
        let column = ContentColumn(id: "order", title: "Order") { item in
            order.note(item.name)
            return item.name
        }
        let store = ColumnValueStore()
        let count = ColumnValueStore.batchSize * 3
        for index in 0..<count { _ = store.text(of: column, for: item(String(format: "f%04d", index))) }
        _ = await wait { !store.isBusy }
        // The first batch started with the first request, when nothing else was waiting; of
        // what waited then, the end of the line (the rows scrolled to last) came first.
        let second = Set(order.names[1...ColumnValueStore.batchSize])
        #expect(second.contains(String(format: "f%04d", count - 1)) && !second.contains("f0001"))
        #expect(order.names.count == count)
    }

    @Test func anotherFolderForgetsTheValuesAndAChangedFileGetsANewOne() async {
        let probe = Probe()
        let column = ContentColumn(id: "c", title: "C") { item in
            probe.enter()
            probe.leave()
            return "\(item.size)"
        }
        let store = ColumnValueStore()
        var arrivals = 0
        store.onArrival = { _ in arrivals += 1 }
        _ = store.text(of: column, for: item("a", size: 1))
        _ = await wait { !store.isBusy }
        #expect(store.text(of: column, for: item("a", size: 1)) == "1" && arrivals == 1)
        // The same name with another size is another value.
        #expect(store.text(of: column, for: item("a", size: 2)) == nil)
        _ = await wait { !store.isBusy }
        #expect(store.text(of: column, for: item("a", size: 2)) == "2")
        // A value that arrives for a folder that was left is dropped; one that had not been
        // started on when the folder was left is not worked out at all (the column is told
        // through its flag that nobody wants it).
        _ = store.text(of: column, for: item("b", size: 5))
        store.reset()
        _ = await wait { !store.isBusy }
        let callsForTheFolderLeft = probe.counts.calls
        #expect(arrivals == 2 && (2...3).contains(callsForTheFolderLeft))
        #expect(store.text(of: column, for: item("b", size: 5)) == nil)
        _ = await wait { !store.isBusy }
        #expect(store.text(of: column, for: item("b", size: 5)) == "5" && probe.counts.calls == callsForTheFolderLeft + 1)
    }

    /// A thumbnail source that answers when the test says so.
    final class ScriptedThumbnails: ThumbnailSource {
        var pending: [String: (NSImage?) -> Void] = [:]
        var requested: [String] = []
        var cancelled: [String] = []

        func thumbnail(for url: URL, side: CGFloat, scale: CGFloat, completion: @escaping (NSImage?) -> Void) -> () -> Void {
            let name = url.lastPathComponent
            requested.append(name)
            pending[name] = completion
            return { [weak self] in
                self?.cancelled.append(name)
                self?.pending[name] = nil
            }
        }

        /// Answers from a background thread, as Quick Look does.
        func answer(_ name: String, with image: NSImage?) {
            guard let completion = pending.removeValue(forKey: name) else { return }
            DispatchQueue.global().async { completion(image) }
        }
    }

    @Test func thumbnailsArriveLaterAreKeptAndAreCancelledWhenOutOfSight() async {
        let source = ScriptedThumbnails()
        let store = ThumbnailStore(source: source)
        var arrived: [String] = []
        store.onArrival = { arrived.append($0) }
        let (a, b, c) = (item("a.png"), item("b.png"), item("c.txt"))
        #expect(store.image(for: a, side: 96, scale: 2) == nil && store.image(for: b, side: 96, scale: 2) == nil)
        // Asking again while the picture is being made does not ask the source again.
        #expect(store.image(for: a, side: 96, scale: 2) == nil && source.requested == ["a.png", "b.png"] && store.runningCount == 2)
        let picture = NSImage(size: NSSize(width: 10, height: 10))
        source.answer("a.png", with: picture)
        let came = await wait { arrived == ["a.png"] }
        #expect(came && store.image(for: a, side: 96, scale: 2) === picture && store.runningCount == 1)
        // Scrolled away: the request for b is given up, and an answer that still comes is dropped.
        let late = source.pending["b.png"]
        store.keepOnly([ThumbnailStore.key(for: a, side: 96)])
        #expect(source.cancelled == ["b.png"] && store.runningCount == 0)
        late?(picture)
        try? await Task.sleep(nanoseconds: 30_000_000)
        #expect(arrived == ["a.png"] && store.image(for: b, side: 96, scale: 2) == nil && source.requested.count == 3)
        // A file without a picture is not asked for twice, until the folder is shown anew.
        #expect(store.image(for: c, side: 96, scale: 2) == nil)
        source.answer("c.txt", with: nil)
        _ = await wait { store.runningCount == 1 }
        #expect(store.image(for: c, side: 96, scale: 2) == nil && source.requested.filter { $0 == "c.txt" }.count == 1)
        store.reset()
        #expect(store.runningCount == 0 && store.image(for: c, side: 96, scale: 2) == nil && source.requested.filter { $0 == "c.txt" }.count == 2)
        // Another size, or a changed file, is another picture.
        #expect(ThumbnailStore.key(for: a, side: 96) != ThumbnailStore.key(for: a, side: 128))
        #expect(ThumbnailStore.key(for: a, side: 96) != ThumbnailStore.key(for: item("a.png", size: 2), side: 96))
    }
}

extension PanelStores {
    @Test func rowsThatWentOutOfSightAreNotComputedAnyMore() async {
        let probe = Probe()
        let column = ContentColumn(id: "slow", title: "Slow") { item in
            probe.enter()
            Thread.sleep(forTimeInterval: 0.005)
            probe.leave()
            return item.name
        }
        let store = ColumnValueStore()
        let count = ColumnValueStore.batchSize * 4
        let items = (0..<count).map { item(String(format: "f%04d", $0)) }
        for one in items { _ = store.text(of: column, for: one) }
        // The panel scrolled: only the rows on screen now are wanted.
        let visible = Set(items.suffix(3).map(\.name))
        #expect(store.hasWaiting)
        store.dropWaiting(except: visible)
        _ = await wait { !store.isBusy }
        #expect(probe.counts.calls < count && items.suffix(3).allSatisfy { store.text(of: column, for: $0) != nil })
        // A row that comes back into sight is asked for again, and arrives.
        #expect(store.text(of: column, for: items[count / 2]) == nil || probe.counts.calls >= count / 2)
        _ = await wait { !store.isBusy }
        #expect(store.text(of: column, for: items[count / 2]) == items[count / 2].name)
    }

    @Test func theAnswerOfAGivenUpThumbnailRequestDoesNotSpoilANewerOne() async {
        let source = ScriptedThumbnails()
        let store = ThumbnailStore(source: source)
        var arrived: [String] = []
        store.onArrival = { arrived.append($0) }
        let a = item("a.png")
        #expect(store.image(for: a, side: 96, scale: 2) == nil)
        let late = source.pending["a.png"]
        // Scrolled away and back: a second request for the same picture is under way.
        store.keepOnly([])
        #expect(store.image(for: a, side: 96, scale: 2) == nil && source.requested == ["a.png", "a.png"] && store.runningCount == 1)
        // The first request answers late, with nothing: that must not end the second request or
        // mark the file as one without a picture.
        late?(nil)
        try? await Task.sleep(nanoseconds: 50_000_000)
        #expect(store.runningCount == 1)
        let picture = NSImage(size: NSSize(width: 10, height: 10))
        source.answer("a.png", with: picture)
        let came = await wait { arrived == ["a.png"] }
        #expect(came && store.image(for: a, side: 96, scale: 2) === picture)
    }

    @Test func picturesAreCountedByTheirPixels() {
        let small = NSImage(size: NSSize(width: 10, height: 10))
        #expect(ThumbnailStore.cost(of: small) == 400)
        let representation = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 512, pixelsHigh: 512, bitsPerSample: 8, samplesPerPixel: 4,
                                              hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        let retina = NSImage(size: NSSize(width: 256, height: 256))
        retina.addRepresentation(representation)
        #expect(ThumbnailStore.cost(of: retina) == 512 * 512 * 4)
    }
}

extension PanelStores.Probe {
    /// Notes the order of calls.
    final class Order: @unchecked Sendable {
        private let lock = NSLock()
        private var noted: [String] = []

        func note(_ name: String) {
            lock.lock(); noted.append(name); lock.unlock()
        }

        var names: [String] {
            lock.lock(); defer { lock.unlock() }
            return noted
        }
    }
}

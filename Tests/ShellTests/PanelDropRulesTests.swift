import AFMContracts
import AFMKernel
import AppKit
import TestSupport
import Testing

@testable import AFMShell

/// The rules of dragging files with the mouse by themselves (spec 05 › Drag & drop): what a drop
/// does, when it is pointless, what travels on the pasteboard and who is believed.
@MainActor
@Suite(.serialized)
internal struct PanelDropRulesTests {
    /// A local file URL.
    private func file(_ path: String) -> URL {
        URL(fileURLWithPath: path)
    }

    /// A URL of another file system.
    private func remote(_ text: String) throws -> URL {
        try #require(URL(string: text))
    }

    /// The file URLs another program reads from `pasteboard`.
    private func fileURLs(on pasteboard: NSPasteboard) -> [String] {
        (pasteboard.pasteboardItems ?? []).compactMap { $0.string(forType: .fileURL) }
    }

    /// The rule spelled out for a few sources: nothing to drop, a folder into itself or below it,
    /// or a move into the folder the items are in.
    private func isPointless(_ kind: TransferKind, _ sources: [URL], into destination: URL) -> Bool {
        sources.isEmpty
            || sources.contains { destination.isSameLocation(as: $0) || destination.isInside($0) }
            || (kind == .move && sources.allSatisfy { $0.deletingLastPathComponent().isSameLocation(as: destination) })
    }

    /// A drop copies between volumes and moves within one; Option asks for a copy and Cmd for a
    /// move; what the source does not allow is not done.
    @Test
    internal func aDropCopiesBetweenVolumesAndMovesWithinOne() {
        let all: NSDragOperation = [.copy, .move, .generic, .link]
        #expect(PanelDrop.kind(modifiers: [], sameVolume: true, allowed: all) == .move)
        #expect(PanelDrop.kind(modifiers: [], sameVolume: false, allowed: all) == .copy)
        #expect(PanelDrop.kind(modifiers: .option, sameVolume: true, allowed: all) == .copy)
        #expect(PanelDrop.kind(modifiers: .command, sameVolume: false, allowed: all) == .move)
        // A copy instead of a move, and the reverse, but never against what was asked for.
        #expect(PanelDrop.kind(modifiers: [], sameVolume: true, allowed: .copy) == .copy)
        #expect(PanelDrop.kind(modifiers: .command, sameVolume: true, allowed: .copy) == nil)
        #expect(PanelDrop.kind(modifiers: .option, sameVolume: false, allowed: .generic) == nil)
        #expect(PanelDrop.kind(modifiers: [], sameVolume: false, allowed: .generic) == .move)
        #expect(PanelDrop.kind(modifiers: [], sameVolume: false, allowed: []) == nil)
        #expect(PanelDrop.kind(modifiers: [], sameVolume: true, allowed: []) == nil)
    }

    /// Where the sources are is worked out once, and judges a drop as the rule does.
    @Test
    internal func whereTheSourcesOfADragAreIsWorkedOutOnceAndJudgedByTheRule() throws {
        let cases: [(sources: [URL], destination: URL)] = [
            ([file("/x/a/f.txt")], file("/x/a")), ([file("/x/a/f.txt")], file("/x/b")), ([file("/x/a")], file("/x/a")),
            ([file("/x/a")], file("/x/a/sub/deep")), ([file("/x/ab")], file("/x/a")),
            ([file("/x/a"), file("/y/b")], file("/x")), ([file("/a"), file("/b")], file("/")),
            ([file("/")], file("/x")),
            ([try remote("mem:///m/a")], try remote("mem:///m")),
            ([try remote("ftp://host/a/b")], try remote("ftp://other/a")),
            ([try remote("noslash:x")], file("/x")), ([], file("/x"))
        ]
        for (sources, destination) in cases {
            for kind in [TransferKind.copy, .move] {
                #expect(
                    DragSources(sources).isPointless(kind, into: destination)
                        == isPointless(kind, sources, into: destination),
                    "\(kind) \(sources.map(\.absoluteString)) into \(destination.absoluteString)"
                )
            }
        }
    }

    /// A session judges each destination once, asks the system for the mount points once, and
    /// works out a drag of very many items in the background, taking nothing until then.
    @Test
    internal func aDragIsLookedAtOnceAndNotAtEveryMoveOfTheMouse() async {
        let sources = (0..<1_000).map { file("/x/f\($0).txt") }
        let session = DropSession(sequence: 7, sources: sources)
        let (inside, elsewhere) = (file("/x"), file("/y"))
        #expect(session.isPointless(.move, into: inside) && !session.isPointless(.copy, into: inside))
        #expect(!session.isPointless(.move, into: elsewhere) && session.isPointless(.move, into: inside))
        #expect(session.mountPoints.contains("/") && session.mountPoints == PanelDrop.mountPoints())
        #expect(DropSession(sequence: 8, sources: []).isPointless(.copy, into: elsewhere))
        let many = (0..<DropSession.backgroundThreshold).map { file("/big/f\($0)") }
        let big = DropSession(sequence: 1, sources: many)
        #expect(big.places == nil && big.isPointless(.copy, into: file("/elsewhere")))
        #expect(await PanelWait.until { big.places != nil })
        #expect(!big.isPointless(.copy, into: file("/elsewhere")) && big.isPointless(.move, into: file("/big")))
        // Dropped before the background got there: worked out at once.
        let hasty = DropSession(sequence: 2, sources: many)
        hasty.finishNow()
        #expect(hasty.places != nil && !hasty.isPointless(.copy, into: file("/elsewhere")))
        await PanelWait.drainMainQueue()
    }

    /// Volumes are told apart by their mount points; places of another file system by their server.
    @Test
    internal func volumesAreToldApartByTheirMountPoints() throws {
        let mounts = ["/", "/Volumes/Stick", "/Volumes/Stick 2", "/System/Volumes/Data"]
        #expect(PanelDrop.mountPoint(of: "/Volumes/Stick/a/b", among: mounts) == "/Volumes/Stick")
        #expect(PanelDrop.mountPoint(of: "/Volumes/Stick 2/a", among: mounts) == "/Volumes/Stick 2")
        #expect(PanelDrop.mountPoint(of: "/Volumes/Sticky/a", among: mounts) == "/")
        #expect(
            PanelDrop.mountPoint(of: "/Users/me", among: mounts) == "/"
                && PanelDrop.mountPoint(of: "/a", among: []) == "/"
        )
        #expect(PanelDrop.areOnSameVolume(file("/Users/a"), file("/tmp/b"), mountPoints: mounts))
        #expect(!PanelDrop.areOnSameVolume(file("/Users/a"), file("/Volumes/Stick/b"), mountPoints: mounts))
        #expect(
            PanelDrop.areOnSameVolume(try remote("ftp://host/a"), try remote("ftp://host/b/c"), mountPoints: mounts)
        )
        #expect(
            !PanelDrop.areOnSameVolume(try remote("ftp://host/a"), try remote("ftp://other/a"), mountPoints: mounts)
        )
        #expect(!PanelDrop.areOnSameVolume(try remote("mem:///a"), file("/a"), mountPoints: mounts))
        #expect(PanelDrop.mountPoints().contains("/"))
        #expect(
            PanelDrop.question(.move, count: 1) == "Move 1 item to"
                && PanelDrop.question(.copy, count: 3) == "Copy 3 items to"
        )
    }

    /// The program's drag carries a ticket and keeps its items in the program; other programs
    /// get the files of the local disks; what another program writes in the panel's type is
    /// not believed, and the ticket is worth nothing once the drag is over.
    @Test
    internal func draggedItemsTravelOnThePasteboardAndOnlyTheProgramsOwnTicketIsBelieved() throws {
        let pasteboard = NSPasteboard.withUniqueName()
        defer {
            pasteboard.releaseGlobally()
            PanelDrop.endDrag()
        }
        let local = FileItem(url: file("/x/a.txt"), name: "a.txt")
        let far = FileItem(url: try remote("mem:///A/one.txt"), name: "one.txt")
        pasteboard.clearContents()
        pasteboard.writeObjects(PanelDrop.beginDrag(PanelDragPayload(items: [local, far])))
        #expect(PanelDrop.locations(on: pasteboard).map(\.absoluteString) == ["file:///x/a.txt", "mem:///A/one.txt"])
        #expect(fileURLs(on: pasteboard) == ["file:///x/a.txt"])
        PanelDrop.endDrag()
        #expect(PanelDrop.current == nil && PanelDrop.locations(on: pasteboard).map(\.path) == ["/x/a.txt"])
        // Another program writes the panel's type with a location on a server: not taken.
        let forged = NSPasteboardItem()
        forged.setString("sftp://evil.example/secret", forType: PanelDrop.itemType)
        pasteboard.clearContents()
        pasteboard.writeObjects([forged])
        #expect(PanelDrop.locations(on: pasteboard).isEmpty)
        // Files dragged in from Finder carry file URLs.
        pasteboard.clearContents()
        pasteboard.writeObjects([file("/x/from-finder.txt") as any NSPasteboardWriting])
        #expect(PanelDrop.locations(on: pasteboard).map(\.path) == ["/x/from-finder.txt"])
        #expect(PanelDrop.beginDrag(PanelDragPayload(items: [])).isEmpty && PanelDrop.current == nil)
    }

    /// A drag of very many items is one pasteboard item that hands out its files when asked:
    /// the first file, and the list of all as paths.
    @Test
    internal func aDragOfVeryManyItemsIsOneItemThatHandsOutItsFilesWhenAsked() {
        defer { PanelDrop.endDrag() }
        let items = (0...PanelDrop.itemsWrittenSingly).map { FileItem(url: file("/many/f\($0)"), name: "f\($0)") }
        let written = PanelDrop.beginDrag(PanelDragPayload(items: items))
        #expect(written.count == 1 && written[0].types.contains(.fileURL))
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        pasteboard.writeObjects(written)
        PanelDrop.offerFileNames(on: pasteboard)
        #expect(PanelDrop.locations(on: pasteboard).count == items.count)
        #expect(pasteboard.string(forType: .fileURL) == "file:///many/f0")
        let paths = pasteboard.propertyList(forType: PanelDrop.fileNamesType) as? [String]
        #expect(paths?.count == items.count && paths?.first == "/many/f0")
        // A drag of a few offers no list of its own: its items name their files one by one.
        let few = NSPasteboard.withUniqueName()
        defer { few.releaseGlobally() }
        few.clearContents()
        few.writeObjects(PanelDrop.beginDrag(PanelDragPayload(items: Array(items.prefix(2)))))
        let types = few.types
        PanelDrop.offerFileNames(on: few)
        #expect(few.types == types && few.pasteboardItems?.count == 2)
    }

    /// The marks of a long list are put together in the background; whoever needs them first
    /// has them at once, and a session waits for them.
    @Test
    internal func theMarksOfALongListArePutTogetherBehindTheDrag() async {
        let folder = file("/marks")
        let model = Fixture.panel((0..<3_000).map { Fixture.file("f\($0)", in: folder) }, at: folder)
        model.selectAll()
        let payload = PanelDragPayload(marked: model.operandsSnapshot())
        #expect(payload.itemCount == 3_000 && payload.isWrittenLazily && !payload.isReady)
        var heard: [Int] = []
        payload.whenReady { heard.append($0.count) }
        let session = DropSession(sequence: 3, payload: payload)
        #expect(session.sources.isEmpty)
        #expect(await PanelWait.until { session.places != nil })
        #expect(heard == [3_000] && session.sources.count == 3_000 && payload.items.count == 3_000)
        payload.whenReady { heard.append($0.count) }
        #expect(heard == [3_000, 3_000])
        // Asked before the background got there: put together at once.
        let hasty = PanelDragPayload(marked: model.operandsSnapshot())
        #expect(hasty.locations.count == 3_000 && hasty.isReady)
        let early = DropSession(sequence: 4, payload: PanelDragPayload(marked: model.operandsSnapshot()))
        early.finishNow()
        #expect(early.sources.count == 3_000 && early.places != nil)
        await PanelWait.drainMainQueue()
    }

    /// Another program that writes a server, an archive or anything else that is not a file into
    /// the file URL's type names no source: only files are taken from other programs.
    @Test
    internal func anotherProgramCannotNameAServerAsASource() {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        let items = ["smb://host/share/x", "mem:///A/one.txt", "not a url", "file:///x/kept.txt"]
            .map { text in
                let item = NSPasteboardItem()
                item.setString(text, forType: .fileURL)
                return item
            }
        pasteboard.writeObjects(items)
        #expect(PanelDrop.locations(on: pasteboard).map(\.absoluteString) == ["file:///x/kept.txt"])
    }

    /// A payload nobody holds any more is gone.
    @Test
    internal func aPayloadNobodyHoldsIsGone() {
        weak var gone: PanelDragPayload?
        do {
            let payload = PanelDragPayload(items: [FileItem(url: file("/x/a.txt"), name: "a.txt")])
            gone = payload
            #expect(payload.isReady && gone != nil)
        }
        #expect(gone == nil)
    }
}

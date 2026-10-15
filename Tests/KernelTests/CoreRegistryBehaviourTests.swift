import Foundation
import TestSupport
import Testing

@testable import AFMKernel

/// What the registries, the defaults of a file system and the consent to typed places answer,
/// down to the details a plugin relies on.
@MainActor
@Suite(.serialized)
internal struct CoreRegistryBehaviourTests {
    /// A file system with the required calls, and listings in batches.
    private final class BatchedFileSystem: MemoryBacked, @unchecked Sendable {
        let inner = MemoryFileSystem(scheme: "corebatch")
        var capabilities: FileSystemCapabilities { [.write] }

        init() {
            inner.listBatchSize = 7
        }

        func list(_ directory: URL, showHidden: Bool, receive: ([FileItem]) -> Bool) throws {
            try inner.list(directory, showHidden: showHidden, receive: receive)
        }

        deinit {
            // Nothing to release.
        }
    }

    /// A file system whose copies fail with an error of their own.
    private final class FailingCopies: MemoryBacked, @unchecked Sendable {
        let inner = MemoryFileSystem(scheme: "corecopy")
        var capabilities: FileSystemCapabilities { [.write] }

        func copy(_: URL, to _: URL, progress _: (Int64) -> Bool) throws {
            throw CocoaError(.fileWriteOutOfSpace)
        }

        deinit {
            // Nothing to release.
        }
    }

    /// A file system that is not the local one and reads no rooted paths.
    private final class ElsewhereFileSystem: MemoryBacked, @unchecked Sendable {
        let inner = MemoryFileSystem(scheme: "coreelse")
        var capabilities: FileSystemCapabilities { [.write] }

        deinit {
            // Nothing to release.
        }
    }

    /// Records the places the user chose.
    private final class Consent: ServerConsentService {
        var chosen: [URL] = []

        func userChose(_ location: URL) { chosen.append(location) }

        deinit {
            // Nothing to release.
        }
    }

    /// Answers with the error it was told and records it.
    private final class Recording: UserInteraction {
        var said: [String] = []

        func prompt(_: String, value _: String, detail _: String) -> String? { nil }
        func choose(_: String, detail _: String, buttons _: [String], style _: QuestionStyle) -> Int { 0 }

        func inform(_ message: String, detail: String, style _: QuestionStyle) {
            said.append(message + ": " + detail)
        }

        func form(_: String, detail _: String, fields _: [FormField], buttons _: [String]) -> FormValues? { nil }

        deinit {
            // Nothing to release.
        }
    }

    /// When two overridden commands want one key, the later of them by name keeps it.
    @Test
    internal func overridesAreAppliedInTheOrderOfTheCommandNames() {
        let keys = KeyBindings()
        keys.apply(overrides: ["core.b": ["f5"], "core.a": ["f5", "f6"]])
        #expect(keys.command(for: .f(5)) == "core.b" && keys.shortcuts(for: "core.a") == [.f(6)])
    }

    /// Only the local file system reads paths from the root as its own, and a location in a file
    /// system's notation is read back by it.
    @Test
    internal func theNotationOfAFileSystemIsReadBackByIt() {
        let batched = BatchedFileSystem()
        #expect(!batched.readsRootedPaths && MemoryFileSystem(scheme: "file").readsRootedPaths)
        #expect(batched.location(from: "corebatch:/a/b") == URL(string: "corebatch:/a/b"))
        #expect(batched.location(from: "other:/a") == nil)
    }

    /// A listing in batches ends as soon as the receiver wants no more.
    @Test
    internal func aListingEndsWhenNoMoreIsWanted() throws {
        let batched = BatchedFileSystem()
        for index in 0..<30 {
            _ = batched.inner.addFile("/big/f\(index).txt")
        }
        var batches = 0
        try batched.list(batched.inner.url("/big"), showHidden: true, cancellation: CancellationFlag()) { _ in
            batches += 1
            return false
        }
        #expect(batches == 1)
    }

    /// A copy that fails for a reason of its own says that reason while nobody has given up.
    @Test
    internal func aFailedCopySaysWhyWhileNobodyGaveUp() {
        let failing = FailingCopies()
        let file = failing.inner.addFile("/a.txt")
        #expect(throws: CocoaError(.fileWriteOutOfSpace)) {
            try failing.copy(file, to: failing.inner.url("/b.txt"), cancellation: CancellationFlag()) { _ in true }
        }
    }

    /// A path from the root is local when the base's file system does not read such paths and a
    /// local file system is there; without one, it stays a place of the base's.
    @Test
    internal func aRootedPathIsLocalOnlyWhenThereIsALocalFileSystem() {
        let elsewhere = ElsewhereFileSystem()
        let base = elsewhere.inner.url("/a")
        let alone = FileSystemRegistry()
        alone.register(elsewhere)
        #expect(alone.location(from: "/x", relativeTo: base).scheme == "coreelse")
        let both = FileSystemRegistry()
        both.register(elsewhere)
        both.register(MemoryFileSystem(scheme: "file"))
        #expect(both.location(from: "/x", relativeTo: base) == URL(fileURLWithPath: "/x"))
    }

    /// Every releaser lets go of a volume that is about to go.
    @Test
    internal func everyReleaserLetsGoOfAVolume() {
        let registry = FileSystemRegistry()
        let released = Shared<[String]>([])
        registry.addVolumeReleaser { volume in released.modify { $0.append("first " + volume.path) } }
        registry.addVolumeReleaser { volume in released.modify { $0.append("second " + volume.path) } }
        registry.releaseVolume(URL(fileURLWithPath: "/Volumes/Stick"))
        #expect(released.value == ["first /Volumes/Stick", "second /Volumes/Stick"])
    }

    /// Only drives that leave the Mac may be ejected.
    @Test
    internal func onlyDrivesThatLeaveTheMacMayBeEjected() {
        func traits(_ path: String, _ facts: [WritableKeyPath<Place.VolumeTraits, Place.Fact>: Bool]) -> Bool {
            var volume = Place.VolumeTraits(path: path, values: nil)
            for (fact, value) in facts {
                volume[keyPath: fact] = .known(value)
            }
            return volume.mayBeEjected
        }
        #expect(!traits("/Volumes/Boot", [\.isRootFileSystem: true, \.isEjectable: true]))
        #expect(!traits("/", [\.isEjectable: true]))
        #expect(!traits("/System/Volumes/Data", [\.isRemovable: true]))
        #expect(traits("/Volumes/Stick", [\.isRootFileSystem: false, \.isEjectable: true]))
        #expect(traits("/Volumes/Card", [\.isRemovable: true, \.isInternal: true]))
        #expect(traits("/Volumes/Share", [\.isLocal: false, \.isInternal: true]))
        #expect(!traits("/Volumes/Inside", [\.isLocal: true, \.isInternal: true]))
        #expect(traits("/Volumes/Outside", [\.isLocal: true, \.isInternal: false]))
        #expect(!traits("/Volumes/Mystery", [:]))
    }

    /// A column is found by its own id.
    @Test
    internal func aColumnIsFoundByItsId() {
        let columns = ColumnRegistry()
        columns.register(ContentColumn(id: "core.one", title: "One") { _ in "1" })
        columns.register(ContentColumn(id: "core.two", title: "Two") { _ in "2" })
        #expect(columns["core.two"]?.title == "Two" && columns["core.three"] == nil)
    }

    /// Panel events reach every subscriber that is still kept, and none that was let go of.
    @Test
    internal func panelEventsReachTheSubscribersThatAreKept() {
        let events = PanelEvents()
        let panel = FakePanel(showing: URL(fileURLWithPath: "/"), fileSystems: FileSystemRegistry())
        let heard = Shared<[String]>([])
        let kept = events.subscribe { event, _ in heard.modify { $0.append("kept \(event)") } }
        var dropped: AnyObject? = events.subscribe { event, _ in heard.modify { $0.append("dropped \(event)") } }
        events.post(.cursorMoved, from: panel)
        dropped = nil
        events.post(.selectionChanged, from: panel)
        #expect(
            heard.value == ["kept cursorMoved", "dropped cursorMoved", "kept selectionChanged"]
                && dropped == nil
        )
        withExtendedLifetime(kept) {
            // Kept until here.
        }
    }

    /// The pages of the configuration are kept in the order they were added.
    @Test
    internal func preferencePagesAreKeptInOrder() {
        let registry = PreferenceRegistry()
        registry.add(PreferencePage(title: "One", preferences: []))
        registry.add(PreferencePage(title: "Two", preferences: []))
        #expect(registry.pages.map(\.title) == ["One", "Two"])
    }

    /// A typed place with an address is the user's choice, unless it is the text the program proposed.
    @Test
    internal func aTypedAddressIsTheUsersChoiceUnlessItWasProposed() {
        let kernel = Kernel(productName: "Test", settings: MemorySettings(), interaction: ScriptedInteraction())
        let consent = Consent()
        kernel.services.register((any ServerConsentService).self, consent)
        kernel.fileSystems.register(ElsewhereFileSystem())
        let base = URL(fileURLWithPath: "/")
        kernel.userTyped(location: " coreelse://host/a ", relativeTo: base, proposal: "coreelse://host/a")
        kernel.userTyped(location: "coreelse://host/b", relativeTo: base, proposal: "coreelse://host/a")
        kernel.userTyped(location: "/plain/path", relativeTo: base)
        #expect(consent.chosen == [URL(string: "coreelse://host/b")])
    }

    /// Declared keys are listed by name, families after them in the order they were declared.
    @Test
    internal func declaredKeysAreListedByName() {
        let keys = SettingsKeyRegistry()
        keys.declare("core.b")
        keys.declare("core.a", kind: .history)
        keys.declare(prefix: "core.z.")
        #expect(keys.all.map(\.key) == ["core.a", "core.b", "core.z."])
    }

    /// The button bar: the proposal by group, the user's layout when there is one, and a redraw
    /// whenever the layout is stored or forgotten.
    @Test
    internal func theButtonBarFollowsTheProposalOrTheUsersLayout() {
        let toolbar = ToolbarRegistry()
        let settings = MemorySettings()
        var redrawn = 0
        toolbar.onChange = { redrawn += 1 }
        toolbar.add("core.copy", symbol: "doc.on.doc", group: 2)
        toolbar.add("core.view", symbol: "eye", group: 1, hint: "Shows the file")
        toolbar.add("core.edit", symbol: "pencil", group: 1)
        toolbar.setSymbol("trash", for: "core.delete")
        #expect(toolbar.defaultLayout.map { $0?.command } == ["core.view", "core.edit", nil, "core.copy"])
        #expect(toolbar.hint(for: "core.view") == "Shows the file" && toolbar.symbol(for: "core.delete") == "trash")
        #expect(!toolbar.hasUserLayout(in: settings))
        toolbar.setLayout(["core.delete", nil, "core.unknown"], in: settings)
        #expect(toolbar.hasUserLayout(in: settings) && redrawn == 1)
        let layout = toolbar.layout(from: settings)
        #expect(layout.map { $0?.command } == ["core.delete", nil, "core.unknown"])
        #expect(layout.map { $0?.symbol } == ["trash", nil, "square.dashed"])
        toolbar.resetLayout(in: settings)
        #expect(!toolbar.hasUserLayout(in: settings) && redrawn == 2)
        #expect(toolbar.layout(from: settings).count == 4)
    }

    /// A failure is told as a warning with the error's own words.
    @Test
    internal func aFailureIsToldWithTheErrorsWords() {
        let recording = Recording()
        recording.report(CocoaError(.fileNoSuchFile), title: "Copy failed")
        #expect(recording.said == ["Copy failed: " + CocoaError(.fileNoSuchFile).localizedDescription])
    }
}

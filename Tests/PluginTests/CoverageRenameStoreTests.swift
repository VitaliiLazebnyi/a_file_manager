import AFMKernel
import Foundation
import TestSupport
import Testing

@testable import MultiRenamePlugin

/// What the Multi-Rename Tool keeps in the settings, at its edges: settings saved by another
/// version, preferences that are no number, lists of names in odd encodings.
@MainActor
@Suite
struct CoverageRenameStore {
    /// One of the saved settings lacks a field (written by another version): the others still load.
    @Test
    func aDamagedSavedSettingLeavesTheOthers() throws {
        let settings = MemorySettings()
        SettingsJSON.store(
            #"""
            {"Good":{"nameMask":"x[C]","extensionMask":"[E]","search":"","replacement":"","caseSensitive":false,\#
            "firstOnly":false,"searchesExtension":true,"regularExpression":false,"substitute":false,"letterCase":0,\#
            "counter":{"start":1,"step":1,"digits":1}},"Broken":{"nameMask":7}}
            """#,
            forKey: "multirename.saved",
            in: settings
        )
        let store = RenameStore(settings: settings)
        #expect(store.savedNames == ["Good"])
        #expect(try #require(store.saved["Good"]).nameMask == "x[C]")
        // Read once: a second look is answered from memory, also after the stored text is gone.
        settings.set(nil, forKey: "multirename.saved")
        #expect(store.savedNames == ["Good"])
    }

    /// A stored value that is no object at all gives no saved settings.
    @Test
    func savedSettingsThatAreNoObjectAreNone() {
        let settings = MemorySettings()
        SettingsJSON.store("[1, 2]", forKey: "multirename.saved", in: settings)
        #expect(RenameStore(settings: settings).saved.isEmpty)
    }

    /// The undo length is read as typed: spaces are allowed, text and negative numbers are not.
    @Test
    func theUndoLengthReadsWhatWasTyped() {
        let settings = MemorySettings()
        let store = RenameStore(settings: settings)
        #expect(store.undoLimit == 20)
        settings.set(" 5 ", forKey: RenameStore.undoLimitKey)
        #expect(store.undoLimit == 5)
        settings.set("many", forKey: RenameStore.undoLimitKey)
        #expect(store.undoLimit == 20)
        settings.set("-3", forKey: RenameStore.undoLimitKey)
        #expect(store.undoLimit == 0)
    }

    /// Asking for the undo history again once it is in memory answers at once.
    @Test
    func loadingTheUndoHistoryTwiceAnswersAtOnce() {
        let store = RenameStore(settings: MemorySettings())
        store.appendUndo([RenamedItem(from: URL(fileURLWithPath: "/a"), to: URL(fileURLWithPath: "/b"))])
        var answered = false
        store.loadUndo { answered = true }
        #expect(answered && store.undoCount == 1)
    }

    /// The history is decoded in the background when it is asked for first; the completion runs
    /// on the main thread with the runs in memory.
    @Test
    func theUndoHistoryIsDecodedInTheBackground() async {
        let settings = MemorySettings()
        let writer = RenameStore(settings: settings)
        writer.appendUndo([RenamedItem(from: URL(fileURLWithPath: "/a"), to: URL(fileURLWithPath: "/b"))])
        writer.flush()
        let copy = MemorySettings()
        for key in ["multirename.undo", "multirename.undoCount"] { copy.set(settings.data(forKey: key), forKey: key) }
        let reader = RenameStore(settings: copy)
        var answered = false
        reader.loadUndo { answered = true }
        #expect(await RunLoopWait.until { answered })
        #expect(reader.lastUndo?.first?.to.path == "/b")
    }

    /// Writing the history now is nothing to do while it was never read.
    @Test
    func flushingAnUnreadHistoryWritesNothing() {
        let settings = MemorySettings()
        RenameStore(settings: settings).flush()
        #expect(
            settings.data(forKey: "multirename.undo") == nil && settings.data(forKey: "multirename.undoCount") == nil
        )
    }

    /// UTF-16 with a byte-order mark and half a character pair is no text.
    @Test
    func aBrokenUTF16ListIsEmpty() {
        #expect(RenameNameList.text(from: Data([0xFF, 0xFE, 0x00, 0xD8])).isEmpty)
        #expect(RenameNameList.text(from: Data([0xFF, 0xFE, 0x41, 0x00])) == "A")
    }

    /// Bytes that are neither UTF-8 nor the Western code page are read as far as they go.
    @Test
    func undecodableBytesAreReadAsFarAsTheyGo() {
        let text = RenameNameList.text(from: Data([0x61, 0x81, 0x62]))
        #expect(text.hasPrefix("a") && text.hasSuffix("b"))
    }
}

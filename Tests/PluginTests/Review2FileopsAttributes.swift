import AFMKernel
import Foundation
import LocalFileSystemPlugin
import TestSupport
import Testing

@testable import FilePropertiesPlugin

/// Changes of rights and flags: octal modes, written and read back, Recurse, races with other programs, the
/// message about failures.
@MainActor
@Suite
internal struct Review2FileopsAttributes {
    // F028, F076
    /// An octal mode sets the whole mode as chmod does, and letters leave the special bits.
    @Test
    internal func anOctalModeIsTheWholeModeAsForChmod() {
        #expect(PermissionChange("755") == .absolute(0o755, keepingSpecialBits: false))
        #expect(PermissionChange("755")?.applied(to: 0o4755, isDirectory: false) == 0o755)
        #expect(PermissionChange("4755")?.applied(to: 0o644, isDirectory: false) == 0o4755)
        #expect(PermissionChange("0755")?.applied(to: 0o4755, isDirectory: false) == 0o755)
        // Letters cannot name the three special bits, and leave them.
        #expect(PermissionChange("rwxr-xr-x")?.applied(to: 0o4700, isDirectory: false) == 0o4755)
        #expect(PermissionChange("go-w")?.applied(to: 0o2777, isDirectory: true) == 0o2755)
    }

    // F069
    /// Every permission change reads back from its own text, and a parsed attribute change fills the dialog the
    /// same way.
    @Test
    internal func everyChangeCanBeWrittenAndReadBack() throws {
        for text in ["755", "4755", "rwxr-x---", "u+x,go-w", "a+rX", "o=", "ug+rw"] {
            let change = try #require(PermissionChange(text))
            #expect(PermissionChange(change.text) == change, "\(text) → \(change.text)")
        }
        let parsed = try #require(AttributeChange.parse(parameters: "+mu+x,go-w +f"))
        var draft = AttributeDraft(items: [
            FileItem(url: URL(fileURLWithPath: "/tmp/x"), name: "x", stat: .init(permissions: 0o644))
        ])
        draft.take(parsed.change)
        #expect(draft.permissions == "u+x,go-w" && draft.untouchedPermissions == nil)
        #expect(try draft.change(isLocal: true).get().permissions == parsed.change.permissions)
    }

    // F028: Recurse with the mode left as shown.
    /// Recurse with the mode left as shown is asked about first, then applied to everything.
    @Test
    internal func recurseWithUntouchedPermissionsIsAskedAboutNotDroppedSilently() throws {
        var draft = AttributeDraft(items: [
            FileItem(url: URL(fileURLWithPath: "/tmp/d"), name: "d", kind: .directory, stat: .init(permissions: 0o750))
        ])
        draft.recurse = true
        let untouched = try draft.change(isLocal: true).get()
        #expect(draft.untouchedPermissions == "750" && untouched.isEmpty)
        draft.confirmPermissions()
        #expect(draft.untouchedPermissions == nil)
        #expect(try draft.change(isLocal: true).get().permissions == .absolute(0o750, keepingSpecialBits: false))
    }

    // F063, F064, F043
    /// A change starts from the item's mode now, leaves a locked file alone unless asked, and never follows a link.
    @Test
    internal func changesStartFromWhatTheItemHasNowAndNeverUnlockOrFollowALink() throws {
        let box = try Sandbox()
        let fileSystems = FileSystemRegistry()
        fileSystems.register(LocalFileSystem())
        let local = try #require(try? fileSystems.provider(for: box.root))
        // Listed with 644, made 600 by somebody else since: `u+x` gives 700, not 744.
        let file = try box.file("d/a.txt")
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)
        let listed = try #require(local.item(at: file))
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        var change = AttributeChange()
        change.permissions = try #require(PermissionChange("u+x"))
        var outcome = AttributeJob(
            change: change,
            fileSystems: fileSystems,
            cancellation: CancellationFlag(),
            meter: nil
        )
        .run([listed])
        #expect(outcome.failed == 0 && LocalInfo.details(file)?.mode == 0o700)
        // A locked file with "Locked: unchanged" is reported and stays locked and as it was.
        let lockedFile = try box.file("d/locked.txt")
        try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: lockedFile.path)
        try LocalInfo.setFlag(UInt32(UF_IMMUTABLE), true, of: lockedFile)
        defer { try? LocalInfo.setFlag(UInt32(UF_IMMUTABLE), false, of: lockedFile) }
        change.permissions = try #require(PermissionChange("644"))
        outcome = AttributeJob(change: change, fileSystems: fileSystems, cancellation: CancellationFlag(), meter: nil)
            .run([try #require(local.item(at: lockedFile))])
        #expect(
            outcome.failed == 1 && LocalInfo.details(lockedFile)?.isLocked == true
                && LocalInfo.details(lockedFile)?.mode == 0o444
        )
        // With "Locked: clear" the same change goes through.
        change.locked = .clear
        outcome = AttributeJob(change: change, fileSystems: fileSystems, cancellation: CancellationFlag(), meter: nil)
            .run([try #require(local.item(at: lockedFile))])
        #expect(outcome.failed == 0 && LocalInfo.details(lockedFile)?.mode == 0o644)
        // Listed as a file, replaced by a link since: the link's target keeps its mode.
        let victim = try box.file("private/key", "k")
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: victim.path)
        let swapped = try box.file("d/swap.txt")
        let before = try #require(local.item(at: swapped))
        try FileManager.default.removeItem(at: swapped)
        try FileManager.default.createSymbolicLink(at: swapped, withDestinationURL: victim)
        change = AttributeChange()
        change.permissions = try #require(PermissionChange("777"))
        _ = AttributeJob(change: change, fileSystems: fileSystems, cancellation: CancellationFlag(), meter: nil)
            .run([before])
        #expect(LocalInfo.details(victim)?.mode == 0o600)
    }

    // F029, F030
    /// A long list of failures is cut to twenty lines and the number of the rest.
    @Test
    internal func aLongListOfFailuresIsCutForTheMessage() {
        let failures = (0..<20).map { "item \($0): no" }
        let text = PropertyActions.summary(of: failures, total: 300_000)
        #expect(text.split(separator: "\n").count == 21 && text.hasSuffix("… and 299980 more"))
        #expect(PropertyActions.summary(of: ["one: no"], total: 1) == "one: no")
    }
}

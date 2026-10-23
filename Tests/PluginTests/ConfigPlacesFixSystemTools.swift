import AFMKernel
import Foundation
import TestSupport
import Testing

@testable import SystemToolsPlugin

/// Typed commands find the right program, and a cancelled child ends.
@Suite
internal struct ConfigPlacesFixSystemTools {
    /// A program on the PATH is run before an application of the same name; a path to an `.app`
    /// is always the application.
    @Test
    internal func aProgramOnThePathBeatsAnApplicationOfTheSameName() throws {
        let box = try Sandbox()
        try box.folder("Apps/mail.app")
        try box.folder("Apps/afmnotaprogram.app")
        try box.file("bin/mail")
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: box.url("bin/mail").path)
        #expect(
            TypedCommand.isOnPath("mail", path: box.url("bin").path)
                && !TypedCommand.isOnPath("mail", path: box.url("Apps").path)
        )
        #expect(TypedCommand.isOnPath("sh", path: "/bin:/usr/bin"))
        // A name that no program has still opens the application.
        let app = try #require(TypedCommand("afmnotaprogram"))
        #expect(
            app.application(relativeTo: box.root, searching: [box.url("Apps")], path: TypedCommand.processPath) != nil
        )
        // `mail` is a program of the system, so it is left to the shell.
        if TypedCommand.isOnPath("mail", path: TypedCommand.processPath) {
            #expect(
                try #require(TypedCommand("mail"))
                    .application(relativeTo: box.root, searching: [box.url("Apps")], path: TypedCommand.processPath)
                    == nil
            )
        }
        // A path ending in .app is an application whatever the PATH holds.
        #expect(
            try #require(TypedCommand(box.url("Apps/mail.app").path))
                .application(
                    relativeTo: box.root,
                    searching: TypedCommand.applicationFolders,
                    path: TypedCommand.processPath
                ) != nil
        )
    }

    /// Cancelling ends a child that ignores the terminate signal, well before it would end itself.
    @Test
    internal func cancellingEndsAChildThatIgnoresTerminate() {
        let flag = CancellationFlag()
        let runner = ProcessRunner(
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "trap '' TERM; sleep 30 & wait"],
            directory: nil
        )
        Thread.detachNewThread {
            Thread.sleep(forTimeInterval: 0.3)
            flag.cancel()
        }
        let started = Date()
        let outcome = runner.run(cancellation: flag, progress: nil)
        #expect(outcome.wasCancelled && Date().timeIntervalSince(started) < 10)
    }
}

import AppKit
import Foundation
import TestSupport

@testable import SystemToolsPlugin

/// A desktop for the system tools that does nothing outside the program: it records what the tools asked of it and
/// answers as the test says. Any thread: everything is kept in `Shared` boxes.
internal final class CovSysToolsDesktop: Sendable {
    /// The applications started.
    internal let started = Shared<[URL]>([])
    /// The files (or folders) opened, each with the application that opens them.
    internal let opened = Shared<[(files: [URL], application: URL)]>([])
    /// The print operations whose dialog would have been shown.
    internal let printed = Shared<[NSPrintOperation]>([])
    /// The texts put on the clipboard.
    internal let copied = Shared<[String]>([])
    /// How often the program would have quit.
    internal let quits = Shared(0)
    /// How often the program would have been minimized.
    internal let minimizes = Shared(0)
    /// The volumes renamed, with their new names.
    internal let renamed = Shared<[(volume: URL, name: String)]>([])
    /// The applications known by bundle identifier.
    internal let identified = Shared<[String: URL]>([:])
    /// The applications that open any file, and the usual one.
    internal let applications = Shared<(usual: URL?, all: [URL])>((nil, []))
    /// What renaming a volume throws; nil lets it succeed.
    internal let renameError = Shared<(any Error)?>(nil)

    /// Lets the main thread run what was queued for it until `condition` holds; false when it still does not after
    /// `Wait.ceiling`.
    @MainActor
    internal static func settle(until condition: () -> Bool) async -> Bool {
        let end = Date(timeIntervalSinceNow: Wait.ceiling)
        while !condition() {
            guard Date() < end else {
                return false
            }
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
        return true
    }

    /// The desktop: every line may run (by `shell`), the PATH is `searchPath`, files print with `printer`, the volumes
    /// are `volumes`.
    internal func desktop(
        shell: URL,
        searchPath: String,
        printer: URL,
        volumes: any VolumeAccess
    ) -> ToolsDesktop {
        ToolsDesktop(
            mayRun: { _ in true },
            shell: (shell, ["-c"]),
            searchPath: { searchPath },
            environment: { ["PATH": searchPath, "AFM_COVERAGE": "yes"] },
            applicationWithIdentifier: { [identified] identifier in identified.value[identifier] },
            applicationsToOpen: { [applications] _ in applications.value },
            renameVolume: { [renamed, renameError] volume, name in
                if let error = renameError.value {
                    throw error
                }
                renamed.modify { $0.append((volume, name)) }
            },
            volumes: volumes,
            printer: printer,
            start: { [started] application in started.modify { $0.append(application) } },
            open: { [opened] files, application in opened.modify { $0.append((files, application)) } },
            print: { [printed] operation in printed.modify { $0.append(operation) } },
            copy: { [copied] text in copied.modify { $0.append(text) } },
            quit: { [quits] in quits.modify { $0 += 1 } },
            minimize: { [minimizes] in minimizes.modify { $0 += 1 } }
        )
    }

    /// The desktop with the plain system shell, the PATH of this process, `/usr/bin/true` as the printer and the
    /// volumes of the Mac, ejected by nobody.
    internal func desktop() -> ToolsDesktop {
        desktop(
            shell: URL(fileURLWithPath: "/bin/sh"),
            searchPath: TypedCommand.processPath,
            printer: URL(fileURLWithPath: "/usr/bin/true"),
            volumes: ToolsDesktop.quiet.volumes
        )
    }

    /// The desktop of `desktop()` with other volumes.
    internal func desktop(volumes: any VolumeAccess) -> ToolsDesktop {
        var desktop = desktop()
        desktop.volumes = volumes
        return desktop
    }

    /// The desktop of `desktop()` with another printer program.
    internal func desktop(printer: URL) -> ToolsDesktop {
        var desktop = desktop()
        desktop.printer = printer
        return desktop
    }

    deinit {
        // Nothing to release.
    }
}

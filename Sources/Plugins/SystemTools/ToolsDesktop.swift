import AppKit

/// What the system tools do outside the program, and the questions to the system behind it: starting applications,
/// printing, the clipboard, quitting and minimizing, renaming and ejecting volumes, the shell a line runs in. The
/// program uses the system's (`system`); tests use `quiet`, which does nothing outside the program and answers
/// from what the test gives it, so that nothing opens, prints, quits or ejects on the desktop.
///
/// The main-thread members are called on the main thread; the others on a job's thread.
internal struct ToolsDesktop: Sendable {
    /// The system's own.
    internal static let system = Self(
        mayRun: { _ in true },
        shell: (URL(fileURLWithPath: LoginShell.posix.executable), LoginShell.posix.options),
        searchPath: { LoginShell.searchPath },
        environment: { LoginShell.environment(ProcessInfo.processInfo.environment, path: LoginShell.foreignPath) },
        applicationWithIdentifier: { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) },
        applicationsToOpen: { file in
            (NSWorkspace.shared.urlForApplication(toOpen: file), NSWorkspace.shared.urlsForApplications(toOpen: file))
        },
        renameVolume: { volume, name in
            var (location, values) = (volume, URLResourceValues())
            values.volumeName = name
            try location.setResourceValues(values)
        },
        volumes: SystemVolumes(unmount: SystemVolumes.unmount),
        printer: URL(fileURLWithPath: "/usr/bin/lpr"),
        start: { NSWorkspace.shared.openApplication(at: $0, configuration: NSWorkspace.OpenConfiguration()) },
        open: { NSWorkspace.shared.open($0, withApplicationAt: $1, configuration: NSWorkspace.OpenConfiguration()) },
        print: { Self.run($0, sheetOf: NSApplication.shared.mainWindow) },
        copy: { text in
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        },
        quit: { NSApplication.shared.terminate(nil) },
        // The command comes through the main window's responder chain: there is a main window.
        minimize: { NSApplication.shared.mainWindow?.miniaturize(nil) }
    )

    /// Nothing outside the program: only harmless lines run, by the plain system shell with the PATH and the
    /// environment of this process; no application is known by its identifier and none opens a file; renaming and
    /// ejecting a volume succeed without touching it; printing, copying, quitting and minimizing do nothing. The
    /// volumes are those of the Mac as they are.
    internal static let quiet = Self(
        mayRun: SystemTools.isHarmless,
        shell: (URL(fileURLWithPath: "/bin/sh"), ["-c"]),
        searchPath: { TypedCommand.processPath },
        environment: { ProcessInfo.processInfo.environment },
        applicationWithIdentifier: { _ in nil },
        applicationsToOpen: { _ in (nil, []) },
        renameVolume: { _, _ in
            // The volume keeps its name.
        },
        volumes: SystemVolumes { _, _, done in done(nil) },
        printer: URL(fileURLWithPath: "/usr/bin/true"),
        start: { _ in
            // Nothing starts.
        },
        open: { _, _ in
            // Nothing opens.
        },
        print: { _ in
            // Nothing prints.
        },
        copy: { _ in
            // The clipboard stays as it is.
        },
        quit: {
            // The program goes on.
        },
        minimize: {
            // The windows stay.
        }
    )

    /// Whether a typed line may run at all.
    internal var mayRun: @Sendable (TypedCommand) -> Bool
    /// The shell that runs a line, and its options before the line.
    internal var shell: (executable: URL, options: [String])
    /// The PATH that decides whether a bare name is a program or an application. May start a process the first
    /// time.
    internal var searchPath: @Sendable () -> String
    /// The environment a line runs in.
    internal var environment: @Sendable () -> [String: String]
    /// The application with this bundle identifier.
    internal var applicationWithIdentifier: @Sendable (String) -> URL?
    /// The applications that can open a file, and the one that usually does. Asks the file's volume.
    internal var applicationsToOpen: @Sendable (URL) -> (usual: URL?, all: [URL])
    /// Gives the volume at a location a new name. Asks the volume.
    internal var renameVolume: @Sendable (URL, String) throws -> Void
    /// The volumes, to look at and to eject.
    internal var volumes: any VolumeAccess
    /// The program that sends files to the printer, with their paths as its arguments.
    internal var printer: URL
    /// Starts an application (main thread).
    internal var start: @MainActor @Sendable (URL) -> Void
    /// Opens files, or a folder, with an application (main thread).
    internal var open: @MainActor @Sendable ([URL], URL) -> Void
    /// Runs the print dialog of an operation, as a sheet of the program's main window when there is one (main
    /// thread).
    internal var print: @MainActor @Sendable (NSPrintOperation) -> Void
    /// Puts text on the clipboard (main thread).
    internal var copy: @MainActor @Sendable (String) -> Void
    /// Quits the program (main thread).
    internal var quit: @MainActor @Sendable () -> Void
    /// Minimizes the program's main window, the one the command came from (main thread).
    internal var minimize: @MainActor @Sendable () -> Void

    /// The print dialog, as a sheet of `window` or on its own.
    @MainActor
    private static func run(_ operation: NSPrintOperation, sheetOf window: NSWindow?) {
        guard let window else {
            _ = operation.run()
            return
        }
        operation.runModal(for: window, delegate: nil, didRun: nil, contextInfo: nil)
    }
}

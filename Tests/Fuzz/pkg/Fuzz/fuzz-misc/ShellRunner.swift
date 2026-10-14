import Foundation
import FuzzCore

@testable import ConfigurationPlugin

/// Runs lines in a real shell, exactly as the program hands a line to a shell.
@MainActor
internal enum ShellRunner {
    /// Marks the end of one case's arguments in the output.
    ///
    /// No generated name holds it.
    internal static let separator = "@@SEP-7f3a@@"

    /// How many lines ran so far; picks the folder of the next one.
    private static var runs = 0

    /// Runs the cases in one script: `ShellLine.script` for the text and the values, `ChildProcess.spawn`
    /// for the start.
    ///
    /// Each case is the pieces that follow `printf '%s\0' ` (or, with `external`, `/usr/bin/printf '%s\0' `:
    /// a program of its own, so that what a started program receives is checked too). A failure when the
    /// line was refused.
    internal static func run(
        _ shell: String,
        _ cases: [(pieces: [ExpandedPiece], external: Bool)]
    ) -> Result<ShellOutcome, ShellContext.Refusal> {
        var pieces: [ExpandedPiece] = [.text("exec >.out 2>/dev/null\n")]
        for one in cases {
            let command = (one.external ? "/usr/bin/printf" : "printf") + " '%s\\0' "
            pieces += [.text(command)] + one.pieces + [.text("\nprintf '%s\\0' \(separator)\n")]
        }
        switch ShellLine.script(pieces) {
        case .failure(let refusal):
            return .failure(refusal)

        case .success(let script):
            return .success(execute(shell, script))
        }
    }

    /// Starts the shell on the script in a fresh folder, waits for it, and reads what it left.
    private static func execute(_ shell: String, _ script: ShellScript) -> ShellOutcome {
        runs += 1
        let folder = fzWorkDir + "/shell-\(runs % 4)"
        try? FileManager.default.removeItem(atPath: folder)
        try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        // The shell's own start files are left out (`-f`, no login): they belong to whoever runs this.
        let options = shell.hasSuffix("zsh") ? ["-f", "-c"] : ["-c"]
        let environment = ["PATH": "/usr/bin:/bin", "HOME": folder, "LC_ALL": "en_US.UTF-8"]
        let started = ChildProcess.spawn(
            executable: shell,
            arguments: options + script.arguments,
            environment: environment,
            directory: folder
        )
        guard case .success(let pid) = started else {
            fzFail("quote-shell-not-started", shell)
        }
        var status: Int32 = 0
        var result: pid_t

        repeat {
            result = waitpid(pid, &status, 0)
        } while result == -1 && errno == EINTR
        return outcome(in: folder)
    }

    /// The arguments the script printed, per case, and the files that appeared in the folder.
    private static func outcome(in folder: String) -> ShellOutcome {
        let output = FileManager.default.contents(atPath: folder + "/.out").map { [UInt8]($0) } ?? []
        var arguments = output.split(separator: 0, omittingEmptySubsequences: false).map(Array.init)
        if arguments.last?.isEmpty == true {
            arguments.removeLast()
        }
        var groups = arguments.split(separator: Array(separator.utf8), omittingEmptySubsequences: false)
            .map(Array.init)
        if groups.last?.isEmpty == true {
            groups.removeLast()
        }
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? []
        let created = names.filter { $0 != ".out" }.sorted()
        return ShellOutcome(cases: groups, created: created)
    }
}

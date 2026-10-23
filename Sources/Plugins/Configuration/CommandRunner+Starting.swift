import AFMKernel
import Foundation

/// Starting a command once its parameters are expanded: the checks, the prompt, the list file.
extension CommandRunner {
    /// Whether the steps hand a line to the shell.
    private static func isExternal(_ steps: [CommandStep]) -> Bool {
        steps.contains { step in
            guard case .external = step else {
                return false
            }
            return true
        }
    }

    /// Writes a list file only the user can read, in a folder only the user can open.
    nonisolated private static func write(_ list: ListFile) throws {
        try FileManager.default.createDirectory(
            at: list.url.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        // The names of the user's files are for the started program alone.
        try list.contents.write(to: list.url)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: list.url.path)
    }

    /// Tells the user that the command was not run, and why.
    private func refuse(_ title: String, _ reason: String) {
        kernel.interaction.inform("“\(title)” was not run", detail: reason, style: .warning)
    }

    /// The line a shell is given for the external step of a command.
    internal func externalLine(_ command: String, parameters: [ExpandedPiece]) -> [ExpandedPiece] {
        let line = CommandLanguage.environmentPieces(command.trimmingCharacters(in: .whitespaces), environment)
        return parameters.isEmpty ? line : line + [.text(" ")] + parameters
    }

    /// Runs the steps of a request with its expanded parameters, unless they say it must not
    /// run or the user gives up at the prompt.
    internal func start(
        _ steps: [CommandStep],
        _ request: Request,
        expanded: ExpandedParameters,
        call: Call,
        completion: Completion?
    ) {
        guard call.generation == generation, mayRun(request, expanded) else {
            return
        }
        var pieces = expanded.pieces
        if !request.action.parameters.isEmpty, !request.arguments.isEmpty, !expanded.usedArguments {
            pieces = ParameterExpander.trimmed(pieces + [.text(" ")] + request.arguments)
        }
        if expanded.asksFirst {
            // Names a shell could read as something else are shown as references to them.
            let shown = ShellLine.prompt(pieces)
            guard
                let edited = kernel.interaction.prompt(
                    "Parameters for “\(request.title)”:",
                    value: shown.text,
                    detail: shown.legend
                )
            else { return }
            pieces = ShellLine.pieces(fromPrompt: edited, values: shown.values)
        }
        let isExternal = Self.isExternal(steps)
        guard !isExternal || accepts(pieces, of: request) else {
            return
        }
        let chain = Chain(
            isChain: steps.count > 1,
            parameters: pieces,
            command: request.action.command,
            startPath: request.action.startPath,
            listURL: expanded.listFile?.url,
            title: request.title,
            call: Call(
                names: call.names + (request.name.map { [$0] } ?? []),
                budget: call.budget,
                generation: call.generation
            )
        )
        perform(steps, chain, writing: expanded.listFile, isExternal: isExternal, then: completion)
    }

    /// Whether the expansion lets the command run; tells the user why not.
    private func mayRun(_ request: Request, _ expanded: ExpandedParameters) -> Bool {
        // A name code with no name stands for the folder (`rm -rf %P%N`): nothing is run.
        if expanded.missingName {
            kernel.interaction.inform(
                "“\(request.title)” needs a file",
                detail: "There is no file under the cursor, only the parent row or an empty list. "
                    + "The command was not run.",
                style: .warning
            )
            return false
        }
        if let problem = expanded.problem {
            refuse(request.title, problem)
            return false
        }
        return true
    }

    /// Whether the line for the shell can be made; tells the user why not.
    ///
    /// The line is checked before anything of the command runs. (A line with thousands of names
    /// is checked where it is started; a refusal is reported from there.)
    private func accepts(_ pieces: [ExpandedPiece], of request: Request) -> Bool {
        guard pieces.count <= Self.checkedHereLimit,
            case .failure(let refusal) = ShellLine.script(externalLine(request.action.command, parameters: pieces))
        else { return true }
        refuse(
            request.title,
            refusal.explanation
                + " A file name is handed to the shell as data, and that is not possible at this place of the line."
        )
        return false
    }

    /// Performs the steps, once the list file is written when there is one.
    private func perform(
        _ steps: [CommandStep],
        _ chain: Chain,
        writing list: ListFile?,
        isExternal: Bool,
        then completion: Completion?
    ) {
        // Weak: the list is written off the main thread, and the plugin may be gone when that is done.
        let grace = listGrace
        let listURL = chain.listURL
        let begin = { [weak self] in
            self?.perform(ArraySlice(steps), chain, then: completion)
            // Commands of the program have read the list by now; a started process removes it itself.
            if !isExternal { self?.removeListFile(listURL, after: grace) }
        }
        guard let list else {
            begin()
            return
        }
        onListQueue(
            { Result { try Self.write(list) } },
            then: { [weak self] result in
                if case .failure(let error) = result {
                    self?.kernel.interaction
                        .report(error, title: "The list of files for “\(chain.title)” could not be written")
                    return
                }
                begin()
            }
        )
    }
}

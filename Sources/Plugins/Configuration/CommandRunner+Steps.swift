import AFMContracts
import AFMKernel
import Dispatch

/// Performing the steps of a command one after the other, across waits.
extension CommandRunner {
    /// Runs the steps in the written order.
    ///
    /// A `cm_wait` hands the rest to a timer, so the main thread never sleeps; so does a program
    /// that later steps have to wait for. The chain carries the names of the commands it is inside
    /// of through every such wait.
    internal func perform(_ steps: ArraySlice<CommandStep>, _ chain: Chain, then done: Completion?) {
        guard chain.call.generation == generation else {
            return
        }
        let outer = active
        active = chain.call.names
        defer { active = outer }
        var rest = steps
        while let step = rest.popFirst() {
            guard counts(chain), perform(step, before: rest, chain, then: done) else {
                return
            }
        }
        done?()
    }

    /// Counts a step of the run; false, and the user told, when the run has taken all it may.
    private func counts(_ chain: Chain) -> Bool {
        chain.call.budget.steps += 1
        guard chain.call.budget.steps <= Self.stepLimit else {
            kernel.interaction.inform(
                "“\(chain.title)” was stopped",
                detail: "It ran \(Self.stepLimit) steps with the commands it calls, "
                    + "which looks like a loop. The remaining steps were not run.",
                style: .warning
            )
            return false
        }
        return true
    }

    /// Performs one step; false when the rest goes on later (after a wait or a program) or not at all.
    private func perform(
        _ step: CommandStep,
        before rest: ArraySlice<CommandStep>,
        _ chain: Chain,
        then done: Completion?
    ) -> Bool {
        switch step {
        case .wait(let milliseconds):
            wait(milliseconds, then: rest, chain, done)
            return false

        case .perform(let id, let written):
            return perform(id, written: written, before: rest, chain, then: done)

        case .changeDirectory(let path):
            changeDirectory(to: path, chain)
            return true

        case .external:
            // The next step of a chain (`em_build, cm_RereadSource`) runs when the program has ended.
            let waits = (!rest.isEmpty || done != nil) && launchesApplications
            launch(
                externalLine(chain.command, parameters: chain.parameters),
                chain,
                waits: waits
            ) { [weak self] started in
                guard started else {
                    return
                }
                self?.perform(rest, chain, then: done)
            }
            return !waits

        case .unknown(let command):
            kernel.interaction.inform(
                "Unknown command",
                detail: "No command is called \(DisplayText.oneLine(command, limit: 80)).",
                style: .warning
            )
            return true
        }
    }

    /// `cm_wait`: the rest of the steps runs after a timer.
    private func wait(
        _ milliseconds: Int,
        then rest: ArraySlice<CommandStep>,
        _ chain: Chain,
        _ done: Completion?
    ) {
        waiting += 1
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(milliseconds)) { [weak self] in
            // The steps after the wait may ask a question: not from inside a block of the main queue.
            MainLoop.perform {
                guard let self, chain.call.generation == self.generation else {
                    return
                }
                self.waiting -= 1
                self.perform(rest, chain, then: done)
            }
        }
    }

    /// A command of the program; false when it is a user command or a menu entry whose end the
    /// rest waits for.
    private func perform(
        _ id: CommandID,
        written: String,
        before rest: ArraySlice<CommandStep>,
        _ chain: Chain,
        then done: Completion?
    ) -> Bool {
        // A chained command takes only what is written after its name.
        let pieces: [ExpandedPiece] =
            chain.isChain || !written.isEmpty ? (written.isEmpty ? [] : [.text(written)]) : chain.parameters
        if let found = chained(id.rawValue, arguments: pieces) {
            // A user command or Start-menu entry is run here: what it starts is waited
            // for, and the values it is given stay values.
            run(found, call: chain.call) { [weak self] in
                self?.perform(rest, chain, then: done)
            }
            return false
        }
        let text = ShellLine.display(pieces)
        if id.rawValue.hasPrefix(UserCommand.prefix) {
            kernel.commands.perform(id, text.isEmpty ? .nothing : .text(text))
        } else {
            kernel.commands.perform(id, CommandLanguage.argument(from: text, location: location))
        }
        return true
    }

    /// `cd`: the folder written, or else the parameters; with a start path the other panel shows it
    /// (spec 14 › Start path).
    private func changeDirectory(to path: String, _ chain: Chain) {
        let folder = path.isEmpty ? ShellWords.unquoted(ShellLine.display(chain.parameters)) : path
        guard !folder.isEmpty else {
            return
        }
        kernel.commands.perform(.changeDirectory, .text(folder))
        if !chain.startPath.isEmpty { kernel.panels.target.show(location(chain.startPath)) }
    }

    /// What a command of a chain runs when it is a user command or a Start-menu entry, given
    /// `arguments`; nil for every other command.
    private func chained(_ id: String, arguments: [ExpandedPiece]) -> Request? {
        if id.hasPrefix(UserCommand.prefix), let found = userCommand?(id) {
            return Request(action: found.action, arguments: arguments, name: found.name, title: found.caption)
        }
        if let found = startMenuEntry?(id) {
            return Request(action: found.action, arguments: arguments, name: id, title: found.title)
        }
        return nil
    }
}

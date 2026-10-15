import AFMKernel
import Foundation

/// Commands that do nothing but note that they ran, and with what.
@MainActor
internal final class CovConfigProbes {
    /// The commands that ran, in order, with the text or the path they were given.
    private var runs: [(name: String, argument: String)] = []

    /// The names of the commands that ran, in order.
    internal var names: [String] { runs.map(\.name) }
    /// The same as `name:argument`, in order.
    internal var seen: [String] { runs.map { $0.name + ":" + $0.argument } }

    /// Registers a probe command under each of `names`, titled "Probe" and its name.
    internal init(_ names: [String], in commands: CommandRegistry) {
        for name in names {
            commands.register(Command(CommandID(rawValue: name), "Probe \(name)")) { [weak self] argument in
                self?.runs.append((name, argument.text ?? argument.location?.path ?? ""))
            }
        }
    }

    deinit {
        // Nothing to release.
    }
}

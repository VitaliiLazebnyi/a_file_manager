import AFMKernel

/// One thing a Command field asks for.
internal enum CommandStep: Equatable {
    /// `cd <path>`; an empty path stands for what the Parameters field holds.
    case changeDirectory(String)
    /// A program or shell line, handed to whoever runs command lines.
    case external(String)
    /// A command of the program with what was written after its name.
    case perform(CommandID, parameter: String)
    /// Looks like a command of the program but no plugin provides it.
    case unknown(String)
    /// `cm_wait <ms>`: a pause between two commands of a chain.
    case wait(milliseconds: Int)
}

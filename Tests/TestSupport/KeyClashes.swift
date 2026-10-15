public import AFMKernel

extension Kernel {
    /// The keys that more than one registered command brings as a default: the first of them
    /// keeps such a key, and the others go without. Empty when the plugins agree.
    public var keyClashes: [Shortcut] {
        var seen: Set<Shortcut> = []
        return commands.all.flatMap { Set($0.defaultShortcuts) }.filter { !seen.insert($0).inserted }
    }
}

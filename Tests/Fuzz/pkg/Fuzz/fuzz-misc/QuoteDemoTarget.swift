import FuzzCore

/// The `quote-demo` target: one name through every template of `quote` in zsh and sh.
///
/// The input's UTF-8 text is the cursor name, a marked name, a folder and the value of a variable.
/// Prints what arrived.
@MainActor
internal enum QuoteDemoTarget {
    /// The target.
    internal static func make() -> FuzzTarget {
        FuzzTarget("quote-demo", maxLen: 256, seeds: { seedTexts(["my file.txt"]) }, run: run)
    }

    /// Prints what the first templates delivered to `/usr/bin/printf`, then checks every case.
    private static func run(_ bytes: [UInt8]) {
        var name = text(bytes)
        name.unicodeScalars.removeAll { $0 == "/" || $0.value == 0 }
        guard !name.isEmpty else {
            return
        }
        let cases = QuoteCaseBuilder.cases(name: name, dir: name, value: name, selection: [name, "b c", name])
        for shell in ["/bin/zsh", "/bin/sh"] {
            let first = cases.prefix(3).map { (pieces: $0.pieces, external: true) }
            if case .success(let outcome) = ShellRunner.run(shell, first) {
                let arrived = outcome.cases.map(QuoteChecks.describeBytes)
                print(
                    "\(shell) %N, \"%N\", '%N' to /usr/bin/printf: \(arrived); files created: \(outcome.created)"
                )
            }
        }
        QuoteChecks.check(cases)
    }
}

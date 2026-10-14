import Foundation

/// The recorded limits, by machine and benchmark (`Tests/Benchmarks/limits.json`).
///
/// Times depend on the machine, so each kind of machine (model, cores, memory) has limits of its
/// own; a machine without any fails the run until they are recorded on it. A limit is the median
/// of the recorded runs plus a margin: half again for the time on the clock, which a busy
/// machine stretches, less for processor time and memory, which vary less.
internal struct Limits: Codable {
    /// The clock time may be this many times the recorded median.
    internal static let wallMargin = 1.5
    /// Processor time may be this many times the recorded median.
    internal static let cpuMargin = 1.3
    /// Memory may be this many times the recorded median.
    internal static let memoryMargin = 1.15
    /// Seconds added to both time limits, for work so short that a scheduling hiccup is a
    /// large part of it.
    internal static let wallAllowance = 0.05
    /// Megabytes added to the memory limit, for what the system and the runtime allocate.
    internal static let memoryAllowance = 32.0

    /// Limits by machine (`Machine.current`), then by benchmark.
    internal var machines: [String: [String: Measurement]]

    /// The limits in the file; none when it does not exist yet.
    internal static func read(from url: URL) throws -> Self {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return Self(machines: [:])
        }
        return try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
    }

    /// Writes the limits, sorted and indented, so that a change reads well in a diff.
    internal func write(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try (encoder.encode(self) + Data("\n".utf8)).write(to: url, options: .atomic)
    }
}

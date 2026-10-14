/// What the watchdog records: one answer, the statistics of a phase, a stall.
extension MainWatchdog {
    /// How the main thread answered one ping.
    internal struct Answer {
        /// When the ping was sent (`now()`).
        internal let sent: Double
        /// How long the answer took.
        internal let milliseconds: Double
        /// Processor time the main thread used meanwhile.
        internal let cpuMilliseconds: Double
    }

    /// What the watchdog has recorded so far.
    public struct Snapshot: Sendable {
        /// The phases in the order they began.
        public let order: [String]
        /// The statistics of each phase.
        public let stats: [String: Stats]
        /// Every stall.
        public let stalls: [Stall]
    }

    /// One answer later than 8 ms.
    public struct Stall: Sendable {
        /// When the ping that found the stall was sent, in seconds since the watchdog was made.
        public let sentAt: Double
        /// How long the main thread took to answer.
        public let milliseconds: Double
        /// Processor time the main thread used during the stall: near `milliseconds` when it was
        /// working, near zero when it was blocked or had no core.
        public let mainCPUMilliseconds: Double
        /// The phase the stall ended in.
        public let phase: String
        /// The main thread's stack at 100 ms and at 1 s, as far as they were taken.
        public let stacks: [[String]]
    }

    /// The answers of one phase.
    public struct Stats: Sendable {
        /// Pings answered.
        public var pings = 0
        /// Answers later than 8 ms.
        public var over8 = 0
        /// Answers later than 100 ms.
        public var over100 = 0
        /// Answers later than 1 s.
        public var over1000 = 0
        /// The latest answer, in milliseconds.
        public var maxMs = 0.0
        /// Processor time the main thread used during the latest answer.
        public var maxCPUMs = 0.0
        /// The milliseconds of all stalls together.
        public var stallMs = 0.0
        /// Processor time the main thread used during all stalls together.
        public var stallCPUMs = 0.0
        /// Answers per bucket of `MainWatchdog.bounds`.
        public var histogram = [Int](repeating: 0, count: MainWatchdog.bounds.count + 1)
        /// Seconds the phase lasted, up to its last end.
        public var wall = 0.0
        /// When the phase last began; 0 while it is not the current one.
        public var started = 0.0

        /// Counts one answer.
        internal mutating func count(_ answer: Answer) {
            let milliseconds = answer.milliseconds
            pings += 1
            if milliseconds > maxMs {
                maxMs = milliseconds
                maxCPUMs = answer.cpuMilliseconds
            }
            histogram[MainWatchdog.bounds.firstIndex { milliseconds < $0 } ?? MainWatchdog.bounds.count] += 1
            if milliseconds > 8 {
                stallMs += milliseconds
                stallCPUMs += answer.cpuMilliseconds
                over8 += 1
            }
            if milliseconds > 100 {
                over100 += 1
            }
            if milliseconds > 1_000 {
                over1000 += 1
            }
        }

        /// Adds the counts of `other` (the latest answer is the larger of the two).
        internal mutating func add(_ other: Self) {
            pings += other.pings
            over8 += other.over8
            over100 += other.over100
            over1000 += other.over1000
            maxMs = max(maxMs, other.maxMs)
            wall += other.wall
            stallMs += other.stallMs
            stallCPUMs += other.stallCPUMs
        }
    }
}

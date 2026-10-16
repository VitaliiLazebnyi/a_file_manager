import Darwin
import Testing

@testable import AFMShell

/// The program raises the number of files it may have open, once at start (`DescriptorLimit`).
///
/// Serialized: two of the tests set the limit of the test process itself.
@Suite(.serialized)
internal struct AppDescriptorLimitTests {
    /// No hard limit, as `getrlimit` reports it.
    private static let unlimited = rlim_t.max

    /// A limit as `getrlimit` gives it.
    private static func limit(_ soft: rlim_t, _ hard: rlim_t) -> rlimit {
        rlimit(rlim_cur: soft, rlim_max: hard)
    }

    /// A low limit with no hard limit above it goes up to what the program wants, the hard limit
    /// left as it was.
    @Test
    internal func aLowLimitIsRaisedToWhatIsWanted() {
        var asked: rlimit?
        let result = DescriptorLimit.raise(
            get: { Self.limit(256, Self.unlimited) },
            set: { limit in
                asked = limit
                return true
            }
        )
        #expect(result == DescriptorLimit.wanted)
        #expect(asked?.rlim_cur == DescriptorLimit.wanted)
        #expect(asked?.rlim_max == Self.unlimited)
    }

    /// A hard limit below what the program wants is as far as the limit goes.
    @Test
    internal func aLowerHardLimitIsAsFarAsItGoes() {
        var asked: rlimit?
        let result = DescriptorLimit.raise(
            get: { Self.limit(256, 1_000) },
            set: { limit in
                asked = limit
                return true
            }
        )
        #expect(result == 1_000)
        #expect(asked?.rlim_cur == 1_000)
    }

    /// A limit already as high as wanted is not touched, and never lowered.
    @Test
    internal func aLimitHighEnoughIsLeftAlone() {
        var askedToSet = false
        let result = DescriptorLimit.raise(
            get: { Self.limit(20_000, Self.unlimited) },
            set: { _ in
                askedToSet = true
                return true
            }
        )
        #expect(result == 20_000)
        #expect(!askedToSet)
    }

    /// When the system refuses, the limit the program had stays in force.
    @Test
    internal func aRefusedRaiseKeepsTheLimitItHad() {
        let result = DescriptorLimit.raise(get: { Self.limit(256, Self.unlimited) }, set: { _ in false })
        #expect(result == 256)
    }

    /// The system takes the limit a process has, and refuses a soft limit above the hard one.
    @Test
    internal func theSystemTakesAPossibleLimitAndRefusesAnImpossibleOne() {
        let now = DescriptorLimit.current()
        #expect(DescriptorLimit.apply(now))
        #expect(!DescriptorLimit.apply(Self.limit(Self.unlimited, 64)))
        #expect(DescriptorLimit.current().rlim_cur == now.rlim_cur)
    }

    /// The real limit of the test process, one below what the program wants, goes up to it; the
    /// limit the process had is put back afterwards (a step of one hurts no test running alongside).
    @Test
    internal func theProcessLimitIsRaisedForReal() throws {
        let now = DescriptorLimit.current()
        let target = min(DescriptorLimit.wanted, now.rlim_max)
        defer { _ = DescriptorLimit.apply(now) }
        try #require(DescriptorLimit.apply(Self.limit(target - 1, now.rlim_max)))
        #expect(DescriptorLimit.raise() == target)
        #expect(DescriptorLimit.current().rlim_cur == target)
    }
}

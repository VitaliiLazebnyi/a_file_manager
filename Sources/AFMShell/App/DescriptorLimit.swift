public import Darwin

/// The number of files the program may have open at once.
///
/// A program started from the Finder may open 256, and every watched folder costs a descriptor for
/// itself and each folder above it; with a few deep tabs, copies and listings run short. The
/// program raises the limit once at start, before anything opens files, to what the system allows.
public enum DescriptorLimit {
    /// What the program asks for: the most a process may set (`OPEN_MAX`), or less where the hard
    /// limit is lower.
    public static let wanted = rlim_t(OPEN_MAX)

    /// Raises the soft limit to `wanted`, or to the hard limit where that is lower.
    ///
    /// It never lowers the limit, and returns the limit in force afterwards.
    ///
    /// `get` and `set` stand for `getrlimit` and `setrlimit` of `RLIMIT_NOFILE` (the tests pass their
    /// own). When the system refuses, the limit stays as it was.
    @discardableResult
    public static func raise(
        get: () -> rlimit = Self.current,
        set: (rlimit) -> Bool = Self.apply
    ) -> rlim_t {
        var limit = get()
        let target = min(wanted, limit.rlim_max)
        guard limit.rlim_cur < target else {
            return limit.rlim_cur
        }
        let before = limit.rlim_cur
        limit.rlim_cur = target
        return set(limit) ? target : before
    }

    /// The limit of the process now.
    public static func current() -> rlimit {
        var limit = rlimit()
        // (Asking for a limit that exists does not fail.)
        getrlimit(RLIMIT_NOFILE, &limit)
        return limit
    }

    /// Sets the limit of the process; whether the system took it.
    public static func apply(_ limit: rlimit) -> Bool {
        var limit = limit
        return setrlimit(RLIMIT_NOFILE, &limit) == 0
    }
}

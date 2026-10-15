public import AFMKernel

/// What a test asks the registry about the kinds of declared settings keys.
extension SettingsKeyRegistry {
    /// What was declared for a key, read the way the settings export reads it: the key itself,
    /// else the longest family it belongs to; nil when nothing was said about it.
    public func kind(of key: String) -> SettingsKeyKind? {
        all.first { !$0.isPrefix && $0.key == key }?.kind
            ?? all.filter { $0.isPrefix && key.utf8.starts(with: $0.key.utf8) }
            .max { $0.key.utf8.count < $1.key.utf8.count }?
            .kind
    }
}

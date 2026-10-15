/// A store that forgets what was not used for a while without ever starting over: entries
/// live in two generations, the newer one filling up while the older is still looked at; when
/// the newer is full, the older is dropped and the newer takes its place. What is in use is
/// carried over as it is asked for, so it holds at most `limit` entries and a full store does
/// not mean that everything on screen is missing again.
internal struct TwoGenerationCache<Key: Hashable, Value> {
    /// The most entries the store holds.
    internal let limit: Int
    /// The newer generation, which takes what is stored and what is used.
    internal private(set) var recent: [Key: Value] = [:]
    /// The older generation, looked at until the newer one is full.
    internal private(set) var older: [Key: Value] = [:]

    /// An empty store of at most `limit` entries (two at the least).
    internal init(limit: Int) {
        self.limit = max(2, limit)
    }

    /// Puts a value into the newer generation, which becomes the older one first when it is full.
    private mutating func insert(_ value: Value, for key: Key) {
        if recent.count >= limit / 2, recent[key] == nil {
            older = recent
            recent = [:]
        }
        recent[key] = value
        older[key] = nil
    }

    /// The value of `key`, carried into the newer generation when it is found in the older;
    /// setting nil removes it.
    internal subscript(key: Key) -> Value? {
        mutating get {
            if let value = recent[key] {
                return value
            }
            guard let value = older.removeValue(forKey: key) else {
                return nil
            }
            insert(value, for: key)
            return value
        }
        set {
            if let newValue {
                insert(newValue, for: key)
            } else {
                (recent[key], older[key]) = (nil, nil)
            }
        }
    }
}

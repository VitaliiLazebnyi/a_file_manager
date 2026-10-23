import AFMKernel
import Foundation

/// What a search is asked for, what it goes through and how it runs.
extension ViewerSearch {
    /// What to find, from where, and which way.
    internal struct Request {
        /// What to find.
        internal let pattern: SearchPattern
        /// The offset the search starts at.
        internal let start: Int64
        /// Whether the search goes towards the start of the file: the last match that begins
        /// before `start` (else the next one that begins at or after it).
        internal let backwards: Bool
    }

    /// The text a search goes through.
    internal struct Subject {
        /// Where the bytes come from.
        internal let source: any ByteSource
        /// The bytes that are text (after a byte-order mark).
        internal let content: Range<Int64>
        /// The encoding the text is shown in.
        internal let encoding: ViewerEncoding
        /// What a text in a double-byte code page is cut into characters with; nil to make one.
        ///
        /// A search that is repeated keeps it between the calls.
        internal let boundaries: CharacterBoundaries?
    }

    /// How a search runs.
    internal struct Tuning {
        /// What the viewer uses: chunks of 1 MB, as many at once as there are cores, raw bytes
        /// where they do.
        internal static var standard: Self {
            Self(chunkSize: 1 << 20, parallelism: ProcessInfo.processInfo.activeProcessorCount, rawBytes: true)
        }

        /// The bytes of a chunk.
        internal var chunkSize: Int
        /// How many chunks are searched at once.
        internal var parallelism: Int
        /// Whether a text is searched for in the raw bytes where that gives the same answer; off
        /// decodes every chunk (the reference the raw searches are tested against).
        internal var rawBytes: Bool
    }

    /// What a search of one chunk needs besides the pattern.
    internal struct Context {
        /// Where the bytes come from.
        internal let source: any ByteSource
        /// The bytes that are text.
        internal let content: Range<Int64>
        /// The encoding of the text.
        internal let encoding: ViewerEncoding
        /// The flag that ends the search.
        internal let cancellation: CancellationFlag
        /// The character boundaries of a double-byte text; nil for any other.
        internal let boundaries: CharacterBoundaries?
        /// Whether raw searches may be used.
        internal let rawBytes: Bool
    }
}

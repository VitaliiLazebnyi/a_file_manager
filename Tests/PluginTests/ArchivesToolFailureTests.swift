import Foundation
import Testing

@testable import ArchivesPlugin

/// How the error of a system tool that failed reads.
@Suite
internal struct ArchivesToolFailureTests {
    /// What a tool wrote to its standard error is the message, without the blank lines around it.
    @Test
    internal func whatTheToolSaidIsTheMessage() {
        let error = Tool.failure("/usr/bin/bzip2", Data("\n  bzip2: Data integrity error  \n".utf8))
        #expect(error.errorDescription == ArchiveError.toolFailed("bzip2: Data integrity error").errorDescription)
    }

    /// A tool that wrote nothing that is UTF-8 is named as the one that failed.
    @Test
    internal func aToolThatSaidNothingReadableIsNamed() {
        let error = Tool.failure("/usr/bin/bzip2", Data([0xFF, 0xFE, 0x80]))
        #expect(error.errorDescription == ArchiveError.toolFailed("bzip2 failed.").errorDescription)
    }
}

import AFMKernel
import Foundation
import Testing

@testable import NetworkPlugin

/// A listing longer than any folder has is given up.
@Suite
internal struct CoverageNetworkListingLimit {
    /// A server that lists more entries than the limit gets an error, not a listing without end.
    @Test
    internal func aListingBeyondTheLimitIsGivenUp() throws {
        let data = Data(String(repeating: "type=file;size=1; a\r\n", count: FTPLimits.listingEntries + 100_000).utf8)
        let server = try CoverageNetworkServer(
            replies: [
                "FEAT": "211-Features:\r\n MLSD\r\n211 End",
                "MLSD": .act { line in line.transfer(data, verdict: "226 Done") }
            ]
        )
        let connection = try server.connected()
        defer { connection.close() }
        var received = 0
        let error = #expect(throws: NetworkError.self) {
            try connection.list("/", showHidden: false) { entries in
                received += entries.count
                return true
            }
        }
        #expect(CoverageNetworkServer.text(of: error)?.hasPrefix("a directory listing of more than") == true)
        #expect(received > FTPLimits.listingEntries && received < FTPLimits.listingEntries + 100_000)
    }
}

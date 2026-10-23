import Foundation
import Testing

@testable import VirtualFoldersPlugin

/// Locations in the virtual file system (review 2): no password, no dots.
@Suite
internal struct Review2ConfigBVirtualLocation {
    /// A password is never written into a branch location, not even encoded.
    @Test
    internal func aPasswordIsNeverWrittenIntoALocation() throws {
        let server = try #require(URL(string: "ftp://someone:s3cret@files.example.org/pub"))
        let url = VirtualLocation.branch(real: server).url
        #expect(!url.absoluteString.contains("s3cret"))
        let hostText = try #require(url.host)
        let hex = hostText.split(separator: ".")
            .dropFirst()
            .filter { $0.hasPrefix("h") }
            .map { $0.dropFirst() }
            .joined()
        let decoded = String(
            bytes: stride(from: 0, to: hex.count, by: 2)
                .compactMap { index -> UInt8? in
                    let start = hex.index(hex.startIndex, offsetBy: index)
                    return UInt8(hex[start..<hex.index(start, offsetBy: 2)], radix: 16)
                },
            encoding: .utf8
        )
        #expect(decoded?.contains("s3cret") == false)
        #expect(VirtualLocation(url)?.realDirectory?.user == "someone")
    }

    /// A path with `.` and `..` in it is made plain.
    @Test
    internal func aPathWithDotsInItIsMadePlain() throws {
        let hand = try #require(URL(string: "vfolder://branch.h66696c653a2f2f/a/../../etc"))
        guard case .branch(let real)? = VirtualLocation(hand) else {
            Issue.record("not a branch")
            return
        }
        #expect(real.path == "/etc")
        #expect(VirtualLocation.plain("/a/./b//c/..") == "/a/b")
    }
}

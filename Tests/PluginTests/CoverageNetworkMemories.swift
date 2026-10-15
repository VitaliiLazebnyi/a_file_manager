import AFMKernel
import Foundation
import Testing

@testable import NetworkPlugin

/// What a session remembers of a server, and how names are read.
@Suite
internal struct CoverageNetworkMemories {
    /// The memories start afresh when they are full.
    @Test
    internal func theMemoriesStartAfreshWhenTheyAreFull() {
        let links = LinkMemory()
        for index in 0...2_048 {
            links.remember("/\(index)", isDirectory: true)
        }
        #expect(links.isDirectory("/0") == nil && links.isDirectory("/2048") == true)
        let names = NameMemory()
        for index in 0...65_536 {
            names.remember("n\(index)", encoding: .isoLatin1)
        }
        #expect(names.encoding(of: Array("n0".utf8)) == nil && names.encoding(of: Array("n65536".utf8)) == .isoLatin1)
    }

    /// Every encoding has a system encoding.
    @Test
    internal func everyEncodingHasASystemEncoding() {
        for encoding in NameEncoding.allCases where encoding != .automatic {
            #expect(encoding.encoding != nil, "\(encoding.title)")
        }
        // Bytes that are not UTF-8 are read as Western Latin 1 in the automatic mode.
        #expect(NameEncoding.automatic.decodeTelling(Data([0x63, 0xE9])) == ("c\u{E9}", .windowsCP1252))
    }
}

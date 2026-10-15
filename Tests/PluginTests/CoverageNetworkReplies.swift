import AFMKernel
import Foundation
import Testing

@testable import NetworkPlugin

/// Replies and their syntax: the cases no server of the other tests sends.
@Suite
internal struct CoverageNetworkReplies {
    /// A reply without text is shown as its code.
    @Test
    internal func aReplyWithoutTextIsShownAsItsCode() {
        #expect(FTPReply(code: 200, lines: []).message == "200 ")
    }

    /// The last piece loses its carriage return.
    @Test
    internal func theLastPieceLosesItsCarriageReturn() {
        var splitter = LineSplitter()
        #expect(splitter.feed(Data("one\r\ntwo\r".utf8)) == [Data("one".utf8)])
        #expect(splitter.finish() == Data("two".utf8))
        #expect(splitter.finish() == nil)
    }

    /// Extended passive replies without a port are refused.
    @Test
    internal func extendedPassiveRepliesWithoutAPortAreRefused() {
        #expect(FTPSyntax.extendedPassivePort("229 Entering Extended Passive Mode ()") == nil)
        #expect(FTPSyntax.extendedPassivePort("229 (|||6446|)") == 6_446)
    }

    /// Passive replies with a huge number or port zero are refused.
    @Test
    internal func passiveRepliesWithAHugeNumberOrPortZeroAreRefused() {
        #expect(FTPSyntax.passiveEndpoint("227 (1,2,3,4,99999999999999999999999,1)") == nil)
        #expect(FTPSyntax.passiveEndpoint("227 (1,2,3,4,0,0)") == nil)
        #expect(FTPSyntax.passiveEndpoint("227 (1,2,3,4,0,21)")?.port == 21)
    }

    /// Empty feature lines are skipped.
    @Test
    internal func emptyFeatureLinesAreSkipped() {
        let reply = FTPReply(code: 211, lines: ["Features:", "  ", " MLST type*;", "End"])
        #expect(FTPSyntax.features(reply) == ["MLST": "type*;"])
    }

    /// Times are read and written in u t c.
    @Test
    internal func timesAreReadAndWrittenInUTC() {
        let date = FTPSyntax.time("20240102030405.123")
        #expect(date == Date(timeIntervalSince1970: 1_704_164_645))
        #expect(date.map(FTPSyntax.timeText) == "20240102030405")
        #expect(FTPSyntax.time("2024010203040x") == nil)
    }
}

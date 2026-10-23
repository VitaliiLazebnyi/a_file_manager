import AFMKernel
import Foundation
import Testing

@testable import NetworkPlugin

/// FTP replies: lines put together into replies, and the parts read out of their text.
@Suite
internal struct NetworkReplyParserTests {
    /// Single and multi-line replies are put together, with their kind; a FEAT reply gives the features.
    @Test
    internal func replies() {
        var parser = FTPReplyParser()
        #expect(parser.feed("220 Welcome") == FTPReply(code: 220, lines: ["Welcome"]))
        #expect(parser.feed("230-First line") == nil)
        #expect(parser.feed(" indented text") == nil)
        #expect(parser.feed("230-Second") == nil)
        #expect(parser.feed("123 a number inside") == nil)
        let reply = parser.feed("230 Logged in")
        #expect(
            reply
                == FTPReply(
                    code: 230,
                    lines: ["First line", " indented text", "Second", "123 a number inside", "Logged in"]
                )
        )
        #expect(reply?.isSuccess == true && reply?.message == "230 Logged in")
        #expect(parser.feed("226") == FTPReply(code: 226, lines: [""]))
        #expect(parser.feed("garbage") == nil && parser.feed("") == nil)
        #expect(FTPReply(code: 150, lines: []).isPreliminary && FTPReply(code: 331, lines: []).isIntermediate)

        var featureParser = FTPReplyParser()
        var features: [String: String] = [:]
        for line in ["211-Features:", " MDTM", " MLST type*;size*;modify*;", " REST STREAM", " UTF8", "211 End"] {
            if let featureReply = featureParser.feed(line) {
                features = FTPSyntax.features(featureReply)
            }
        }
        #expect(features == ["MDTM": "", "MLST": "type*;size*;modify*;", "REST": "STREAM", "UTF8": ""])
    }

    /// Passive ports and endpoints, PORT and EPRT arguments, quoted paths, times and start commands are
    /// read and written as the RFCs say.
    @Test
    internal func replySyntax() {
        #expect(FTPSyntax.extendedPassivePort("Entering Extended Passive Mode (|||6446|)") == 6_446)
        #expect(FTPSyntax.extendedPassivePort("Extended (!!!50000!) ok") == 50_000)
        #expect(FTPSyntax.extendedPassivePort("Entering Extended Passive Mode") == nil)
        #expect(FTPSyntax.extendedPassivePort("(|||99999|)") == nil)
        var endpoint = FTPSyntax.passiveEndpoint("Entering Passive Mode (192,168,1,20,19,137).")
        #expect(endpoint?.host == "192.168.1.20" && endpoint?.port == 19 * 256 + 137)
        endpoint = FTPSyntax.passiveEndpoint("Entering Passive Mode 10,0,0,5,200,1")
        #expect(endpoint?.host == "10.0.0.5" && endpoint?.port == 51_201)
        #expect(FTPSyntax.passiveEndpoint("Entering Passive Mode (1,2,3,4,5)") == nil)
        #expect(FTPSyntax.passiveEndpoint("Entering Passive Mode (1,2,3,400,5,6)") == nil)
        #expect(FTPSyntax.portArgument(host: "127.0.0.1", port: 51_201) == "127,0,0,1,200,1")
        #expect(FTPSyntax.portArgument(host: "::1", port: 80) == nil)
        #expect(FTPSyntax.extendedPortArgument(host: "::1", port: 5_282) == "|2|::1|5282|")
        #expect(FTPSyntax.extendedPortArgument(host: "10.0.0.1", port: 21) == "|1|10.0.0.1|21|")
        #expect(FTPSyntax.quotedPath("\"/home/user\" is the current directory") == "/home/user")
        #expect(FTPSyntax.quotedPath("\"/a \"\"quoted\"\" name\" created") == "/a \"quoted\" name")
        #expect(FTPSyntax.quotedPath("no quotes") == nil && FTPSyntax.quotedPath("\"unfinished") == nil)
        let time = ListingClock.time(2_026, 10, 11, 3, 50) + 43
        #expect(FTPSyntax.time("20261011035043") == time && FTPSyntax.time("20261011035043.999") == time)
        #expect(FTPSyntax.time("2026101103") == nil && FTPSyntax.timeText(time) == "20261011035043")
        #expect(
            FTPServerConfig.initCommands(from: "CWD /test/a;;b;;c;PWD; ;SITE X") == [
                "CWD /test/a;b;c", "PWD", "SITE X"
            ]
        )
    }
}

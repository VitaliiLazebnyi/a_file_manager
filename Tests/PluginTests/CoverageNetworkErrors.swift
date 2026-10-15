import AFMKernel
import Foundation
import Testing

@testable import NetworkPlugin

/// The messages the user reads for each failure.
@Suite
internal struct CoverageNetworkErrors {
    /// Every failure has a sentence.
    @Test
    internal func everyFailureHasASentence() {
        let reply = FTPReply(code: 550, lines: ["No such file"])
        let certificate = CertificateInfo(fingerprint: "AB", subject: "host", problem: "It expired.")
        let messages: [(NetworkError, String)] = [
            (.timedOut("reading"), "The server did not answer in time (reading)."),
            (.connectionLost, "The connection to the server was lost."),
            (.cancelled, "The operation was cancelled."),
            (.refused(reply), "The server answered: 550 No such file"),
            (.untrustedCertificate(certificate), "The server's certificate is not trusted: It expired."),
            (.unexpected("a riddle"), "Unexpected answer from the server: a riddle"),
            (.notConnected("ftp://host"), "There is no connection to ftp://host."),
            (.incomplete("Half of it is there."), "Half of it is there.")
        ]
        for (error, message) in messages {
            #expect(error.errorDescription == message)
        }
    }
}

import Foundation
import TestSupport

@testable import NetworkPlugin

/// An SFTP server written for these tests, run by the Python that comes with the developer
/// tools.
///
/// Unlike the system's `sftp-server` it can be made to behave badly: every answer comes after a
/// random delay (so answers arrive out of order), reads are cut short, reads fail from some
/// position on, a request is never answered, or nothing is read from the pipe at all. Unchecked:
/// set up in `init` and not changed afterwards.
internal final class FakeSFTPServer: @unchecked Sendable {
    /// How the server misbehaves; the raw value is the script's first argument.
    internal enum Mode: String {
        /// Every request is answered, after its delay; some reads are shorter than asked for.
        case normal = "normal"
        /// Reads at or behind 98304 answer with a failure.
        case failingReads = "failread"
        /// A stat of a path ending in `hang` is never answered.
        case hangingStat = "hang"
        /// Answers the first packet and then reads no more.
        case stalled = "stall"
        /// Opening a directory, reads from 98304 on and every write are never answered, nor is a stat of `hang`.
        case hangingIO = "hangio"
        /// Closing a handle that was written to answers with a failure (a full disk that shows at the end).
        case failingClose = "failclose"
        /// The write at 65536 is refused; the writes before and after it are carried out.
        case failingWrite = "failwrite"
        /// Every write is confirmed, but nothing behind 65536 is stored.
        case forgetfulWrite = "forgetwrite"
        /// A plain rename onto an existing name is refused, and so is every rename of a name ending in `locked`.
        case strictRename = "strictrename"
        /// Where a link leads (a stat that follows it) is never told for a name ending in `hang`, refused for one
        /// ending in `deny`, and asking about one ending in `die` ends the server.
        case links = "links"
        /// Reading a directory closes the server's input before the answer: what the client sends next finds
        /// nobody reading.
        case cutListing = "cutlisting"
        /// The length of an open file is not told.
        case noSize = "nosize"
        /// A read is answered with more bytes than were asked for.
        case overlong = "overlong"
        /// A read is answered with no bytes and no end of file.
        case emptyData = "emptydata"
        /// No read is answered with more than 1,000 bytes; the length of every read asked for goes to
        /// `sftp-reads.log`.
        case shortReads = "shortreads"
        /// The answer to the first question after the greeting is too short to name its request.
        case shortPacket = "shortpacket"
    }

    /// The Python that runs the script, the one the developer tools put there.
    internal static let python = "/usr/bin/python3"
    /// True when the Python is there; the suites that use the server are skipped otherwise.
    internal static var isAvailable: Bool { FileManager.default.isExecutableFile(atPath: python) }

    /// The transport an SFTP session starts the server with.
    internal let transport: SFTPTransport

    /// A server on the folder that answers each request after 20 to 60 milliseconds.
    internal convenience init(root: URL, box: Sandbox, mode: Mode) throws {
        try self.init(root: root, box: box, mode: mode, delay: 20...60)
    }

    /// Writes the script into the sandbox; the server serves `root` and answers each request after a delay in
    /// milliseconds picked from `delay`.
    internal init(root: URL, box: Sandbox, mode: Mode, delay: ClosedRange<Int>) throws {
        let scriptFile = box.url("fake-sftp.py")
        try Self.script.write(to: scriptFile, atomically: true, encoding: .utf8)
        transport = SFTPTransport(
            executable: Self.python,
            arguments: [scriptFile.path, mode.rawValue, root.path, String(delay.lowerBound), String(delay.upperBound)]
        )
    }

    deinit {
        // Nothing to release: each session ends the server process it started.
    }
}

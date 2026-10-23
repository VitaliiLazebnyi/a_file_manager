import AFMKernel
import Foundation
import TestSupport
import Testing

@testable import NetworkPlugin

/// Names from a server are one path component, whatever the server says (a name with a slash
/// would put a downloaded file outside the folder the user chose).
@Suite
internal struct NetworkFixNames {
    /// Ordinary names, also ones of dots only or with a backslash, are safe; empty names, `.`, `..`,
    /// names with a slash or a NUL are not, and a DOS name may not hold a backslash.
    @Test
    internal func theSharedCheck() {
        #expect(RemoteEntry.isSafeName("report.txt"))
        #expect(RemoteEntry.isSafeName("..."))
        #expect(RemoteEntry.isSafeName(".hidden"))
        #expect(RemoteEntry.isSafeName("a\\b"))
        for bad in ["", ".", "..", "../x", "a/b", "/etc/passwd", "x/", "a\0b", "../../Library/LaunchAgents/x.plist"] {
            #expect(!RemoteEntry.isSafeName(bad), "\(bad)")
        }
        #expect(!RemoteEntry.isSafeDOSName("a\\b"))
    }

    /// MLSD lines with an unsafe name give no entry; MLST keeps the last name of the path, unless it is `..`.
    @Test
    internal func mlsdAndMlstDropThem() {
        #expect(FTPListParser.mlsd("type=file;size=1; ../../x.plist") == nil)
        #expect(FTPListParser.mlsd("type=file;size=1; sub/x") == nil)
        #expect(FTPListParser.mlsd("type=file;size=1; nul\0x") == nil)
        #expect(FTPListParser.mlsd("type=file;size=1; fine.txt")?.name == "fine.txt")
        // MLST names a whole path, of which the last name is kept.
        #expect(FTPListParser.mlst(" type=file;size=1; /pub/fine.txt")?.name == "fine.txt")
        #expect(FTPListParser.mlst(" type=file;size=1; /pub/..") == nil)
    }

    /// Unix, DOS and EPLF lines with an unsafe name give no entry, and a link is judged by its own name.
    @Test
    internal func listDropsThemInEveryFormat() {
        let unix = "-rw-r--r--   1 owner    group          12 Jan 31  2024 "
        #expect(FTPListParser.list(unix + "../../Library/x.plist") == nil)
        #expect(FTPListParser.list(unix + "a/b") == nil)
        #expect(FTPListParser.list(unix + "ok.txt")?.name == "ok.txt")
        // A backslash is an ordinary character in a Unix name.
        #expect(FTPListParser.list(unix + "a\\b")?.name == "a\\b")
        // A link whose own name is not safe.
        #expect(FTPListParser.list("lrwxrwxrwx   1 owner    group          12 Jan 31  2024 ../l -> target") == nil)
        #expect(
            FTPListParser.list("lrwxrwxrwx   1 owner    group          12 Jan 31  2024 l -> ../target")?.name == "l"
        )

        let dos = "01-31-24  03:04PM              1,234 "
        #expect(FTPListParser.list(dos + "..\\..\\evil.exe") == nil)
        #expect(FTPListParser.list(dos + "sub\\evil.exe") == nil)
        #expect(FTPListParser.list(dos + "../evil.exe") == nil)
        #expect(FTPListParser.list(dos + "ok.exe")?.name == "ok.exe")
        #expect(FTPListParser.list("01-31-24  03:04PM       <DIR>          ..\\up") == nil)

        #expect(FTPListParser.list("+i8388621.29609,m824255902,/,\t../../dev") == nil)
        #expect(FTPListParser.list("+i8388621.29609,m824255902,/,\ta/b") == nil)
        #expect(FTPListParser.list("+i8388621.29609,m824255902,/,\tdev")?.name == "dev")
    }

    /// A listing from the server keeps only the safe names, and every URL stays directly below the folder.
    @Test(arguments: [true, false])
    internal func aListingFromAServerKeepsOnlyTheSafeNames(mlsd: Bool) throws {
        var options = TestFTPServer.Options()
        options.offersMLSD = mlsd
        options.injectedLines =
            mlsd
            ? ["type=file;size=3; ../../evil", "type=file;size=3; a/b", "type=file;size=3; injected.txt"]
            : [
                "-rw-r--r--   1 o g 3 Jan 01  2020 ../../evil", "-rw-r--r--   1 o g 3 Jan 01  2020 a/b",
                "-rw-r--r--   1 o g 3 Jan 01  2020 injected.txt"
            ]
        let fixture = try FTPFixture(options)
        try fixture.box.file("srv/real.txt", "r")
        let items = try fixture.fileSystem.list(fixture.url("/"), showHidden: true)
        #expect(items.map(\.name).sorted() == ["injected.txt", "real.txt"])
        // Every URL stays directly below the listed folder.
        #expect(items.allSatisfy { $0.url.deletingLastPathComponent().path == "/" })
    }

    /// The SFTP listing uses the same check, which refuses `../x` and `a/b`.
    @Test
    internal func theSFTPListingCheckIsTheSameFunction() {
        // The SFTP loop filters with `RemoteEntry.isSafeName`; the system's server cannot
        // be made to send such a name, so the rule itself is what is tested above.
        #expect(!RemoteEntry.isSafeName("../x") && !RemoteEntry.isSafeName("a/b"))
    }
}

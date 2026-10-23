import AFMKernel
import Foundation
import TestSupport
import Testing

@testable import VirtualFoldersPlugin

/// The `vfolder:` URLs: what they carry and what is not one.
@Suite
internal struct VirtualLocations {
    /// A branch location has the real directory's path and comes back the same, however it is written.
    @Test
    internal func aBranchLocationCarriesItsRealDirectory() throws {
        let real = URL(fileURLWithPath: "/Users/x/My Files/dir")
        let url = VirtualLocation.branch(real: real).url
        #expect(url.scheme == "vfolder" && url.lastPathComponent == "dir" && url.path == "/Users/x/My Files/dir")
        #expect(VirtualLocation(url) == .branch(real: real))
        #expect(VirtualLocation(url.standardized) == .branch(real: real))
        #expect(VirtualLocation(try #require(URL(string: url.absoluteString))) == .branch(real: real))
    }

    /// The scheme, user, host and port of a real location survive the round trip, also when long.
    @Test
    internal func otherFileSystemsHostsAndPortsSurvive() throws {
        let memory = MemoryFileSystem()
        #expect(
            VirtualLocation(VirtualLocation.branch(real: memory.url("/A/docs")).url)
                == .branch(real: memory.url("/A/docs"))
        )
        let server = try #require(URL(string: "sftp://someone@files.example.org:2222/srv/www/a%20b"))
        let back = VirtualLocation(VirtualLocation.picked(id: 12, real: server).url)
        guard case .picked(12, let real)? = back else {
            Issue.record("not a picked branch: \(String(describing: back))")
            return
        }
        #expect(real.absoluteString == server.absoluteString)
        // A long prefix is cut into host labels of a legal length.
        let long = try #require(URL(string: "sftp://\(String(repeating: "u", count: 70))@host.example.org/x"))
        let host = try #require(VirtualLocation.branch(real: long).url.host)
        #expect(host.split(separator: ".").allSatisfy { $0.count <= 63 })
        #expect(
            VirtualLocation(VirtualLocation.branch(real: long).url)?.realDirectory?.absoluteString
                == long.absoluteString
        )
    }

    /// A list location keeps its id, its title and the folder it was opened from, the root included.
    @Test
    internal func aListLocationKnowsItsTitleAndWhereItCameFrom() throws {
        let origin = URL(fileURLWithPath: "/Users/x")
        let url = VirtualLocation.list(id: 7, title: "Search result", origin: origin).url
        #expect(url.lastPathComponent == "Search result")
        #expect(VirtualLocation(url) == .list(id: 7, title: "Search result", origin: origin))
        let rootless = VirtualLocation.list(id: 8, title: "Found", origin: nil)
        #expect(VirtualLocation(rootless.url) == rootless && rootless.realDirectory == nil)
        let atRoot = VirtualLocation.list(id: 9, title: "Found", origin: URL(fileURLWithPath: "/"))
        #expect(VirtualLocation(atRoot.url)?.realDirectory?.path == "/")
        // A list written without a title has the root for one, as a path has.
        let untitled = try #require(URL(string: "vfolder://list.n5"))
        #expect(VirtualLocation(untitled) == .list(id: 5, title: "/", origin: nil))
        #expect(VirtualLocation.pathComponent("a/b") == "a:b" && VirtualLocation.pathComponent(" ") == "List")
    }

    /// Other schemes, unknown kinds, broken hex and a list without a number are no virtual location.
    @Test
    internal func foreignAndBrokenLocationsAreNotVirtual() throws {
        #expect(VirtualLocation(URL(fileURLWithPath: "/tmp")) == nil)
        #expect(VirtualLocation(try #require(URL(string: "vfolder://nonsense/x"))) == nil)
        #expect(VirtualLocation(try #require(URL(string: "vfolder://pick.hzz/x"))) == nil)
        #expect(VirtualLocation(try #require(URL(string: "vfolder://list/x"))) == nil)
    }
}

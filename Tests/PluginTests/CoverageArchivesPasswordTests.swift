import AFMKernel
import Foundation
import TestSupport
import Testing

@testable import ArchivesPlugin

/// Encrypted and unusual ZIP members: which passwords are tried and kept, which are forgotten,
/// and what cannot be read at all.
@Suite
internal struct CoverageArchivesPasswordTests {
    private let bench: ArchiveBench
    private var box: Sandbox { bench.box }

    /// A bench of its own for each test.
    internal init() throws {
        bench = try ArchiveBench()
    }

    /// Reads a whole member.
    private static func readFully(_ archive: OpenArchive, _ path: String) throws -> Data {
        let entry = try #require(archive.entry(path))
        let stream = try archive.open(entry)
        defer { stream.close() }
        return try stream.readFully(1 << 20)
    }

    /// The state of a thread: true while it waits (for a lock, here).
    private static func isWaiting(_ thread: mach_port_t) -> Bool {
        var info = thread_basic_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<thread_basic_info_data_t>.size / MemoryLayout<integer_t>.size)
        let status = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { fields in
                thread_info(thread, thread_flavor_t(THREAD_BASIC_INFO), fields, &count)
            }
        }
        return status == KERN_SUCCESS && info.run_state == TH_STATE_WAITING
    }

    private func read(_ archive: OpenArchive, _ path: String) throws -> Data {
        try Self.readFully(archive, path)
    }

    /// Whether `password` passes the two bytes that check the password of an AES member, as
    /// one wrong password in 65 536 does.
    private func passesTheCheck(_ password: String, _ archive: OpenArchive, _ path: String) throws -> Bool {
        let entry = try #require(archive.entry(path))
        guard case .zip(let record) = entry.content, case .archive(let offset, let file) = record.source,
            let field = record.aes
        else {
            Issue.record("\(path) is no AES member in the archive file")
            return true
        }
        let start = try ZipDirectory.localHeader(of: record, at: offset, in: file).dataOffset
        let head = try file.read(at: start, count: field.saltLength + ZipAES.verifierLength)
        let cipher = try ZipAES.Cipher(
            password: password,
            salt: head.prefix(field.saltLength),
            keyLength: field.keyLength
        )
        return cipher.verifier == head.suffix(ZipAES.verifierLength)
    }

    /// A ZIP of AES members (each holding its own name) written by the plugin, opened afresh;
    /// made again until no member's check lets another's password or one of `refused` pass.
    private func encrypted(_ members: [(name: String, password: String)], refused: [String]) throws -> OpenArchive {
        while true {
            try? FileManager.default.removeItem(at: box.url("aes.zip"))
            _ = try CoverageArchives.zip("aes.zip", in: box, ["stub.txt": "stub"], options: [])
            let archive = try bench.store.archive(at: box.url("aes.zip"))
            try archive.remove("stub.txt")
            for member in members {
                let writer = try archive.write(member.name, password: member.password)
                try writer.write(Data(member.name.utf8))
                try writer.close(attributes: FileAttributes())
            }
            try archive.commit()
            bench.store.close()
            let reopened = try bench.store.archive(at: box.url("aes.zip"))
            var clean = true
            for member in members {
                let others = members.map(\.password).filter { $0 != member.password } + refused
                for password in others {
                    clean = try clean && !passesTheCheck(password, reopened, member.name)
                }
            }
            if clean {
                return reopened
            }
            bench.store.close()
        }
    }

    /// Flips a byte of the data of the first member of a ZIP, `into` bytes behind its header.
    private func damageFirstMember(of url: URL, into offset: Int) throws {
        var bytes = try Data(contentsOf: url)
        let nameLength = Int(bytes[26]) | Int(bytes[27]) << 8
        let extraLength = Int(bytes[28]) | Int(bytes[29]) << 8
        bytes[30 + nameLength + extraLength + offset] ^= 0x55
        try bytes.write(to: url)
    }

    /// Checks that a password that opened one member is tried first for the next, and that the
    /// user is asked when it does not fit; a wrong answer is asked again.
    @Test
    internal func eachMemberGetsThePasswordThatFitsIt() throws {
        let archive = try encrypted(
            [(name: "one.txt", password: "first"), (name: "two.txt", password: "second")],
            refused: ["wrong"]
        )
        bench.passwords.set(["first", "wrong", "second"])
        #expect(try read(archive, "one.txt") == Data("one.txt".utf8))
        #expect(try read(archive, "two.txt") == Data("two.txt".utf8))
        #expect(bench.passwords.asked == 3)
        // Both are known now.
        #expect(try read(archive, "one.txt") == Data("one.txt".utf8) && bench.passwords.asked == 3)
    }

    /// Checks that no more than eight passwords are kept: the oldest goes.
    @Test
    internal func onlyTheLatestEightPasswordsAreKept() throws {
        let members = (0..<9).map { (name: "member\($0).txt", password: "password \($0)") }
        let archive = try encrypted(members, refused: [])
        bench.passwords.set(members.map(\.password))
        for member in members {
            #expect(try read(archive, member.name) == Data(member.name.utf8))
        }
        #expect(bench.passwords.asked == 9)
        // The first one's password was let go; the last one's is kept.
        #expect(try read(archive, members[8].name) == Data(members[8].name.utf8) && bench.passwords.asked == 9)
        #expect(throws: ArchiveError.self) { try read(archive, members[0].name) }
        #expect(bench.passwords.asked == 10)
    }

    /// Checks that passwords handed over by a caller are tried first, and that they can all be forgotten.
    @Test
    internal func passwordsGivenByACallerAreTriedFirstAndCanBeForgotten() throws {
        let archive = try encrypted([(name: "one.txt", password: "known")], refused: ["other"])
        archive.usePassword("other")
        archive.usePassword("known")
        archive.usePassword("other")
        #expect(try read(archive, "one.txt") == Data("one.txt".utf8) && bench.passwords.asked == 0)
        archive.usePassword(nil)
        #expect(throws: ArchiveError.self) { try read(archive, "one.txt") }
        #expect(bench.passwords.asked == 1)
    }

    /// Checks that a password whose member then fails its checksum (old encryption) is not kept.
    @Test
    internal func aPasswordThatYieldsAWrongChecksumIsForgotten() throws {
        try box.file("plain.txt", String(repeating: "stored text ", count: 100))
        #expect(runTool("/usr/bin/zip", ["-q0", "-P", "pw", "old.zip", "plain.txt"], in: box.root).status == 0)
        try damageFirstMember(of: box.url("old.zip"), into: 12 + 600)
        let archive = try bench.store.archive(at: box.url("old.zip"))
        bench.passwords.set(["pw", "pw"])
        #expect(throws: (any Error).self) { try read(archive, "plain.txt") }
        #expect(throws: (any Error).self) { try read(archive, "plain.txt") }
        #expect(bench.passwords.asked == 2)
    }

    /// Checks that a password whose AES member then fails its authentication is not kept;
    /// the member is written stored, as asked.
    @Test
    internal func aPasswordThatFailsTheAuthenticationIsForgotten() throws {
        try box.file("stub.txt", "stub")
        #expect(runTool("/usr/bin/zip", ["-q", "aes.zip", "stub.txt"], in: box.root).status == 0)
        let archive = try bench.store.archive(at: box.url("aes.zip"))
        try archive.remove("stub.txt")
        let writer = try archive.write("secret.txt", level: 0, password: "pw")
        try writer.write(Data(String(repeating: "secret ", count: 200).utf8))
        try writer.close(attributes: FileAttributes())
        try archive.commit()
        bench.store.close()
        try damageFirstMember(of: box.url("aes.zip"), into: 18 + 700)
        let reopened = try bench.store.archive(at: box.url("aes.zip"))
        let entry = try #require(reopened.entry("secret.txt"))
        guard case .zip(let record) = entry.content else {
            Issue.record("not a ZIP member")
            return
        }
        #expect(record.aes?.method == ZipRecord.methodStored)
        bench.passwords.set(["pw", "pw"])
        #expect(throws: (any Error).self) { try read(reopened, "secret.txt") }
        #expect(throws: (any Error).self) { try read(reopened, "secret.txt") }
        #expect(bench.passwords.asked == 2)
    }

    /// Checks that members the plugin cannot unpack say why: an AES member without its field,
    /// a compression method it does not know.
    @Test
    internal func membersThatCannotBeUnpackedSayWhy() throws {
        let url = box.url("odd.zip")
        try CoverageArchives.craft(url, [(name: "aes.bin", data: Data("x".utf8))], localExtra: nil) { record in
            record.method = ZipAES.method
        }
        let odd = try bench.store.archive(at: url)
        #expect {
            _ = try read(odd, "aes.bin")
        } throws: { error in
            guard case ArchiveError.unsupported(let what) = error else {
                return false
            }
            return what.contains("encryption")
        }
        let other = box.url("bzip.zip")
        try CoverageArchives.craft(other, [(name: "bzip.bin", data: Data("x".utf8))], localExtra: nil) { record in
            record.method = 12
        }
        let bzip = try bench.store.archive(at: other)
        #expect {
            _ = try read(bzip, "bzip.bin")
        } throws: { error in
            guard case ArchiveError.unsupported(let what) = error else {
                return false
            }
            return what.contains("compression method 12")
        }
    }

    /// Checks that an empty member that was written but not yet put into the file reads as empty.
    @Test
    internal func anEmptyNewMemberReadsAsEmpty() throws {
        try box.file("stub.txt", "stub")
        #expect(runTool("/usr/bin/zip", ["-q", "empty.zip", "stub.txt"], in: box.root).status == 0)
        let archive = try bench.store.archive(at: box.url("empty.zip"))
        let writer = try archive.write("nothing.txt")
        try writer.close(attributes: FileAttributes())
        #expect(try read(archive, "nothing.txt").isEmpty && archive.hasPendingChanges)
    }

    /// Checks that a thread that waited while another asked for the password takes the answer
    /// without asking again.
    @Test
    internal func whoWaitedForTheQuestionTakesItsAnswer() throws {
        let archive = try encrypted([(name: "one.txt", password: "pw")], refused: [])
        let other = Signal<Bool>()
        bench.environment.askPassword = { [bench] _, _ in
            let port = Signal<mach_port_t>()
            OtherThread.start {
                port.set(pthread_mach_thread_np(pthread_self()))
                other.set((try? Self.readFully(archive, "one.txt")) == Data("one.txt".utf8))
            }
            // Answered once the other reader waits for the question to end.
            let thread = port.wait() ?? 0
            _ = Wait.until { Self.isWaiting(thread) }
            return bench.passwords.next()
        }
        bench.passwords.set(["pw"])
        #expect(try read(archive, "one.txt") == Data("one.txt".utf8))
        #expect(other.wait() == true && bench.passwords.asked == 1)
    }
}

import AFMKernel
import Foundation
import TestSupport
import Testing

@testable import ArchivesPlugin

/// Review round 2: encryption, AES and the old one, and how often a password is asked for.
@Suite
internal struct Review2ArchivesEncryptionTests: ArchiveFixSuite {
    /// The archive file systems in a sandbox of their own.
    internal let bench: ArchiveBench

    /// A fresh bench for each test.
    internal init() throws {
        bench = try ArchiveBench()
    }

    /// New archives are encrypted with AES-256 that libarchive reads; a wrong password is asked for again (A023).
    @Test
    internal func newArchivesAreEncryptedWithAESAndOldOnesStillOpen() throws {
        let tree = try bench.makeTree("tree")
        let archive = box.url("aes.zip")
        try bench.pack([tree], to: archive, innerFolder: "") { options in
            options.password = "open sesame"
            options.verifies = true
        }
        let records = try ZipDirectory.read(try RandomAccessFile(archive, shownAs: nil), maxEntries: .max, check: nil)
            .records.filter { !$0.isDirectory }
        #expect(
            !records.isEmpty
                && records.allSatisfy { record in
                    record.method == ZipAES.method && record.aes?.strength == 3 && record.aes?.version == 2
                        && record.crc == 0
                }
        )
        // libarchive reads what was written, with the password and not without.
        let listed = runTool(
            "/usr/bin/bsdtar",
            ["-xOf", archive.path, "--passphrase", "open sesame", "tree/sub/deep/übung – ñ 日本.txt"],
            in: nil
        )
        #expect(listed.status == 0 && listed.output == "unicode name")
        #expect(
            runTool("/usr/bin/bsdtar", ["-xOf", archive.path, "--passphrase", "nope", "tree/readme.txt"], in: nil)
                .status != 0
        )
        // Read back here: a wrong password is asked for again, the right one is kept.
        bench.store.close()
        bench.passwords.set(["wrong", "open sesame"])
        #expect(
            try bench.read(bench.inside(archive, "tree/big.log", scheme: ArchiveURL.writableScheme))
                == Data(contentsOf: tree.appendingPathComponent("big.log"))
        )
        #expect(bench.passwords.asked == 2)
        #expect(
            try bench.read(bench.inside(archive, "tree/empty.txt", scheme: ArchiveURL.writableScheme)).isEmpty
                && bench.passwords.asked == 2
        )
        let back = try bench.unpack(archive, to: box.url("back"))
        #expect(back.problems.isEmpty && snapshot(box.url("back/tree")) == snapshot(tree))

        try expectOtherAESAndTheOldEncryption(tree)
    }

    /// The AES cipher decrypts what it encrypted in blocks of any length, with the same authentication.
    @Test
    internal func theCipherMatchesItselfAcrossBlockSizes() throws {
        var plain = Data(count: 100_003)
        plain.withUnsafeMutableBytes { arc4random_buf($0.baseAddress, $0.count) }
        let salt = Data((0..<16).map { UInt8($0) })
        let (encrypting, decrypting) = (
            try ZipAES.Cipher(password: "pässword", salt: salt, keyLength: 32),
            try ZipAES.Cipher(password: "pässword", salt: salt, keyLength: 32)
        )
        var encrypted = Data()
        var offset = 0
        // Blocks of every awkward length, so the key stream is carried over correctly.
        for size in [1, 15, 16, 17, 31, 4_096, 65_537, 30_000] {
            let end = min(plain.count, offset + size)
            encrypted.append(encrypting.encrypt(plain.subdata(in: offset..<end)))
            offset = end
        }
        encrypted.append(encrypting.encrypt(plain.subdata(in: offset..<plain.count)))
        var whole = encrypted
        decrypting.decrypt(&whole)
        #expect(whole == plain && encrypted != plain)
        #expect(encrypting.authentication() == decrypting.authentication())
        #expect(try ZipAES.Cipher(password: "other", salt: salt, keyLength: 32).verifier != encrypting.verifier)
    }

    /// A declined password is not asked for again by the same operation, nor while the refusal is remembered.
    @Test
    internal func aDeclinedPasswordIsNotAskedForAgainByTheSameOperation() throws {
        let tree = try bench.makeTree("tree")
        let archive = box.url("locked.zip")
        try bench.pack([tree], to: archive, innerFolder: "") { $0.password = "sesame" }
        bench.store.close()
        // Unpacking with nobody answering asks once, however many members there are and
        // however many threads read them.
        let refused = try bench.unpack(archive, to: box.url("refused"))
        #expect(!refused.problems.isEmpty && bench.passwords.asked == 1)
        // The next operation asks again, once, and every member opens with the answer.
        bench.passwords.set(["sesame"])
        let opened = try bench.unpack(archive, to: box.url("opened"))
        #expect(
            opened.problems.isEmpty && bench.passwords.asked == 2 && snapshot(box.url("opened/tree")) == snapshot(tree)
        )
        // Outside an operation a refusal is remembered for as long as the environment says.
        let fresh = try ArchiveBench()
        fresh.environment.passwordRefusalMemory = 60
        for name in ["readme.txt", "big.log", "empty.txt"] {
            #expect(throws: ArchiveError.self) {
                try fresh.read(fresh.inside(archive, "tree/" + name, scheme: ArchiveURL.writableScheme))
            }
        }
        #expect(fresh.passwords.asked == 1)
        fresh.store.close()
    }

    /// Unpacking the plain members of a partly encrypted archive asks for no password (A098).
    @Test
    internal func unpackingPlainMembersOfAPartlyEncryptedArchiveAsksNothing() throws {
        let tree = try bench.makeTree("tree")
        let archive = box.url("mixed.zip")
        try bench.pack([tree.appendingPathComponent("readme.txt")], to: archive, innerFolder: "") { $0.format = .zip }
        try bench.pack([tree.appendingPathComponent("big.log")], to: archive, innerFolder: "") { $0.password = "pw" }
        bench.store.close()
        let open = try bench.store.archive(at: archive, cancellation: nil)
        let unpacker = Unpacker(
            fileSystems: bench.fileSystems,
            monitor: bench.monitor,
            options: UnpackOptions(),
            whileUnpacking: nil
        ) { _, _ in
            .overwrite
        }
        let result = unpacker.run(
            [Unpacker.Source(archive: open, selection: .paths(["readme.txt"]))],
            into: box.url("plain")
        )
        #expect(result.problems.isEmpty && box.exists("plain/readme.txt") && bench.passwords.asked == 0)
    }

    /// What another program encrypted with AES opens here, and the old encryption is still written on request.
    private func expectOtherAESAndTheOldEncryption(_ tree: URL) throws {
        // What another program encrypted with AES (libarchive writes AE-1, with a checksum).
        #expect(
            runTool(
                "/usr/bin/bsdtar",
                ["-a", "-cf", "theirs.zip", "--options", "zip:encryption=aes256", "--passphrase", "pw", "tree"],
                in: box.root
            )
            .status == 0
        )
        let fresh = try ArchiveBench()
        fresh.passwords.set(["pw"])
        #expect(
            try fresh.read(fresh.inside(box.url("theirs.zip"), "tree/readme.txt", scheme: ArchiveURL.writableScheme))
                == Data(contentsOf: tree.appendingPathComponent("readme.txt"))
        )
        fresh.store.close()
        // The old encryption is still written on request, for programs that know no other.
        let readme = tree.appendingPathComponent("readme.txt")
        try bench.pack([readme], to: box.url("old.zip"), innerFolder: "") { options in
            options.password = "pw"
            options.encryption = .legacy
        }
        #expect(runTool("/usr/bin/unzip", ["-tq", "-P", "pw", box.url("old.zip").path], in: nil).status == 0)
        #expect(ArchiveCommands.legacyLabel.contains("weak") && ArchiveCommands.encryptionNote.contains("AES-256"))
    }
}

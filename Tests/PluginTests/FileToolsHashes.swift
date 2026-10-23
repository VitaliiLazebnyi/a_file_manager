import AFMKernel
import Foundation
import TestSupport
import Testing

@testable import FileToolsPlugin

/// The checksum methods against reference digests and the system's tools.
@Suite
internal struct FileToolsHashes {
    /// The four SHA-3 digests of the test pattern of one length.
    internal struct SHA3Vector: Sendable, CustomTestStringConvertible {
        /// The length of the pattern.
        internal let count: Int
        /// Its SHA3-224.
        internal let sha224: String
        /// Its SHA3-256.
        internal let sha256: String
        /// Its SHA3-384.
        internal let sha384: String
        /// Its SHA3-512.
        internal let sha512: String

        /// The length, as the test's name shows it.
        internal var testDescription: String { "\(count) bytes" }
    }

    /// Digests of the test pattern, computed with Python's hashlib; the lengths lie around
    /// the block sizes of the four variants.
    internal static let sha3Vectors: [SHA3Vector] = [
        SHA3Vector(
            count: 0,
            sha224: "6b4e03423667dbb73b6e15454f0eb1abd4597f9a1b078e3f5b5a6bc7",
            sha256: "a7ffc6f8bf1ed76651c14756a061d662f580ff4de43b49fa82d80a4b80f8434a",
            sha384: "0c63a75b845e4f7d01107d852e4c2485c51a50aaaa94fc61995e71bbee983a2ac3713831264adb47fb6bd1e058d5f004",
            sha512: "a69f73cca23a9ac5c8b567dc185a756e97c982164fe25859e0d1dcc1475c80a6"
                + "15b2123af1f5f94c11e3e9402c3ac558f500199d95b6d3e301758586281dcd26"
        ),
        SHA3Vector(
            count: 135,
            sha224: "3174e5126280625ecdfdb238d6a10d1c8b071031870ed197640cad90",
            sha256: "fded8fd9d6551c601eeb3b7c6bc5e5cfd8aad1d015b7e9aaa9c9b9475231d5e2",
            sha384: "25d2be1f5a681f8135992e0cc18a7b0758d1a880eb3c64d9c722f80d68b744bb3a89c223a0c38164cf4a423f91f8a533",
            sha512: "d942df0df09ac042cd3b641144c98d8fda0980bb037fc5c0e7f2e9a073b073dc"
                + "4bb8a8c1f4cb5b45f5805c6523741ed0571d6779b15829b2faa280fc60b50645"
        ),
        SHA3Vector(
            count: 136,
            sha224: "5d633f7e245e4338fa2698ef8b0cf98b129b5cc99622f770e3ba0cb6",
            sha256: "cf3ccff92480a29160c2d38317c430e14749bfee1788106957dfe73f8c4930e5",
            sha384: "ced899b993a69f66251a7872fbb87f8be5967857b2693e3feb032b3440dd94b78cab782debfa10956642ae536a8241e9",
            sha512: "ad8edff4f1b7aa1c63bbe49728ab9b165f7245b3d7102e6f99c261fc15d2d0bf"
                + "6afef6a491720454a1349fbf5d848854875ac83a1156fd7f6e2a37af26c07fb2"
        ),
        SHA3Vector(
            count: 137,
            sha224: "7098ddcff44c0ae3e0802d8d60fe7bea8d0d3219ce28660af1aee40c",
            sha256: "ce9d7dc90913ee5d92745019479a5352c6d6279bef18ed07dc0a83ee8084daca",
            sha384: "ef446c45f31f98fe3aa92392ee4198d8c797128cb87da84ad008aad1e1d972d0c6d98ef74e99b4bc5b97ae92be53ee27",
            sha512: "3f827e5d7ddbd54ea1dba28cae0154eb5ff8d8d973770865861b7cdf5f091040"
                + "889d55c0e74b672cead274fac1d4a559fd9185be898ab8969b5e78681527660d"
        ),
        SHA3Vector(
            count: 1_000,
            sha224: "51481b8dbd6b73dd110a967f438aa22facfcdce1eb5d2b36a5ec023f",
            sha256: "48e66a01861d0eadaacdb7a6ae7db6b9ac79242ecced4154a9fbb33c4e3cc571",
            sha384: "43e60a7ef818a0e367fcd4ede8f5fabbdb7090cb45972bb7a84038cc3abf4fc26c4f44b59d3a0306c973b66e84c8890b",
            sha512: "b8030d306ae990bc794bfb3a6100f67851889d6c272257afac7d1077a18660d6"
                + "ea8d0da5d2299c3ebaa0d34baf62cc58ac1fd4476506cf512a4897bb083a6fc4"
        ),
        SHA3Vector(
            count: 100_000,
            sha224: "98c0926f75e7c1907450b43b5d3c50ebff848a33d554f4e8764f0dbe",
            sha256: "b751df62942bc84db9f6a5c2def78558162c2857d5b126d7a2e56a0a357cdf62",
            sha384: "1c771bd5027191aa0d06ae42f555c94d98f68b6059da56881f6bab6b183ec9371be7717e9c3e9c67eca086f29124f57d",
            sha512: "04ffdd636dc25b3e900d12778cacbbd5c98300786b0b83e5c34b088bd2aa201f"
                + "3fc41dbe4c0e30cc6fa1c60e28354a02942b7ddf9e7a2f863ec6494472f1de47"
        )
    ]

    /// The digest of `data` by `method` in hex, fed in `pieces` blocks of about the same size.
    internal func digest(_ method: ChecksumMethod, _ data: Data, pieces: Int) -> String {
        let hasher = method.makeHasher()
        let step = max(1, (data.count + pieces - 1) / pieces)
        for start in stride(from: 0, to: data.count, by: step) {
            hasher.update(data.subdata(in: start..<min(start + step, data.count)))
        }
        return hasher.finish().hex
    }

    /// Every method gives the digests the standards and their reference implementations give.
    @Test
    internal func knownDigests() {
        let abc = Data("abc".utf8)
        #expect(digest(.crc32, Data("123456789".utf8), pieces: 1) == "cbf43926")
        #expect(digest(.crc32, Data(), pieces: 1) == "00000000")
        #expect(digest(.md5, abc, pieces: 1) == "900150983cd24fb0d6963f7d28e17f72")
        #expect(digest(.sha1, abc, pieces: 1) == "a9993e364706816aba3e25717850c26c9cd0d89d")
        #expect(digest(.sha224, abc, pieces: 1) == "23097d223405d8228642a477bda255b32aadbce4bda0b3f7e36c9da7")
        #expect(digest(.sha256, abc, pieces: 1) == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        #expect(
            digest(.sha384, abc, pieces: 1)
                == "cb00753f45a35e8bb5a03d699ac65007272c32ab0eded1631a8b605a43ff5bed8086072ba1e7cc2358baeca134c825a7"
        )
        #expect(
            digest(.sha512, abc, pieces: 1)
                .hasPrefix("ddaf35a193617abacc417349ae20413112e6fa4e89a97ea20a9eeee64b55d39a")
        )
        #expect(
            digest(.sha3Bits256, abc, pieces: 1) == "3a985da74fe225b2045c172d6bd390bd855f086e3e9d525b46bfe24511431532"
        )
        #expect(digest(.blake3, abc, pieces: 1) == "6437b3ac38465133ffb63b75273a8db548c558465d79db03fd359c6cd5bd9d85")
    }

    /// The SHA-3 digests of the test pattern, of lengths around the block sizes of the four variants, are those of
    /// Python's hashlib, whole and fed in pieces.
    @Test(arguments: sha3Vectors)
    internal func sha3(vector: SHA3Vector) {
        let data = FileToolsFixture.patternData(vector.count)
        for pieces in [1, 3, 7] {
            #expect(digest(.sha3Bits224, data, pieces: pieces) == vector.sha224)
            #expect(digest(.sha3Bits256, data, pieces: pieces) == vector.sha256)
            #expect(digest(.sha3Bits384, data, pieces: pieces) == vector.sha384)
            #expect(digest(.sha3Bits512, data, pieces: pieces) == vector.sha512)
        }
    }

    /// Digests of the test pattern from the BLAKE3 reference implementation; the lengths lie
    /// around the chunk size, where the tree grows.
    @Test(arguments: [
        (0, "af1349b9f5f9a1a6a0404dea36dcc9499bcb25c9adc112b7cc9a93cae41f3262"),
        (3, "e1be4d7a8ab5560aa4199eea339849ba8e293d55ca0a81006726d184519e647f"),
        (1_023, "10108970eeda3eb932baac1428c7a2163b0e924c9a9e25b35bba72b28f70bd11"),
        (1_024, "42214739f095a406f3fc83deb889744ac00df831c10daa55189b5d121c855af7"),
        (1_025, "d00278ae47eb27b34faecf67b4fe263f82d5412916c1ffd97c8cb7fb814b8444"),
        (2_048, "e776b6028c7cd22a4d0ba182a8bf62205d2ef576467e838ed6f2529b85fba24a"),
        (2_049, "5f4d72f40d7a5f82b15ca2b2e44b1de3c2ef86c426c95c1af0b6879522563030"),
        (3_072, "b98cb0ff3623be03326b373de6b9095218513e64f1ee2edd2525c7ad1e5cffd2"),
        (3_073, "7124b49501012f81cc7f11ca069ec9226cecb8a2c850cfe644e327d22d3e1cd3"),
        (4_096, "015094013f57a5277b59d8475c0501042c0b642e531b0a1c8f58d2163229e969"),
        (5_000, "ee78d92070de3df1c57c37002abf0a6b1a6589acdeef4d8ffac7cf3d9e8f2836"),
        (8_192, "aae792484c8efe4f19e2ca7d371d8c467ffb10748d8a5a1ae579948f718a2a63"),
        (31_744, "62b6960e1a44bcc1eb1a611a8d6235b6b4b78f32e7abc4fb4c6cdcce94895c47"),
        (102_400, "bc3e3d41a1146b069abffad3c0d44860cf664390afce4d9661f7902e7943e085")
    ])
    internal func blake3(count: Int, expected: String) {
        let data = FileToolsFixture.patternData(count)
        #expect(digest(.blake3, data, pieces: 1) == expected)
        #expect(digest(.blake3, data, pieces: 5) == expected)
        #expect(digest(.blake3, data, pieces: 64) == expected)
    }

    /// The digests of a file are those of the programs of macOS, whole and fed in pieces.
    @Test
    internal func agreesWithTheSystemTools() throws {
        let box = try Sandbox()
        let data = FileToolsFixture.patternData(300_001)
        let url = box.url("data.bin")
        try data.write(to: url)
        func first(_ tool: String, _ arguments: [String]) throws -> String {
            String(
                try FileToolsFixture.systemTool(tool, arguments + [url.path], in: nil).output.split(separator: " ")
                    .first ?? ""
            )
        }
        for pieces in [1, 9] {
            #expect(
                digest(.md5, data, pieces: pieces)
                    == (try first("/sbin/md5", ["-q"])).trimmingCharacters(in: .whitespacesAndNewlines)
            )
            #expect(digest(.sha1, data, pieces: pieces) == (try first("/usr/bin/shasum", ["-a", "1"])))
            #expect(digest(.sha224, data, pieces: pieces) == (try first("/usr/bin/shasum", ["-a", "224"])))
            #expect(digest(.sha256, data, pieces: pieces) == (try first("/usr/bin/shasum", ["-a", "256"])))
            #expect(digest(.sha384, data, pieces: pieces) == (try first("/usr/bin/shasum", ["-a", "384"])))
            #expect(digest(.sha512, data, pieces: pieces) == (try first("/usr/bin/shasum", ["-a", "512"])))
            // `cksum -o 3` prints the CRC32 as a decimal number.
            let crc = UInt32(try first("/usr/bin/cksum", ["-o", "3"])) ?? 0
            #expect(digest(.crc32, data, pieces: pieces) == String(format: "%08x", crc))
        }
    }

    /// The methods keep the numbers of the spec's setting, stand in the dialog once each, and name their files
    /// and lengths.
    @Test
    internal func methodsOfTheDialog() {
        #expect(ChecksumMethod.allCases.map(\.rawValue).sorted() == Array(0...11))
        #expect(
            ChecksumMethod(rawValue: 3) == .sha256 && ChecksumMethod(rawValue: 7) == .sha3Bits256
                && ChecksumMethod(rawValue: 11) == .blake3
        )
        #expect(Set(ChecksumMethod.dialogOrder) == Set(ChecksumMethod.allCases))
        #expect(
            [ChecksumMethod.crc32, .md5, .sha1, .sha256, .blake3, .sha512, .sha3Bits256].map(\.fileExtension)
                == ["sfv", "md5", "sha", "sha256", "bk3", "sha512", "sha3_256"]
        )
        #expect(
            ChecksumMethod.md5.reportName == "MD5" && ChecksumMethod.sha256.reportName == "SHA2_256"
                && ChecksumMethod.crc32.reportName == "CRC32"
        )
        #expect(ChecksumMethod.candidates(hexDigits: 64) == [.sha256, .sha3Bits256, .blake3])
        #expect(ChecksumMethod.candidates(hexDigits: 8) == [.crc32] && ChecksumMethod.candidates(hexDigits: 10).isEmpty)
        for method in ChecksumMethod.allCases {
            #expect(digest(method, Data("x".utf8), pieces: 1).count == method.digestLength * 2)
        }
    }

    /// Many files are hashed side by side and come back in their order, with a missing file as an error and the
    /// progress complete.
    @Test
    internal func manyFilesAreHashedOnAllCoresInOrder() {
        let (fileSystems, memory) = makeFileSystems()
        let files = (0..<300)
            .map { index in
                (url: memory.addFile("/h/f\(index)", "content \(index)"), methods: [ChecksumMethod.md5, .crc32])
            }
        // Guarded by `lock`.
        nonisolated(unsafe) var reports: [JobProgress] = []
        let lock = NSLock()
        let run = ToolRun(
            fileSystems: fileSystems,
            cancellation: CancellationFlag(),
            report: { progress in
                lock.lock()
                reports.append(progress)
                lock.unlock()
            },
            askExisting: { _ in .overwrite }
        )
        run.expect(bytes: 300 * 10, items: 300)
        let digests = ChecksumRun.digests(of: files + [(memory.url("/h/missing"), [.md5])], run: run)
        #expect(digests.count == 301)
        for index in 0..<300 {
            let expected = [
                digest(.md5, Data("content \(index)".utf8), pieces: 1),
                digest(.crc32, Data("content \(index)".utf8), pieces: 1)
            ]
            #expect((try? digests[index].get())?.map(\.hex) == expected)
        }
        #expect((try? digests[300].get()) == nil)
        run.advance(0, items: 0, force: true)
        #expect(
            reports.last?.itemsDone == 300
                && reports.last?.bytesDone
                    == Int64((0..<300).reduce(0) { total, index in total + "content \(index)".count })
        )
    }

    /// A cancelled run hashes nothing.
    @Test
    internal func hashingStopsWhenCancelled() {
        let (fileSystems, memory) = makeFileSystems()
        let run = ToolRun(fileSystems: fileSystems)
        run.cancellation.cancel()
        let digests = ChecksumRun.digests(of: [(memory.addFile("/h/a", "a"), [.sha1])], run: run)
        #expect(throws: ToolError.cancelled) { try digests[0].get() }
    }
}

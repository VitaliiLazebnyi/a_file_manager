import AFMKernel
import Foundation
import LocalFileSystemPlugin
import TestSupport
import Testing

@testable import FileToolsPlugin

/// The file tools: the six-bit codecs against their first form, hashing in passes, and the cancel of blocked work.
@Suite
internal struct ToolsAdoptFileTools {
    /// The first form of the two six-bit codecs, kept as the reference of the pointer loops.
    private enum Reference {
        /// The 64 characters of XXEncode, by value.
        static let xxAlphabet = Array("+-0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz".utf8)

        /// The character of a six-bit value, in XXEncode's alphabet with `xxEncode`, else in UUEncode's.
        static func character(_ value: UInt8, xxEncode: Bool) -> UInt8 {
            xxEncode ? xxAlphabet[Int(value & 63)] : (value & 63 == 0 ? 96 : (value & 63) + 32)
        }

        /// The six-bit value of a character; nil for one outside the alphabet.
        static func value(_ character: UInt8, xxEncode: Bool) -> UInt8? {
            if xxEncode {
                return xxAlphabet.firstIndex(of: character).map { index in UInt8(index) }
            }
            return (32...96).contains(character) ? (character - 32) & 63 : nil
        }

        /// The lines of `data`, as the encoder first made them.
        static func encode(_ data: Data, xxEncode: Bool) -> Data {
            var output: [UInt8] = []
            data.withUnsafeBytes { (input: UnsafeRawBufferPointer) in
                var offset = 0
                while offset < input.count {
                    let count = min(45, input.count - offset)
                    output.append(character(UInt8(count), xxEncode: xxEncode))
                    for group in stride(from: 0, to: count, by: 3) {
                        func byte(_ index: Int) -> UInt8 { group + index < count ? input[offset + group + index] : 0 }
                        let (first, second, third) = (byte(0), byte(1), byte(2))
                        output.append(character(first >> 2, xxEncode: xxEncode))
                        output.append(character((first << 4 | second >> 4) & 63, xxEncode: xxEncode))
                        output.append(character((second << 2 | third >> 6) & 63, xxEncode: xxEncode))
                        output.append(character(third & 63, xxEncode: xxEncode))
                    }
                    output.append(13)
                    output.append(10)
                    offset += count
                }
            }
            return Data(output)
        }

        /// The bytes of one line, as the decoder first made them; throws `NotALine` for a line not of the format.
        static func decode(_ line: ArraySlice<UInt8>, xxEncode: Bool) throws -> [UInt8] {
            guard let first = line.first, let count = value(first, xxEncode: xxEncode).map(Int.init) else {
                throw SixBitText.NotALine()
            }
            var values: [UInt8] = []
            for character in line.dropFirst() {
                guard let value = value(character, xxEncode: xxEncode) else {
                    throw SixBitText.NotALine()
                }
                values.append(value)
            }
            let needed = (count + 2) / 3 * 4
            guard values.count >= needed || (!xxEncode && values.count + 3 >= needed) else {
                throw SixBitText.NotALine()
            }
            while values.count < needed {
                values.append(0)
            }
            var bytes: [UInt8] = []
            for group in stride(from: 0, to: needed, by: 4) {
                bytes.append(values[group] << 2 | values[group + 1] >> 4)
                bytes.append(values[group + 1] << 4 | values[group + 2] >> 2)
                bytes.append(values[group + 2] << 6 | values[group + 3])
            }
            return Array(bytes.prefix(count))
        }
    }

    /// `count` bytes from a generator seeded with `seed`.
    private func random(_ count: Int, seed: UInt64) -> Data {
        var state = seed
        return Data(
            (0..<count)
                .map { _ in
                    state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
                    return UInt8(truncatingIfNeeded: state >> 33)
                }
        )
    }

    /// The pointer loops of the six-bit codecs give what their first form gave, also for lines not of the format.
    @Test
    internal func sixBitLoopsMatchTheFirstImplementation() throws {
        let lengths =
            [0, 1, 2, 3, 4, 43, 44, 45, 46, 47, 89, 90, 91, 92, 135, 1_000, 4_096, 65_537]
            + (0..<60).map { step in (step * 7_919) % 3_000 }
        for (index, length) in lengths.enumerated() {
            let data = random(length, seed: UInt64(index + 1))
            for xxEncode in [false, true] {
                let encoded = SixBitText.encode(data, xxEncode: xxEncode)
                #expect(encoded == Reference.encode(data, xxEncode: xxEncode))
                let bytes = [UInt8](encoded)
                var start = 0
                var decoded: [UInt8] = []
                while start < bytes.count {
                    let end = try #require(bytes[start...].firstIndex(of: 13))
                    let line = bytes[start..<end]
                    let one = try? SixBitText.decode(line, xxEncode: xxEncode)
                    #expect(
                        one == (try? Reference.decode(line, xxEncode: xxEncode))
                            && (try? SixBitText.decode(line, xxEncode: !xxEncode))
                                == (try? Reference.decode(line, xxEncode: !xxEncode))
                    )
                    decoded += one ?? []
                    start = end + 2
                }
                #expect(decoded == [UInt8](data))
            }
        }
        // Lines that are not lines of the format, cut short, or too long.
        var state: UInt64 = 99
        for _ in 0..<20_000 {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            let count = Int(state >> 40) % 90
            let line = ArraySlice(
                (0..<count)
                    .map { offset -> UInt8 in
                        UInt8(28 + Int(((state >> UInt64(offset % 40)) &+ UInt64(offset) &* 31) % 100))
                    }
            )
            for xxEncode in [false, true] {
                let decoded = try? SixBitText.decode(line, xxEncode: xxEncode)
                #expect(decoded == (try? Reference.decode(line, xxEncode: xxEncode)))
            }
        }
    }

    /// A digest whose method is not known is found in one more pass over the other methods of its length.
    @Test
    internal func aDigestWithoutAMethodHintIsFoundInOnePassOverTheOthers() throws {
        let box = try Sandbox()
        let fileSystems = FileSystemRegistry()
        fileSystems.register(LocalFileSystem())
        let data = random(3 << 20, seed: 5)
        try data.write(to: box.url("f.bin"))
        let run = ToolRun(fileSystems: fileSystems)
        func digest(_ method: ChecksumMethod) -> String {
            let hasher = method.makeHasher()
            hasher.update(data)
            return hasher.finish().hex
        }
        // Two other methods of the same length than the first candidate: the second pass hashes both.
        let candidates: [ChecksumMethod] = [.sha256, .sha3Bits256, .blake3]
        let wanted = digest(.blake3)
        let results = ChecksumRun.digests(
            of: [ChecksumRun.HashRequest(url: box.url("f.bin"), methods: candidates, expected: wanted)],
            run: run
        )
        let found = try results[0].get()
        #expect(
            found.count == 3 && found[0].hex == digest(.sha256) && found[1].hex == digest(.sha3Bits256)
                && found[2].hex == wanted
        )
    }

    /// The cancel ends a hash that waits on a read, as a cancelled error.
    @Test
    internal func cancellingEndsABlockedHash() {
        let memory = MemoryFileSystem()
        memory.addFile("/h/a", "data")
        let probe = ToolsAdopt.ProbingFileSystem(memory)
        let registry = FileSystemRegistry()
        registry.register(probe)
        memory.stallsReads = true
        defer { memory.releaseStalls() }
        let flag = CancellationFlag()
        let run = ToolRun(
            fileSystems: registry,
            cancellation: flag,
            report: { _ in
                // Not watched here.
            },
            askExisting: { _ in .overwrite }
        )
        let results = ToolsAdopt.Outcome<[Result<[[UInt8]], any Error>]>()
        let done = ToolsAdopt.background {
            results.value = ChecksumRun.digests(of: [(memory.url("/h/a"), [.sha1])], run: run)
        }
        #expect(probe.reading.wait(timeout: .now() + Wait.ceiling) == .success)
        ToolsAdopt.cancelFromThread(flag)
        #expect(done.wait(timeout: .now() + Wait.ceiling) == .success)
        if case .failure(let error)? = results.value?.first {
            #expect((error as? ToolError) == .cancelled)
        } else {
            Issue.record("the hash did not fail")
        }
        #expect(memory.interruptions >= 1)
    }

    /// The cancel ends a split that waits on a read, and leaves no part behind.
    @Test
    internal func cancellingEndsABlockedSplit() throws {
        let memory = MemoryFileSystem()
        let source = memory.addFile("/s/big.bin", String(repeating: "x", count: 100))
        memory.addDirectory("/out")
        let probe = ToolsAdopt.ProbingFileSystem(memory)
        let registry = FileSystemRegistry()
        registry.register(probe)
        memory.stallsReads = true
        defer { memory.releaseStalls() }
        let flag = CancellationFlag()
        let run = ToolRun(
            fileSystems: registry,
            cancellation: flag,
            report: { _ in
                // Not watched here.
            },
            askExisting: { _ in .overwrite }
        )
        let item = try #require(memory.item(at: source))
        let failure = ToolsAdopt.Outcome<any Error>()
        let done = ToolsAdopt.background {
            do {
                try Splitter.split(item, into: memory.url("/out"), partSize: 40, run: run)
            } catch {
                failure.value = error
            }
        }
        #expect(probe.reading.wait(timeout: .now() + Wait.ceiling) == .success)
        ToolsAdopt.cancelFromThread(flag)
        #expect(done.wait(timeout: .now() + Wait.ceiling) == .success)
        #expect((failure.value as? ToolError) == .cancelled)
        #expect(!memory.allPaths.contains { path in path.hasPrefix("/out/") })
    }

    /// The cancel ends an encode that waits on a write.
    @Test
    internal func cancellingEndsABlockedWrite() throws {
        let memory = MemoryFileSystem()
        let source = memory.addFile("/s/data.bin", String(repeating: "x", count: 100))
        memory.addDirectory("/out")
        let probe = ToolsAdopt.ProbingFileSystem(memory)
        let registry = FileSystemRegistry()
        registry.register(probe)
        memory.stallsWrites = true
        defer { memory.releaseStalls() }
        let flag = CancellationFlag()
        let run = ToolRun(
            fileSystems: registry,
            cancellation: flag,
            report: { _ in
                // Not watched here.
            },
            askExisting: { _ in .overwrite }
        )
        let item = try #require(memory.item(at: source))
        let failure = ToolsAdopt.Outcome<any Error>()
        let done = ToolsAdopt.background {
            do {
                try Encoder.encode(item, into: memory.url("/out"), options: Encoder.Options(method: .uue), run: run)
            } catch {
                failure.value = error
            }
        }
        #expect(probe.writing.wait(timeout: .now() + Wait.ceiling) == .success)
        ToolsAdopt.cancelFromThread(flag)
        #expect(done.wait(timeout: .now() + Wait.ceiling) == .success)
        #expect((failure.value as? ToolError) == .cancelled && memory.interruptions >= 1)
    }
}

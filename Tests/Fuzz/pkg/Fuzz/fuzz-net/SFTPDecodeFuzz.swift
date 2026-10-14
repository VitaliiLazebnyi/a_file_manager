import AFMKernel
import Foundation
import FuzzCore

@testable import NetworkPlugin

/// The `sftpdec` target: the body of an SFTP packet read as each answer a session expects.
internal enum SFTPDecodeFuzz {
    /// The target.
    ///
    /// - Returns: The target for `fuzzMain`.
    internal static func target() -> FuzzTarget {
        FuzzTarget("sftpdec", maxLen: 2_048, seeds: seeds, run: run)
    }

    /// A listing, a status, attributes, a handle, data and a version packet (the first byte is the type).
    ///
    /// - Returns: The seeds.
    private static func seeds() -> [[UInt8]] {
        var names = SFTPEncoder()
        names.u32(2)
        names.string("file.txt")
        names.string("-rw-r--r-- 1 u g 5 Jan 1 00:00 file.txt")
        names.u32(0x8000_000F)
        names.u64(5)
        names.u32(501)
        names.u32(20)
        names.u32(0o100644)
        names.u32(1)
        names.u32(1_600_000_000)
        names.u32(1)
        names.string("k")
        names.string("v")
        names.string("dir")
        names.string("long")
        names.u32(4)
        names.u32(0o040755)
        var status = SFTPEncoder()
        status.u32(2)
        status.string("No such file")
        status.string("en")
        return [
            [104] + [UInt8](names.data), [101] + [UInt8](status.data),
            [105, 0, 0, 0, 5, 0, 0, 0, 0, 0, 0, 0, 9, 0, 0, 0x81, 0xA4], [102, 0, 0, 0, 4, 1, 2, 3, 4],
            [103, 0, 0, 0, 3, 65, 66, 67], [2, 0, 0, 0, 3, 0, 0, 0, 1, 97, 0, 0, 0, 1, 98]
        ]
    }

    /// Reads the body as the packet type it names, and as every answer type.
    ///
    /// - Parameter bytes: The input: a packet type, then the body.
    private static func run(_ bytes: [UInt8]) {
        guard let first = bytes.first else {
            return
        }

        // The payload as the reading thread hands it on: a view into a larger buffer, the type cut off,
        // then the request number.
        let payload = Data([0, 0, 0, 0] + bytes).dropFirst(4)
        let body = payload.dropFirst()
        let kinds: [SFTPPacket.Kind] = [.version, .status, .handle, .data, .name, .attributes, .extendedReply, .closed]
        if let kind = SFTPPacket.Kind(rawValue: first) {
            decodeAs(kind, body)
            decodeAs(kind, body.dropFirst(min(4, body.count)))
        }
        for kind in kinds {
            decodeAs(kind, body)
        }
    }

    /// The body of a packet as the session reads the answers it expects.
    ///
    /// - Parameters:
    ///   - kind: The packet type.
    ///   - body: The body.
    private static func decodeAs(_ kind: SFTPPacket.Kind, _ body: Data) {
        let packet = SFTPPacket(kind: kind, body: body)
        _ = packet.statusCode
        _ = try? packet.checkStatus()
        readNames(packet)
        if var decoder = try? packet.expect(.attributes), let attributes = try? decoder.attributes() {
            _ = attributes.entry(named: "x").item(in: NetFuzz.base)
        }
        if var decoder = try? packet.expect(.handle) {
            _ = try? decoder.bytes()
        }
        if var decoder = try? packet.expect(.data) {
            _ = try? decoder.bytes()
            _ = decoder.isAtEnd
        }
        if var decoder = try? packet.expect(.extendedReply) {
            _ = try? decoder.u64()
            _ = try? decoder.u64()
            _ = try? decoder.u8()
        }
        if var decoder = try? packet.expect(.version) {
            _ = try? decoder.u32()
            while !decoder.isAtEnd {
                guard (try? decoder.string()) != nil, (try? decoder.string()) != nil else {
                    break
                }
            }
        }
    }

    /// A name packet as an answer to readdir and to realpath.
    ///
    /// - Parameter packet: The packet.
    private static func readNames(_ packet: SFTPPacket) {
        // readdir
        if var decoder = try? packet.expect(.name) {
            var entries: [RemoteEntry] = []
            do {
                for _ in 0..<(try decoder.u32()) {
                    let name = try decoder.string()
                    _ = try decoder.bytes()
                    let attributes = try decoder.attributes()
                    if RemoteEntry.isSafeName(name) {
                        entries.append(attributes.entry(named: name))
                    }
                }
            } catch {
                // A short or broken listing ends here; what was read so far is used.
            }
            for entry in entries {
                _ = entry.item(in: NetFuzz.base)
            }
        }
        // realpath
        if var names = try? packet.expect(.name) {
            _ = try? names.u32()
            if let path = try? names.string() {
                _ = RemotePath.normalized(path)
            }
        }
    }
}

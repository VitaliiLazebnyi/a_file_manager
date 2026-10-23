import AFMKernel
import Foundation
import FuzzCore

@testable import ArchivesPlugin

/// A file is packed into a new ZIP with a password, the way Pack does it.
///
/// The contract: without another choice the members are encrypted with AES-256 (WinZip AE-2: method 99, extra field
/// 0x9901, version 2, strength 3); the contents are not in the archive in the clear; the right password gives the
/// contents back byte for byte and a wrong one never does.
@MainActor
internal func runZipPack(_ bytes: [UInt8]) {
    let input = PackInput(bytes)
    let root = fzWorkDir + "/p"
    try? FileManager.default.removeItem(atPath: root)
    try? FileManager.default.createDirectory(atPath: root + "/src", withIntermediateDirectories: true)
    let source = root + "/src/" + input.name
    guard FileManager.default.createFile(atPath: source, contents: Data(input.contents)) else {
        return
    }
    let archive = URL(fileURLWithPath: root + "/out.zip")
    guard pack(input, from: source, into: archive) else {
        return
    }
    guard let packed = FileManager.default.contents(atPath: archive.path).map({ [UInt8]($0) }),
        let directory = ZipDirectory(packed)
    else {
        fzFail("zippack-no-directory")
    }
    checkPackedMembers(directory.members, input)
    checkSecrecy(packed, input)
    checkReadBack(archive, input)
}

/// The seeds of `zippack`.
internal func zipPackSeeds() -> [[UInt8]] {
    [
        Array("\u{0}\u{5}secret\u{5}a.txthello from the packer, hello from the packer\n".utf8),
        [0x60, 3, 0xC3, 0xA9, 0x21, 2, 0x78, 0x79] + Array(repeating: 0x41, count: 64),
        [0x0F, 2, 0x70, 0x77, 1, 0x66] + Array("old encryption on request, sixteen bytes and more".utf8),
        [0x45, 1, 0x70, 0] + (0..<200).map { UInt8($0) }
    ]
}

/// Packs the file at `source` into `archive`; false when the file system does not find it.
@MainActor
private func pack(_ input: PackInput, from source: String, into archive: URL) -> Bool {
    let store = ArchiveStore(environment: ArchiveRig.environment)
    let registry = ArchiveRig.registry(for: store)
    defer { store.close() }
    guard let item = registry.item(at: URL(fileURLWithPath: source)) else {
        return false
    }
    var options = PackOptions()
    options.password = input.password
    options.level = input.level
    if input.legacy {
        options.encryption = .legacy
    }
    let packer = Packer(fileSystems: registry, store: store, monitor: QuietMonitor(), options: options)
    let result = packer.run([item], archive: archive, innerFolder: "")
    if let failure = result.failure {
        fzFail("zippack-pack-failed", "\(failure) name \(input.name.debugDescription) \(input.contents.count) bytes")
    }
    return true
}

/// One file, encrypted, with AES-256 unless the old encryption was asked for.
private func checkPackedMembers(_ members: [ZipMember], _ input: PackInput) {
    let files = members.filter { $0.name.last != 0x2F }
    fzCheck(files.count == 1, "zippack-member-count", "\(members.count) members")
    for member in files {
        fzCheck(member.flags & 1 == 1, "zippack-member-not-encrypted", "flags \(member.flags) method \(member.method)")
        if input.legacy {
            fzCheck(member.method != 99, "zippack-legacy-asked-aes-written")
        } else {
            fzCheck(member.method == 99, "zippack-default-is-not-aes", "method \(member.method)")
            checkAESField(member.extra)
        }
    }
}

/// The AES extra field: header 0x9901, 7 bytes, version 2 (AE-2), "AE", strength 3 (256 bits).
private func checkAESField(_ extra: [UInt8]) {
    var offset = 0
    var found = false
    while offset + 4 <= extra.count {
        let fieldID = Int(readLE(extra, offset, 2))
        let size = Int(readLE(extra, offset + 2, 2))
        if fieldID == 0x9901, size == 7, offset + 11 <= extra.count {
            found = true
            let isAE2 =
                readLE(extra, offset + 4, 2) == 2 && extra[offset + 6] == 0x41 && extra[offset + 7] == 0x45
                && extra[offset + 8] == 3
            fzCheck(isAE2, "zippack-aes-field-is-not-ae2-256", "\(Array(extra[offset..<(offset + 11)]))")
        }
        offset += 4 + size
    }
    fzCheck(found, "zippack-aes-field-missing", "\(extra)")
}

/// Neither the contents nor the password are in the archive in the clear.
private func checkSecrecy(_ packed: [UInt8], _ input: PackInput) {
    if input.contents.count >= 16 {
        fzCheck(
            !holds(packed, input.contents),
            "zippack-contents-in-the-clear",
            "\(input.contents.count) bytes, level \(input.level)"
        )
    }
    let secret = Array(input.password.utf8)
    if secret.count >= 6, !holds(Array(input.name.utf8), secret),
        !holds(Array(input.name.precomposedStringWithCanonicalMapping.utf8), secret)
    {
        fzCheck(
            !holds(packed, secret),
            "zippack-password-in-the-archive",
            "password \(input.password.debugDescription) name \(input.name.debugDescription)"
        )
    }
}

/// Read back with the right password, then with a wrong one.
@MainActor
private func checkReadBack(_ archive: URL, _ input: PackInput) {
    let environment = ArchiveRig.environment
    let saved = environment.askPassword
    defer { environment.askPassword = saved }
    let password = input.password
    environment.askPassword = { _, retry in retry ? nil : password }
    let right = Opened.open(archive)
    let read = right.browse(readLimit: 48 << 20)
    right.store.close()
    let first = read.contents.values.first
    fzCheck(
        read.listed && read.contents.count == 1 && first.map { [UInt8]($0) } == input.contents,
        "zippack-roundtrip",
        "listed \(read.listed), \(read.contents.count) readable members, \(first?.count ?? -1) bytes of "
            + "\(input.contents.count), legacy \(input.legacy)"
    )
    let wrongPassword = password + "x"
    environment.askPassword = { _, retry in retry ? nil : wrongPassword }
    let wrong = Opened.open(archive)
    let other = wrong.browse(readLimit: 48 << 20)
    wrong.store.close()
    if !input.legacy || input.contents.count >= 16 {
        // (The old encryption checks one byte only; a short member can pass it by chance.)
        let readsContents = other.contents.values.contains { [UInt8]($0) == input.contents }
        fzCheck(
            !readsContents || input.contents.isEmpty,
            "zippack-wrong-password-reads-the-contents",
            "legacy \(input.legacy)"
        )
    }
}

/// Whether `needle` (not empty) occurs in `haystack`.
private func holds(_ haystack: [UInt8], _ needle: [UInt8]) -> Bool {
    guard !needle.isEmpty, haystack.count >= needle.count else {
        return false
    }
    return haystack.contains(needle)
}

import AFMKernel
import Foundation
import FuzzCore
import LocalFileSystemPlugin

@testable import ArchivesPlugin

// Archives: a mutated archive file is opened the way a panel opens it (ArchiveStore →
// ArchiveFileSystem), listed completely, every member is read to its end, and the whole
// archive is unpacked with the Unpacker into a folder next to a canary folder.
//
//   <work>/x/in/<archive>          the input
//   <work>/x/out/target/           where it is unpacked
//   <work>/x/out/canary/keep.txt   must stay as it is; nothing else may appear in out/ or x/

final class QuietMonitor: JobMonitor {
    let cancellation = CancellationFlag()
    func report(_ progress: JobProgress) {}
    func ask<Answer>(_ question: () -> Answer) -> Answer { question() }
}

let fm = FileManager.default
var environment: ArchiveEnvironment!
var local: LocalFileSystem!
let canaryText = Data("canary: must stay as it is\n".utf8)

func setUpArchives() {
    // The plugin's scratch folder goes below the work folder as well.
    let tmp = fzWorkDir + "/tmp"
    try? fm.createDirectory(atPath: tmp, withIntermediateDirectories: true)
    setenv("TMPDIR", tmp, 1)
    environment = ArchiveEnvironment()
    environment.flushDelay = nil
    environment.unpackedLimit = 8 << 20
    environment.askPassword = { _, retry in retry ? nil : "secret" }
    local = LocalFileSystem()
}

struct Opened {
    let store: ArchiveStore
    let fileSystems: FileSystemRegistry
    let root: URL
    let provider: FileSystemProvider
}

func open(_ archive: URL) -> Opened {
    let store = ArchiveStore(environment: environment)
    let registry = FileSystemRegistry()
    let zip = ArchiveFileSystem(scheme: ArchiveURL.writableScheme, store: store)
    let readOnly = ArchiveFileSystem(scheme: ArchiveURL.readOnlyScheme, store: store)
    [local, zip, readOnly].forEach(registry.register)
    environment.fileSystems = { [weak registry] in registry }
    let scheme = ArchiveFileSystem.scheme(forArchive: archive, fileSystems: registry)
    return Opened(
        store: store, fileSystems: registry, root: ArchiveURL.make(scheme: scheme, archive: archive),
        provider: scheme == ArchiveURL.writableScheme ? zip : readOnly)
}

/// Lists everything and reads every file. Returns what could be read, by URL path.
func browse(_ o: Opened, readLimit: Int = 48 << 20) -> (listed: Bool, contents: [String: Data], count: Int) {
    var contents: [String: Data] = [:]
    var queue = [o.root]
    var count = 0
    var total = 0
    var listedRoot = false
    while let folder = queue.popLast(), count < 20_000 {
        guard let items = try? o.provider.list(folder, showHidden: true) else { continue }
        if folder == o.root { listedRoot = true }
        for item in items {
            count += 1
            // A member whose name is a way out (`..`, a zero byte, a `/` that is part of a name or
            // joined to a neighbouring character) is not listed at all.
            let name = Array(item.name.utf8)
            fzCheck(
                !name.isEmpty && name != [0x2E] && name != [0x2E, 0x2E] && !name.contains(0x2F) && !name.contains(0),
                "listed-unsafe-name",
                "\(item.name.debugDescription) in \(folder.path.debugDescription)")
            _ = o.provider.item(at: item.url)
            if item.isDirectory {
                queue.append(item.url)
                continue
            }
            guard total < readLimit, let reader = try? o.provider.read(item.url) else { continue }
            var data = Data()
            var ok = true
            do {
                while let block = try reader.read(upToCount: 70_000) {
                    data.append(block)
                    if data.count > readLimit {
                        ok = false
                        break
                    }
                }
            } catch { ok = false }
            reader.close()
            total += data.count
            if ok { contents[item.url.path] = data }
        }
    }
    return (listedRoot, contents, count)
}

func names(_ path: String) -> [String] { ((try? fm.contentsOfDirectory(atPath: path)) ?? []).sorted() }

func checkContainment(_ root: String, archiveName: String, what: String) {
    let out = root + "/out"
    fzCheck(names(root) == ["in", "out"], "escape-work-root", "\(what): \(names(root))")
    fzCheck(
        names(out).allSatisfy { $0 == "canary" || $0 == "target" }, "escape-next-to-target", "\(what): \(names(out))")
    fzCheck(names(out + "/canary") == ["keep.txt"], "escape-into-canary", "\(what): \(names(out + "/canary"))")
    fzCheck(fm.contents(atPath: out + "/canary/keep.txt") == canaryText, "escape-canary-changed", what)
    var st = stat()
    if lstat(out + "/canary/keep.txt", &st) == 0 {
        fzCheck(st.st_nlink == 1, "escape-hardlink-to-canary", what)
        fzCheck(st.st_mode & 0o7777 == 0o644, "escape-canary-mode", "\(what): \(String(st.st_mode, radix: 8))")
    }
    let inside = names(root + "/in")
    fzCheck(inside.allSatisfy { $0 == archiveName }, "stray-next-to-archive", "\(what): \(inside)")
}

/// No link below `target` may be a way out that something was written through: every regular
/// file must really lie below the target.
func checkTree(_ target: String) {
    guard let real = realpath(target, nil) else { return }
    let base = String(cString: real)
    free(real)
    guard let walker = fm.enumerator(atPath: target) else { return }
    var seen = 0
    for case let rel as String in walker {
        seen += 1
        if seen > 5000 { break }
        let path = target + "/" + rel
        var st = stat()
        guard lstat(path, &st) == 0 else { continue }
        if st.st_mode & S_IFMT == S_IFREG {
            fzCheck(st.st_mode & 0o6000 == 0, "unpacked-setuid", "\(rel) \(String(st.st_mode, radix: 8))")
            if let r = realpath(path, nil) {
                let resolved = String(cString: r)
                free(r)
                // By bytes: a name may begin with a mark that joins the `/` before it into one character.
                fzCheck(
                    Array(resolved.utf8).starts(with: Array((base + "/").utf8)), "escape-through-link",
                    "\(rel) -> \(resolved)")
            }
        }
    }
}

func prepare(_ bytes: [UInt8], name: String) -> (root: String, archive: URL) {
    let root = fzWorkDir + "/x"
    try? fm.removeItem(atPath: root)
    // What the last input left may be unremovable as it is (folders without write permission).
    if fm.fileExists(atPath: root) {
        _ = try? Process.run(URL(fileURLWithPath: "/bin/chmod"), arguments: ["-R", "u+rwx", root]).waitUntilExit()
        try? fm.removeItem(atPath: root)
    }
    try? fm.createDirectory(atPath: root + "/in", withIntermediateDirectories: true)
    try? fm.createDirectory(atPath: root + "/out/canary", withIntermediateDirectories: true)
    fm.createFile(atPath: root + "/out/canary/keep.txt", contents: canaryText, attributes: [.posixPermissions: 0o644])
    let archive = URL(fileURLWithPath: root + "/in/" + name)
    fm.createFile(atPath: archive.path, contents: Data(bytes))
    return (root, archive)
}

func isForeign(_ bytes: [UInt8], name: String) -> Bool {
    // bsdtar reads those: a process per input, and somebody else's parser.
    ArchiveFormat.detect(head: Data(bytes.prefix(512)), name: name) { _ in true } == .foreign
}

func runArchive(_ bytes: [UInt8], name: String, unpack: Bool = true) {
    if isForeign(bytes, name: name) { return }
    let (root, archive) = prepare(bytes, name: name)
    for pass in 0..<2 {
        // Second pass: as for an archive too large to keep an unpacked copy of (every read
        // goes through the stream, sizes come from the trailers).
        environment.materializeLimit = pass == 0 ? 256 << 20 : 0
        if pass == 1, name.hasSuffix(".zip") || name.hasSuffix(".tar") { break }
        let o = open(archive)
        let seen = browse(o)
        if pass == 0, unpack, seen.listed, let opened = try? o.store.archive(at: archive) {
            for keepsPaths in [true, false] {
                if !keepsPaths {
                    // Links that stand in the target already (the user's own, or what the first round
                    // unpacked): nothing may be written through them.
                    let target = root + "/out/target"
                    try? fm.createDirectory(atPath: target, withIntermediateDirectories: true)
                    for (name, to) in [
                        ("ln", "../canary"), ("up", ".."), ("keep.txt", "../canary/keep.txt"),
                        ("hl", "../canary/keep.txt")
                    ] {
                        var st = stat()
                        if lstat(target + "/" + name, &st) != 0 {
                            try? fm.createSymbolicLink(atPath: target + "/" + name, withDestinationPath: to)
                        }
                    }
                }
                var options = UnpackOptions()
                options.keepsPaths = keepsPaths
                options.overwrites = true
                let unpacker = Unpacker(fileSystems: o.fileSystems, monitor: QuietMonitor(), options: options) { _, _ in
                    .overwrite
                }
                _ = unpacker.run([Unpacker.Source(archive: opened)], into: URL(fileURLWithPath: root + "/out/target"))
                checkContainment(root, archiveName: name, what: "unpack keepsPaths=\(keepsPaths)")
                checkTree(root + "/out/target")
            }
            _ = ArchiveTester.test(opened, cancellation: CancellationFlag())
        }
        o.store.close()
        checkContainment(root, archiveName: name, what: "browse")
    }
    if let file = try? RandomAccessFile(archive) {
        _ = CompressedSize.ofXZ(file)
        _ = CompressedSize.claimedByGzip(file)
        _ = GzipHeader(Data(bytes.prefix(1024)))
    }
}

/// Browsing only: the archive is listed and every member read, nothing is unpacked. Much
/// faster than the full round, so the parsers see many more inputs.
func runList(_ bytes: [UInt8], name: String) {
    if isForeign(bytes, name: name) { return }
    let dir = fzWorkDir + "/l"
    try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
    let archive = URL(fileURLWithPath: dir + "/" + name)
    fm.createFile(atPath: archive.path, contents: Data(bytes))
    let plain = name.hasSuffix(".zip") || name.hasSuffix(".tar")
    for pass in 0..<(plain ? 1 : 2) {
        environment.materializeLimit = pass == 0 ? 256 << 20 : 0
        let o = open(archive)
        _ = browse(o, readLimit: 8 << 20)
        o.store.close()
    }
    if !plain, let file = try? RandomAccessFile(archive) {
        _ = CompressedSize.ofXZ(file)
        _ = CompressedSize.claimedByGzip(file)
        _ = GzipHeader(Data(bytes.prefix(1024)))
    }
}

/// The modify path: add a member, rename one, change a date, write it all into the file.
/// Either that throws, or the archive opens again and holds what it held, plus the changes.
func runZipModify(_ bytes: [UInt8]) {
    let name = "m.zip"
    let (root, archive) = prepare(bytes, name: name)
    let o = open(archive)
    defer { o.store.close() }
    let before = browse(o)
    guard before.listed else { return }
    let added = Data("added by the fuzzer \(bytes.count)\n".utf8)
    let newURL = o.root.appendingPathComponent("fz-added.txt")
    var changed = false
    var renamed: (from: String, to: String)?
    var dated: String?
    do {
        let writer = try o.provider.write(newURL)
        try writer.write(added)
        try writer.close(
            attributes: FileAttributes(modified: Date(timeIntervalSince1970: 1_600_000_000), permissions: 0o644))
        changed = true
        let files = before.contents.keys.sorted()
        if let first = files.first {
            let source = url(o, path: first)
            let destination = source.deletingLastPathComponent().appendingPathComponent("fz-renamed.bin")
            try o.provider.move(source, to: destination, replacing: false)
            renamed = (first, destination.path)
        }
        if files.count > 1, let last = files.last {
            try o.provider.setAttributes(
                FileAttributes(modified: Date(timeIntervalSince1970: 1_234_567_890)), of: url(o, path: last))
            dated = last
        }
    } catch {}
    do {
        try o.provider.commit(o.root, cancellation: CancellationFlag())
    } catch {
        checkContainment(root, archiveName: name, what: "modify, commit threw")
        return
    }
    checkContainment(root, archiveName: name, what: "modify")
    guard changed else { return }
    // A new store reads the file as it now is.
    let again = open(archive)
    defer { again.store.close() }
    let after = browse(again)
    fzCheck(
        after.listed, "zipmod-unreadable-after-commit",
        "the archive no longer opens after a commit that reported success")
    fzCheck(
        after.contents[newURL.path] == added, "zipmod-added-member-lost",
        "have \(after.contents.keys.sorted().prefix(20))")
    for (path, data) in before.contents {
        if path == newURL.path { continue }
        let now = renamed?.from == path ? renamed!.to : path
        if renamed?.to == path, renamed?.from != path { continue }
        fzCheck(
            after.contents[now] == data, "zipmod-member-changed",
            "\(path) (now \(now)): \(data.count) bytes before, \(after.contents[now].map { "\($0.count) bytes" } ?? "unreadable") after; dated=\(dated ?? "-")"
        )
    }
}

// MARK: - packing with a password

/// The members of a ZIP as its directory names them: flags, method and the extra field of each.
func zipDirectory(_ d: [UInt8]) -> [(name: [UInt8], flags: Int, method: Int, extra: [UInt8])]? {
    guard d.count >= 22 else { return nil }
    var end = d.count - 22
    while end >= 0, !(d[end] == 0x50 && d[end + 1] == 0x4B && d[end + 2] == 5 && d[end + 3] == 6) { end -= 1 }
    guard end >= 0 else { return nil }
    let count = Int(le(d, end + 10, 2))
    var at = Int(le(d, end + 16, 4))
    var out: [(name: [UInt8], flags: Int, method: Int, extra: [UInt8])] = []
    for _ in 0..<count {
        guard at + 46 <= d.count, d[at] == 0x50, d[at + 1] == 0x4B, d[at + 2] == 1, d[at + 3] == 2 else { return nil }
        let nameLength = Int(le(d, at + 28, 2))
        let extraLength = Int(le(d, at + 30, 2))
        let commentLength = Int(le(d, at + 32, 2))
        guard at + 46 + nameLength + extraLength <= d.count else { return nil }
        out.append(
            (
                Array(d[(at + 46)..<(at + 46 + nameLength)]), Int(le(d, at + 8, 2)), Int(le(d, at + 10, 2)),
                Array(d[(at + 46 + nameLength)..<(at + 46 + nameLength + extraLength)])
            ))
        at += 46 + nameLength + extraLength + commentLength
    }
    return out
}

func contains(_ haystack: [UInt8], _ needle: [UInt8]) -> Bool {
    guard !needle.isEmpty, haystack.count >= needle.count else { return false }
    return Data(haystack).range(of: Data(needle)) != nil
}

/// A file is packed into a new ZIP with a password, the way Pack does it. The contract: without
/// another choice the members are encrypted with AES-256 (WinZip AE-2: method 99, extra field
/// 0x9901, version 2, strength 3); the contents are not in the archive in the clear; the right
/// password gives the contents back byte for byte and a wrong one never does.
func runZipPack(_ bytes: [UInt8]) {
    var c = Choices(bytes)
    let flags = c.byte()
    var password = String(decoding: c.take(1 + Int(c.byte() % 20)), as: UTF8.self)
    password.unicodeScalars.removeAll { $0.value == 0 }
    if password.isEmpty { password = "pw" }
    var name = String(decoding: c.take(Int(c.byte() % 24)), as: UTF8.self)
    name.unicodeScalars.removeAll { $0 == "/" || $0.value == 0 || $0 == ":" }
    if name.isEmpty || name == "." || name == ".." || name.utf8.count > 200 { name = "f.bin" }
    var contents = c.rest()
    if flags & 0x40 != 0 { contents = Array(repeating: contents, count: 40).flatMap { $0 } }
    let legacy = flags & 0x0F == 0x0F

    let root = fzWorkDir + "/p"
    try? fm.removeItem(atPath: root)
    try? fm.createDirectory(atPath: root + "/src", withIntermediateDirectories: true)
    guard fm.createFile(atPath: root + "/src/" + name, contents: Data(contents)) else { return }
    let archive = URL(fileURLWithPath: root + "/out.zip")
    do {
        let store = ArchiveStore(environment: environment)
        let registry = FileSystemRegistry()
        [
            local, ArchiveFileSystem(scheme: ArchiveURL.writableScheme, store: store),
            ArchiveFileSystem(scheme: ArchiveURL.readOnlyScheme, store: store)
        ].forEach(registry.register)
        environment.fileSystems = { registry }
        defer { store.close() }
        guard let item = registry.item(at: URL(fileURLWithPath: root + "/src/" + name)) else { return }
        var options = PackOptions()
        options.password = password
        options.level = Int(flags >> 4) % 10
        if legacy { options.encryption = .legacy }
        let result = Packer(fileSystems: registry, store: store, monitor: QuietMonitor(), options: options).run(
            [item], archive: archive)
        if let failure = result.failure {
            fzFail("zippack-pack-failed", "\(failure) name \(name.debugDescription) \(contents.count) bytes")
        }
    }
    guard let packed = fm.contents(atPath: archive.path).map({ [UInt8]($0) }), let members = zipDirectory(packed) else {
        fzFail("zippack-no-directory")
    }
    let files = members.filter { $0.name.last != 0x2F }
    fzCheck(files.count == 1, "zippack-member-count", "\(members.count) members")
    for member in files {
        fzCheck(member.flags & 1 == 1, "zippack-member-not-encrypted", "flags \(member.flags) method \(member.method)")
        if legacy {
            fzCheck(member.method != 99, "zippack-legacy-asked-aes-written")
        } else {
            fzCheck(member.method == 99, "zippack-default-is-not-aes", "method \(member.method)")
            // The AES extra field: header 0x9901, 7 bytes, version 2 (AE-2), "AE", strength 3 (256 bits).
            var at = 0
            var found = false
            while at + 4 <= member.extra.count {
                let id = Int(le(member.extra, at, 2))
                let size = Int(le(member.extra, at + 2, 2))
                if id == 0x9901, size == 7, at + 11 <= member.extra.count {
                    found = true
                    fzCheck(
                        le(member.extra, at + 4, 2) == 2 && member.extra[at + 6] == 0x41 && member.extra[at + 7] == 0x45
                            && member.extra[at + 8] == 3,
                        "zippack-aes-field-is-not-ae2-256", "\(Array(member.extra[at..<(at + 11)]))")
                }
                at += 4 + size
            }
            fzCheck(found, "zippack-aes-field-missing", "\(member.extra)")
        }
    }
    if contents.count >= 16 {
        fzCheck(
            !contains(packed, contents), "zippack-contents-in-the-clear",
            "\(contents.count) bytes, level \(Int(flags >> 4) % 10)")
    }
    if password.utf8.count >= 6, !contains(Array(name.utf8), Array(password.utf8)),
        !contains(Array(name.precomposedStringWithCanonicalMapping.utf8), Array(password.utf8))
    {
        fzCheck(
            !contains(packed, Array(password.utf8)), "zippack-password-in-the-archive",
            "password \(password.debugDescription) name \(name.debugDescription)")
    }
    // Read back with the right password, then with a wrong one.
    let saved = environment.askPassword
    defer { environment.askPassword = saved }
    environment.askPassword = { _, retry in retry ? nil : password }
    let right = open(archive)
    let read = browse(right)
    right.store.close()
    fzCheck(
        read.listed && read.contents.count == 1 && read.contents.values.first.map { [UInt8]($0) } == contents,
        "zippack-roundtrip",
        "listed \(read.listed), \(read.contents.count) readable members, \(read.contents.values.first?.count ?? -1) bytes of \(contents.count), legacy \(legacy)"
    )
    environment.askPassword = { _, retry in retry ? nil : password + "x" }
    let wrong = open(archive)
    let other = browse(wrong)
    wrong.store.close()
    if !legacy || contents.count >= 16 {
        // (The old encryption checks one byte only; a short member can pass it by chance.)
        fzCheck(
            !other.contents.values.contains { [UInt8]($0) == contents } || contents.isEmpty,
            "zippack-wrong-password-reads-the-contents", "legacy \(legacy)")
    }
}

func url(_ o: Opened, path: String) -> URL {
    var c = URLComponents(url: o.root, resolvingAgainstBaseURL: false)!
    c.path = path
    return c.url!
}

// MARK: - format-aware mutations

func le(_ d: [UInt8], _ at: Int, _ width: Int) -> UInt64 { Mutate.get(width: width, at: at, bigEndian: false, in: d) }

/// The offsets of the size, count and offset fields of a ZIP file's records.
func zipFields(_ d: [UInt8]) -> [Int] {
    var out: [Int] = []
    var i = 0
    while i + 4 <= d.count {
        if d[i] == 0x50, d[i + 1] == 0x4B {
            switch (d[i + 2], d[i + 3]) {
            case (1, 2):
                out += [4, 6, 8, 10, 12, 14, 16, 20, 24, 28, 30, 32, 34, 36, 38, 42].map { i + $0 }
                i += 46
                continue
            case (3, 4):
                out += [4, 6, 8, 10, 14, 18, 22, 26, 28].map { i + $0 }
                i += 30
                continue
            case (5, 6):
                out += [4, 6, 8, 10, 12, 16, 20].map { i + $0 }
                i += 22
                continue
            case (6, 6):
                out += [4, 12, 14, 16, 20, 24, 32, 40, 48].map { i + $0 }
                i += 56
                continue
            case (6, 7):
                out += [4, 8, 16].map { i + $0 }
                i += 20
                continue
            case (7, 8):
                out += [4, 8, 12].map { i + $0 }
                i += 16
                continue
            default: break
            }
        }
        // extra fields: zip64 and the time stamps
        if i + 4 <= d.count,
            (d[i] == 1 && d[i + 1] == 0) || (d[i] == 0x55 && d[i + 1] == 0x54) || (d[i] == 0x75 && d[i + 1] == 0x78)
        {
            out += [i + 2, i + 4, i + 12, i + 20]
        }
        i += 1
    }
    return out
}

let hostileNames: [[UInt8]] = [
    "../", "/", "..\\", "../canary/", "./", "//", "..", "a/../", "\0", "ln/", "up/canary/", "C:\\", "~/", "keep.txt",
    "hl", "ln", "up/",
    "..\u{301}/", "/\u{301}../", "x/\u{301}../../canary/"
].map { Array($0.utf8) }

func zipCustom(_ d: inout [UInt8], _ rng: inout Rng) {
    // The name of a member, in the directory and in its local header, starts with a way out.
    var heads: [(at: Int, nameAt: Int, lenAt: Int)] = []
    var i = 0
    while i + 4 <= d.count {
        if d[i] == 0x50, d[i + 1] == 0x4B, d[i + 2] == 1, d[i + 3] == 2 { heads.append((i, i + 46, i + 28)) }
        if d[i] == 0x50, d[i + 1] == 0x4B, d[i + 2] == 3, d[i + 3] == 4 { heads.append((i, i + 30, i + 26)) }
        i += 1
    }
    guard !heads.isEmpty else { return }
    let h = rng.pick(heads)
    let length = Int(le(d, h.lenAt, 2))
    switch rng.below(6) {
    case 0, 1:  // written over the start of the name
        let name = rng.pick(hostileNames)
        for (k, b) in name.enumerated() where k < length && h.nameAt + k < d.count { d[h.nameAt + k] = b }
    case 2:  // inserted, with the length corrected (later offsets shift: the directory is then found or not)
        let name = rng.pick(hostileNames)
        guard h.nameAt <= d.count, length + name.count <= 0xFFFF else { return }
        d.insert(contentsOf: name, at: h.nameAt)
        Mutate.put(UInt64(length + name.count), width: 2, at: h.lenAt, bigEndian: false, in: &d)
    case 3:  // the type of the member: link, folder, device
        guard h.at + 42 <= d.count, d[h.at + 2] == 1 else { return }
        let mode: UInt64 = rng.pick([0o120777, 0o040755, 0o100644, 0o020644, 0o104755, 0o060000, 0o010000, 0])
        Mutate.put(mode << 16 | UInt64(rng.below(64)), width: 4, at: h.at + 38, bigEndian: false, in: &d)
        d[h.at + 5] = rng.chance(4) ? UInt8(rng.below(20)) : 3
    case 4:  // flags and method
        let off = d[h.at + 2] == 1 ? 8 : 6
        Mutate.put(
            rng.pick([0, 1, 8, 0x41, 0x800, 0x809, 0x2000, 0xFFFF]), width: 2, at: h.at + off, bigEndian: false, in: &d
        )
        Mutate.put(rng.pick([0, 8, 9, 12, 14, 99, 0xFFFF]), width: 2, at: h.at + off + 2, bigEndian: false, in: &d)
    default:  // sizes say "see the zip64 field"
        let off = d[h.at + 2] == 1 ? 20 : 18
        Mutate.put(0xFFFF_FFFF, width: 4, at: h.at + off + (rng.chance(2) ? 4 : 0), bigEndian: false, in: &d)
        if d[h.at + 2] == 1, rng.chance(2) {
            Mutate.put(0xFFFF_FFFF, width: 4, at: h.at + 42, bigEndian: false, in: &d)
        }
    }
}

func tarFixChecksum(_ d: inout [UInt8], block at: Int) {
    guard at + 512 <= d.count else { return }
    var sum = 0
    for i in 0..<512 { sum += (148..<156).contains(i) ? 32 : Int(d[at + i]) }
    let text = Array(String(sum, radix: 8).utf8)
    let padded = [UInt8](repeating: 48, count: max(0, 6 - text.count)) + text
    for (k, b) in padded.prefix(6).enumerated() { d[at + 148 + k] = b }
    d[at + 154] = 0
    d[at + 155] = 32
}

/// Blocks that are, or were, headers: "ustar" where the magic belongs.
func tarHeaders(_ d: [UInt8]) -> [Int] {
    var out: [Int] = []
    var at = 0
    while at + 512 <= d.count {
        if Array(d[(at + 257)..<(at + 262)]) == [117, 115, 116, 97, 114] { out.append(at) }
        at += 512
    }
    if out.isEmpty, d.count >= 512 { out.append(0) }
    return out
}

func tarFields(_ d: [UInt8]) -> [Int] {
    tarHeaders(d).flatMap { [$0 + 124, $0 + 128, $0 + 136, $0 + 100, $0 + 483, $0 + 386, $0 + 398] }
}

func putText(_ text: [UInt8], _ d: inout [UInt8], at: Int, length: Int) {
    for k in 0..<length where at + k < d.count { d[at + k] = k < text.count ? text[k] : 0 }
}

func tarCustom(_ d: inout [UInt8], _ rng: inout Rng) {
    let heads = tarHeaders(d)
    guard !heads.isEmpty else { return }
    if rng.chance(6) {
        for h in heads { tarFixChecksum(&d, block: h) }
        return
    }
    let h = rng.pick(heads)
    guard h + 512 <= d.count else { return }
    switch rng.below(9) {
    case 0, 1:  // the size: octal, or binary with the top bit
        if rng.chance(2) {
            let v = rng.pick(interesting)
            d[h + 124] = rng.chance(4) ? 0xFF : 0x80
            for k in 0..<3 { d[h + 125 + k] = rng.chance(8) ? 0xFF : 0 }
            Mutate.put(v, width: 8, at: h + 128, bigEndian: true, in: &d)
        } else {
            let v = rng.pick(
                [
                    0, 1, 5, 511, 512, 513, 0o77777777777, 0o7777777777, 1 << 20, UInt64(d.count),
                    UInt64(max(0, d.count - h - 512)), UInt64(max(0, d.count - h - 511))
                ] as [UInt64])
            putText(Array((String(v, radix: 8)).utf8), &d, at: h + 124, length: 12)
        }
    case 2:  // the type
        d[h + 156] = rng.pick([48, 49, 50, 51, 52, 53, 54, 55, 76, 75, 120, 103, 83, 0, 77, 78, 86, 88, 65]) as UInt8
    case 3:  // the name
        let name = rng.pick(hostileNames)
        if rng.chance(2) {
            for (k, b) in name.enumerated() where k < 100 { d[h + k] = b }
        } else {
            putText(name + Array("pwn.txt".utf8), &d, at: h, length: 100)
        }
    case 4:  // the link target
        putText(
            rng.pick(
                ["../canary", "..", "/", "../canary/keep.txt", "ok.txt", ".", "", "ln", "hl", "../../", "a/../.."].map {
                    Array($0.utf8)
                }), &d, at: h + 157, length: 100)
        if rng.chance(2) { d[h + 156] = rng.chance(2) ? 49 : 50 }
    case 5:  // the prefix
        putText(rng.pick(hostileNames), &d, at: h + 345, length: 155)
    case 6:  // mode and time
        putText(
            Array(String(rng.pick(interesting), radix: 8).utf8.prefix(11)), &d, at: h + (rng.chance(2) ? 100 : 136),
            length: rng.chance(2) ? 8 : 12)
    case 7:  // the old GNU sparse fields
        d[h + 156] = 83
        d[h + 482] = rng.chance(2) ? 1 : 0
        putText(Array(String(rng.pick(interesting), radix: 8).utf8.prefix(11)), &d, at: h + 483, length: 12)
    default:  // a pax record in the block that follows
        guard h + 1024 <= d.count else { break }
        let key = rng.pick([
            "path", "linkpath", "size", "mtime", "GNU.sparse.size", "GNU.sparse.realsize", "GNU.sparse.name",
            "GNU.sparse.map", "GNU.sparse.major", "uid", "SCHILY.xattr.x", "hdrcharset"
        ])
        let value = rng.pick([
            "../canary/pwn", "/abs", "0", "-1", "99999999999999999999", "9223372036854775807", "18446744073709551615",
            "1e308", "nan", "1.5", "", "\0", "x/../../y", String(repeating: "A", count: 300)
        ])
        let body = " \(key)=\(value)\n"
        var length = body.utf8.count + 1
        while String(length).utf8.count + body.utf8.count != length {
            length = String(length).utf8.count + body.utf8.count
        }
        let record = Array(
            "\(rng.chance(6) ? rng.pick(["0", "1", "99999999999999999999", "-5", String(length + 1), String(length - 1)]) : String(length))\(body)"
                .utf8)
        putText(record, &d, at: h + 512, length: min(512, record.count))
        d[h + 156] = rng.chance(4) ? 103 : 120
        putText(Array(String(record.count, radix: 8).utf8), &d, at: h + 124, length: 12)
    }
    tarFixChecksum(&d, block: h)
}

func readAll(_ stream: ByteStream, limit: Int = 4 << 20) -> [UInt8]? {
    var out = Data()
    defer { stream.close() }
    do {
        while let block = try stream.read(upToCount: 1 << 16) {
            out.append(block)
            if out.count > limit { return nil }
        }
    } catch { return out.isEmpty ? nil : [UInt8](out) }
    return [UInt8](out)
}

/// Mutates what a compressed archive holds and compresses it again, so that changes reach
/// the TAR reader behind the decompressor.
func recompressing(_ codec: ArchiveFormat.Codec) -> (inout [UInt8], inout Rng) -> Void {
    { d, rng in
        let source = DataStream(Data(d))
        let stream: ByteStream?
        switch codec {
        case .gzip: stream = InflateStream(source, wrapping: .gzip)
        case .xz: stream = try? XZStream(source)
        case .bzip2: stream = nil
        }
        guard let stream, var inner = readAll(stream), !inner.isEmpty else { return }
        for _ in 0..<(1 + rng.below(3)) {
            if rng.chance(2) {
                tarCustom(&inner, &rng)
            } else {
                Mutate.one(&inner, rng: &rng, other: [], dict: hostileNames, fields: tarFields(inner))
            }
        }
        if inner.count > 60_000 { inner.removeSubrange(60_000...) }
        switch codec {
        case .gzip:
            let deflater = Deflater(level: 6)
            let body = deflater.compress(Data(inner), flush: .finish)
            var out: [UInt8] = [0x1F, 0x8B, 8, 0, 0, 0, 0, 0, 0, 3] + [UInt8](body)
            let crc = CRC32.of(Data(inner))
            for k in 0..<4 { out.append(UInt8(truncatingIfNeeded: crc >> UInt32(k * 8))) }
            for k in 0..<4 {
                out.append(UInt8(truncatingIfNeeded: UInt32(truncatingIfNeeded: inner.count) >> UInt32(k * 8)))
            }
            d = out
        case .xz:
            if let out = try? XZCoder.compress(Data(inner)) { d = [UInt8](out) }
        case .bzip2: break
        }
    }
}

// MARK: - seeds made by the program's own Packer

func makeOwnSeeds(_ dir: String) {
    let tree = dir + "/work.tmp/tree"
    try? fm.createDirectory(atPath: tree + "/sub/hollow", withIntermediateDirectories: true)
    fm.createFile(atPath: tree + "/a.txt", contents: Data("hello from the packer\n".utf8))
    fm.createFile(atPath: tree + "/empty", contents: Data())
    fm.createFile(atPath: tree + "/sub/übung – 日本.txt", contents: Data(String(repeating: "jack ", count: 200).utf8))
    try? fm.createSymbolicLink(atPath: tree + "/link", withDestinationPath: "a.txt")
    let store = ArchiveStore(environment: environment)
    let registry = FileSystemRegistry()
    [
        local, ArchiveFileSystem(scheme: ArchiveURL.writableScheme, store: store),
        ArchiveFileSystem(scheme: ArchiveURL.readOnlyScheme, store: store)
    ].forEach(registry.register)
    environment.fileSystems = { registry }
    let formats: [(String, ArchiveFormat, String?, String)] = [
        ("zip", .zip, nil, "own.zip"), ("zip", .zip, "secret", "own-crypt.zip"),
        ("zip", .zip, "secret", "own-crypt-aes.zip"), ("tar", .tar, nil, "own.tar"),
        ("tgz", .compressedTar(.gzip), nil, "own.tar.gz"), ("txz", .compressedTar(.xz), nil, "own.tar.xz"),
        ("bz", .compressedTar(.bzip2), nil, "own.tar.bz2"),
        ("tgz", .compressedFile(.gzip), nil, "own.gz"), ("txz", .compressedFile(.xz), nil, "own.xz")
    ]
    for (sub, format, password, name) in formats {
        var options = PackOptions()
        options.format = format
        options.password = password
        // The program's default is AES-256; the seed of the old encryption is kept beside it.
        if name == "own-crypt.zip" { options.encryption = .legacy }
        let packer = Packer(fileSystems: registry, store: store, monitor: QuietMonitor(), options: options)
        let single = {
            guard case .compressedFile = format else { return false }
            return true
        }()
        guard let item = registry.item(at: URL(fileURLWithPath: single ? tree + "/a.txt" : tree)) else {
            print("no item")
            continue
        }
        let result = packer.run([item], archive: URL(fileURLWithPath: dir + "/" + sub + "/" + name))
        print(name, result.failure.map { "FAILED \($0)" } ?? "ok")
    }
    // A ZIP holding another archive, by the packer as well.
    if let a = registry.item(at: URL(fileURLWithPath: dir + "/tar/own.tar")),
        let b = registry.item(at: URL(fileURLWithPath: tree + "/a.txt"))
    {
        let packer = Packer(fileSystems: registry, store: store, monitor: QuietMonitor(), options: PackOptions())
        print(
            "own-nested.zip",
            packer.run([a, b], archive: URL(fileURLWithPath: dir + "/zip/own-nested.zip")).failure.map {
                "FAILED \($0)"
            } ?? "ok")
    }
    store.close()
    try? fm.removeItem(atPath: dir + "/work.tmp")
}

var toolWorkDir: String?
func fzSetWorkDirForTools(_ dir: String) {
    toolWorkDir = dir
    try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
    setenv("TMPDIR", dir, 1)
}

if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "mkseeds" {
    // setUpArchives reads fzWorkDir, which only a worker has; the scratch folder follows TMPDIR.
    let dir = CommandLine.arguments[2]
    fzSetWorkDirForTools(dir + "/work.tmp")
    environment = ArchiveEnvironment()
    environment.flushDelay = nil
    local = LocalFileSystem()
    makeOwnSeeds(dir)
    exit(0)
}

let zipDict = [
    "PK\u{1}\u{2}", "PK\u{3}\u{4}", "PK\u{5}\u{6}", "PK\u{6}\u{6}", "PK\u{6}\u{7}", "PK\u{7}\u{8}", "../", "/", "\\",
    "\u{1}\u{0}", "UT", "ux", "\u{1}\u{99}"
]
let tarDict = [
    "ustar\u{0}00", "ustar  \u{0}", "../", "/", "././@LongLink", "PaxHeader/", "path=", "size=", "linkpath=",
    "GNU.sparse.", "\n", " ", "=", "0000000", "77777777777"
]

fuzzMain([
    FuzzTarget(
        "ziplist", maxLen: 12_000, dict: zipDict, fields: zipFields, custom: zipCustom, setUp: setUpArchives,
        run: { runList($0, name: "a.zip") }),
    FuzzTarget(
        "tarlist", maxLen: 24_000, dict: tarDict, fields: tarFields, custom: tarCustom, setUp: setUpArchives,
        run: { runList($0, name: "a.tar") }),
    FuzzTarget(
        "tgzlist", maxLen: 8_000, dict: tarDict + ["\u{1F}\u{8B}\u{8}"], custom: recompressing(.gzip),
        setUp: setUpArchives, run: { runList($0, name: "a.tar.gz") }),
    FuzzTarget(
        "txzlist", maxLen: 8_000, dict: tarDict + ["\u{FD}7zXZ\u{0}", "YZ"], custom: recompressing(.xz),
        setUp: setUpArchives, run: { runList($0, name: "a.tar.xz") }),
    FuzzTarget(
        "zip", maxLen: 12_000, dict: zipDict, fields: zipFields, custom: zipCustom, setUp: setUpArchives,
        run: { runArchive($0, name: "a.zip") }),
    FuzzTarget(
        "zippack", maxLen: 4_000,
        seeds: {
            [
                Array("\u{0}\u{5}secret\u{5}a.txthello from the packer, hello from the packer\n".utf8),
                [0x60, 3, 0xC3, 0xA9, 0x21, 2, 0x78, 0x79] + Array(repeating: 0x41, count: 64),
                [0x0F, 2, 0x70, 0x77, 1, 0x66] + Array("old encryption on request, sixteen bytes and more".utf8),
                [0x45, 1, 0x70, 0] + (0..<200).map { UInt8($0) }
            ]
        },
        setUp: setUpArchives, run: runZipPack),
    FuzzTarget(
        "zipmod", maxLen: 12_000, dict: zipDict, fields: zipFields, custom: zipCustom, setUp: setUpArchives,
        run: { runZipModify($0) }),
    FuzzTarget(
        "tar", maxLen: 24_000, dict: tarDict, fields: tarFields, custom: tarCustom, setUp: setUpArchives,
        run: { runArchive($0, name: "a.tar") }),
    FuzzTarget(
        "tgz", maxLen: 8_000, dict: tarDict + ["\u{1F}\u{8B}\u{8}"], custom: recompressing(.gzip), setUp: setUpArchives,
        run: { runArchive($0, name: "a.tar.gz") }),
    FuzzTarget(
        "txz", maxLen: 8_000, dict: tarDict + ["\u{FD}7zXZ\u{0}", "YZ"], custom: recompressing(.xz),
        setUp: setUpArchives, run: { runArchive($0, name: "a.tar.xz") }),
    FuzzTarget(
        "bz", maxLen: 4_000, dict: ["BZh9", "1AY&SY"], setUp: setUpArchives,
        run: { runArchive($0, name: "a.tar.bz2") })
])

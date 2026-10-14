import Foundation
import FuzzCore
import AFMKernel
@testable import NetworkPlugin

// Network parsers: what a server (or a saved file) sends is parsed the way the sessions do it.

func text(_ b: [UInt8]) -> String { String(decoding: b, as: UTF8.self) }
func lines(_ b: [UInt8]) -> [[UInt8]] { b.split(separator: 0x0A, omittingEmptySubsequences: false).map { var l = Array($0); if l.last == 0x0D { l.removeLast() }; return l } }
let base = URL(string: "ftp://example.com/dir/")!
let fixedNow = Date(timeIntervalSince1970: 1_700_000_000)

func check(_ entry: RemoteEntry?) {
    guard let entry else { return }
    // What becomes a row of a panel: a name that is one path component.
    fzCheck(RemoteEntry.isSafeName(entry.name) || entry.name.contains("\\"), "ftplist-unsafe-name", entry.name.debugDescription)
    // By bytes: a `/` that carries a combining mark is one character with it, and still a separator.
    let raw = Array(entry.name.utf8)
    fzCheck(!raw.contains(0x2F) && raw != [0x2E] && raw != [0x2E, 0x2E] && !raw.isEmpty && !raw.contains(0), "ftplist-name-is-a-path", entry.name.debugDescription)
    _ = entry.item(in: base)
}

let ftpList = FuzzTarget("ftplist", maxLen: 2048,
    dict: ["type=file;", "type=dir;", "type=cdir;", "type=pdir;", "type=OS.unix=slink:/x;", "size=", "sizd=", "modify=20240102030405;", "perm=", "unix.mode=0755;", "UNIX.mode=", " -> ", "drwxr-xr-x", "lrwxrwxrwx", "-rw-r--r--", "+i8388621.29609,m824255902,/,\t", "+s", ",r,", "<DIR>", "01-02-24  03:04PM", "AM", "PM", " Jan ", " janv. ", " 2024 ", " 12:34 ", "2024-01-31 12:34 ", "total 12", "\t", ";", "=", "../", "/", "..", "99999999999999999999", "-1", "\u{0}", "\r"],
    seeds: { ["type=file;size=12;modify=20240102030405;perm=adfr;unix.mode=0644; name.txt", "type=dir;modify=20240102030405.123; sub dir", "type=cdir; .", "type=pdir; ..", "type=OS.unix=slink:/target;size=3; link", " type=file;size=5; /path/to/name",
               "-rw-r--r--   1 user group     1234 Jan  2 03:04 file.txt", "drwxr-xr-x 2 0 0 4096 Jan 02  2020 dir", "lrwxrwxrwx 1 u g 4 Feb 29 12:00 link -> target", "-rwsr-sr-t 1 u g 99999999999999999999 31 Dec 2099 big", "-rw-r--r-- 1 u g 12 2024-01-31 12:34:56.789 +0100 iso name", "crw-rw-rw- 1 root wheel 3, 2 Jan 1 00:00 null",
               "01-02-24  03:04PM       <DIR>          Program Files", "12-31-1999  11:59AM              1234 file.exe", "+i8388621.29609,m824255902,/,\tdev", "+i8388621.44468,m839956783,r,s10376,\tRFCEPLF", "+up644,s0,m99999999999999999999,\tx", "total 42",
               "-rw-r--r-- 1 u g 5 Jan 2 03:04 a\n-rw-r--r-- 1 u g 5 2 Jan 03:04 b\ntype=file;size=1; c\n+s1,\td\n01-02-24 03:04AM 5 e"].map { Array($0.utf8) } },
    run: { bytes in
        var decoded: [String] = []
        for (index, raw) in lines(bytes).enumerated() {
            // Names come in the server's encoding; the choice of the decoder goes with the line.
            let encoding = NameEncoding.allCases[index % NameEncoding.allCases.count]
            let line = index % 3 == 0 ? text(raw) : encoding.decode(Data(raw))
            decoded.append(line)
            check(FTPListParser.mlsd(line))
            _ = FTPListParser.mlst(line).map { $0.item(in: base) }
            check(FTPListParser.list(line, now: fixedNow))
        }
        FTPListParser.entries(of: decoded, asMLSD: true, now: fixedNow).forEach(check)
        FTPListParser.entries(of: decoded, asMLSD: false, now: fixedNow).forEach(check)
    })

let ftpReply = FuzzTarget("ftpreply", maxLen: 2048,
    dict: ["227 Entering Passive Mode (192,168,1,2,19,137)", "229 Entering Extended Passive Mode (|||6446|)", "211-Features:", "211 End", " MLST type*;size*;modify*;", " UTF8", "257 \"/a \"\"quoted\"\" name\" created", "213 20240102030405.123", "220-", "220 ", "-", "(", ")", "|", ",", "\"", "\"\"", "99999999999999999999", "256", "65536", "0,0,0,0,0,0", ";;", ";", "+ ", "- ", "\\"],
    seeds: { ["220-Welcome\n line two\n220 ready\n227 Entering Passive Mode (192,168,1,2,19,137)\n229 Entering Extended Passive Mode (|||6446|)\n211-Features:\n MLST type*;size*;\n UTF8\n211 End\n257 \"/a \"\"q\"\" n\" created\n213 20240102030405\n", "150\n226-x\n226\n", "500 no\n227 =1,2,3,4,5,6\n229 (!!!1!)\n", "SITE A;;B; SITE C ;\nsrc -> dst\n+ a/b\n- c\n"].map { Array($0.utf8) } },
    run: { bytes in
        var parser = FTPReplyParser()
        for raw in lines(bytes) {
            let line = text(raw)
            if let reply = parser.feed(line) {
                fzCheck((0...999).contains(reply.code), "ftpreply-code", "\(reply.code)")
                _ = FTPSyntax.features(reply)
                _ = FTPConnection.requiresSessionReuse(reply)
                for l in reply.lines { _ = FTPSyntax.quotedPath(l) }
            }
            if let port = FTPSyntax.extendedPassivePort(line) { fzCheck((1...65535).contains(port), "epsv-port", "\(port) from \(line.debugDescription)") }
            if let end = FTPSyntax.passiveEndpoint(line) {
                fzCheck((1...65535).contains(end.port), "pasv-port", "\(end.port) from \(line.debugDescription)")
                _ = FTPSyntax.portArgument(host: end.host, port: end.port)
                _ = FTPSyntax.extendedPortArgument(host: end.host, port: end.port)
            }
            _ = FTPSyntax.quotedPath(line)
            if let time = FTPSyntax.time(line) { _ = FTPSyntax.timeText(time) }
            _ = FTPSyntax.portArgument(host: line, port: raw.count)
            _ = FTPServerConfig.initCommands(from: line)
        }
        _ = DownloadList.parse(text(bytes))
    })

func exercise(_ c: SavedConnection) {
    _ = c.key.description; _ = c.hostText; _ = c.listTitle
    let p = c.profile
    _ = p.key.url(path: c.remoteDirectory)
    _ = ServerKey(p.key.url())
}

let address = FuzzTarget("address", maxLen: 1024,
    dict: ["ftp://", "ftps://", "sftp://", "ftpes://", "://", "@", ":", "/", "[", "]", "[::1]", "%", "%00", "%2F", "%40", "%ZZ", "%E0%A4%A", "99999999999999999999", ":0", ":65536", ":-1", ":21", "user:pass@", "//", "?", "#", " ", "\u{0}", "..", "é", "xn--"],
    seeds: { ["ftp://user:p%40ss@host.example.com:2121/pub/dir", "sftp://[2001:db8::1]:22/home", "host", "host:21", "ftps://host/", "user@host/path with space/%41", "ftp://a:b:c@d@e:99/", "[::1]", "sftp://u@h/~/../x//y/./z", "ftp://host:99999999999999999999/", "://", "ftp://%zz:%@:/"].map { Array($0.utf8) } },
    run: { bytes in
        for raw in lines(bytes).prefix(8) {
            let s = text(raw)
            for scheme in ["ftp", "sftp", "ftps"] {
                guard let a = ServerAddress(s, defaultScheme: scheme) else { continue }
                fzCheck(a.path.hasPrefix("/"), "address-path-not-absolute", "\(s.debugDescription) -> \(a.path.debugDescription)")
                let shown = a.textWithoutPassword
                // (The user name is shown percent-encoded: its escapes may spell the password by chance.)
                let shownUser = (a.user ?? "").addingPercentEncoding(withAllowedCharacters: .urlUserAllowed) ?? ""
                if let p = a.password, p.count >= 6, !(a.user ?? "").contains(p), !shownUser.contains(p), !a.host.contains(p), !a.path.contains(p), !a.scheme.contains(p), !String(a.port).contains(p) {
                    fzCheck(!shown.contains(p), "address-password-shown", "\(s.debugDescription) -> \(shown.debugDescription)")
                }
                _ = ServerAddress(shown, defaultScheme: scheme)
                let key = ServerKey(scheme: a.scheme, host: a.host, port: a.port)
                let url = key.url(path: a.path)
                _ = ServerKey(url); _ = RemotePath.of(url); _ = key.description
            }
            _ = ServerAddress.removingPassword(from: s)
            _ = ServerKey.bare(s)
            let n = RemotePath.normalized(s)
            // By bytes, as a server reads the path: it begins with a slash and no part of it is empty, `.` or `..`.
            let parts = Array(n.utf8).split(separator: 0x2F, omittingEmptySubsequences: false).map(Array.init)
            fzCheck(n.utf8.first == 0x2F && (n.utf8.count == 1 || !parts.dropFirst().contains([])) && !parts.contains([0x2E, 0x2E]) && !parts.contains([0x2E]),
                    "remotepath-normalized", "\(s.debugDescription) -> \(n.debugDescription)")
            _ = RemotePath.parent(of: s); _ = RemotePath.name(of: s); _ = RemotePath.join(s, s)
            if let u = URL(string: s) { _ = ServerKey(u); _ = RemotePath.of(u) }
            var c = SavedConnection()
            for kind in SavedConnection.Kind.allCases { if c.setHost(s, kind: kind) { exercise(c) } }
            _ = SFTPSession.asksForPassword(s, of: ConnectionProfile(key: ServerKey(scheme: "sftp", host: "host"), user: "u"))
        }
    })

let saved = FuzzTarget("saved", maxLen: 4096,
    dict: ["\"id\"", "\"name\"", "\"kind\"", "\"host\"", "\"port\"", "\"user\"", "\"anonymous\"", "\"remoteDirectory\"", "\"localDirectory\"", "\"passive\"", "\"encoding\"", "\"listing\"", "\"initCommands\"", "null", "true", "-1", "99", "1e99", "9223372036854775808", "[", "]", "{", "}", ",", ":", "\"\"", "\\u0000", "\\ud800"],
    seeds: {
        var c = SavedConnection(); c.name = "Work"; c.host = "ftp.example.com"; c.port = 2121; c.user = "me"; c.remoteDirectory = "pub/../x"; c.initCommands = "SITE A;;B;C"
        var d = SavedConnection(); d.kind = SavedConnection.Kind.allCases.last!; d.host = "::1"; d.encoding = .shiftJIS; d.listing = .mlsd
        let json = (try? JSONEncoder().encode([c, d])) ?? Data()
        return [[UInt8](json), Array("[]".utf8), Array("[{}]".utf8)]
    },
    run: { bytes in
        let data = Data(bytes)
        // As the settings store hands it out: the stored value decoded into the model.
        let settings = MemorySettings()
        if let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) {
            if let list = try? JSONDecoder().decode([SavedConnection].self, from: data) { settings.set(list, forKey: "network.connections"); list.forEach(exercise) }
            if let texts = object as? [String] { settings.set(texts, forKey: "network.history") }
            if let trusted = object as? [String: [String]] { settings.set(trusted, forKey: "network.trustedCertificates") }
        }
        if let one = try? JSONDecoder().decode(SavedConnection.self, from: data) { exercise(one) }
        let store = ConnectionStore(settings: settings, passwords: MemoryPasswords())
        for c in store.connections { exercise(c); store.save(c); _ = store.connection(named: c.name) }
        for h in store.history { if let a = ServerAddress(h) { store.remember(address: a) } }
        _ = store.lastUsed; _ = store.trustedCertificates
    })

/// The body of a packet as the session reads the answers it expects.
func decodeAs(_ kind: SFTPPacket.Kind, _ body: Data) {
    let packet = SFTPPacket(kind: kind, body: body)
    _ = packet.statusCode
    _ = try? packet.checkStatus()
    // readdir
    if var decoder = try? packet.expect(.name) {
        var entries: [RemoteEntry] = []
        do {
            for _ in 0..<(try decoder.u32()) {
                let name = try decoder.string()
                _ = try decoder.bytes()
                let attributes = try decoder.attributes()
                if RemoteEntry.isSafeName(name) { entries.append(attributes.entry(named: name)) }
            }
        } catch {}
        for e in entries { _ = e.item(in: base) }
    }
    // realpath
    if var names = try? packet.expect(.name) { _ = try? names.u32(); if let s = try? names.string() { _ = RemotePath.normalized(s) } }
    if var d = try? packet.expect(.attributes), let a = try? d.attributes() { _ = a.entry(named: "x").item(in: base) }
    if var d = try? packet.expect(.handle) { _ = try? d.bytes() }
    if var d = try? packet.expect(.data) { _ = try? d.bytes(); _ = d.isAtEnd }
    if var d = try? packet.expect(.extendedReply) { _ = try? d.u64(); _ = try? d.u64(); _ = try? d.u8() }
    if var d = try? packet.expect(.version) { _ = try? d.u32(); while !d.isAtEnd { guard (try? d.string()) != nil, (try? d.string()) != nil else { break } } }
}

let sftpDecode = FuzzTarget("sftpdec", maxLen: 2048,
    seeds: {
        var e = SFTPEncoder()
        e.u32(2); e.string("file.txt"); e.string("-rw-r--r-- 1 u g 5 Jan 1 00:00 file.txt"); e.u32(0x8000_000F); e.u64(5); e.u32(501); e.u32(20); e.u32(0o100644); e.u32(1); e.u32(1_600_000_000); e.u32(1); e.string("k"); e.string("v")
        e.string("dir"); e.string("long"); e.u32(4); e.u32(0o040755)
        var s = SFTPEncoder(); s.u32(2); s.string("No such file"); s.string("en")
        return [[104] + [UInt8](e.data), [101] + [UInt8](s.data), [105, 0, 0, 0, 5, 0, 0, 0, 0, 0, 0, 0, 9, 0, 0, 0x81, 0xA4], [102, 0, 0, 0, 4, 1, 2, 3, 4], [103, 0, 0, 0, 3, 65, 66, 67], [2, 0, 0, 0, 3, 0, 0, 0, 1, 97, 0, 0, 0, 1, 98]]
    },
    run: { bytes in
        guard let first = bytes.first else { return }
        // The payload as the reading thread hands it on: a view into a larger buffer, the type cut off, then the request number.
        let payload = Data([0, 0, 0, 0] + bytes).dropFirst(4)
        let body = payload.dropFirst()
        let kinds: [SFTPPacket.Kind] = [.version, .status, .handle, .data, .name, .attributes, .extendedReply, .closed]
        if let kind = SFTPPacket.Kind(rawValue: first) { decodeAs(kind, body); decodeAs(kind, body.dropFirst(min(4, body.count))) }
        for kind in kinds { decodeAs(kind, body) }
    })

/// A whole session against a "server" that says what the input holds: the answers are framed
/// here (length, type, the request numbers in the order the session asks), their bodies are
/// the input's. One process (`/bin/cat`) per input.
func conversation(_ bytes: [UInt8]) -> Data {
    var c = Choices(bytes)
    var out: [UInt8] = []
    func be(_ v: UInt32) -> [UInt8] { [UInt8(v >> 24), UInt8(v >> 16 & 255), UInt8(v >> 8 & 255), UInt8(v & 255)] }
    func packet(_ kind: UInt8, id: UInt32?, _ body: [UInt8]) {
        out += be(UInt32(1 + (id == nil ? 0 : 4) + body.count)) + [kind]
        if let id { out += be(id) }
        out += body
    }
    packet(2, id: nil, [0, 0, 0, 3])
    var id: UInt32 = 1
    let kinds: [UInt8] = [101, 102, 103, 104, 105, 201, 104, 104, 102]
    while !c.atEnd, id < 40 {
        let kind = kinds[c.int(kinds.count)]
        let length = c.int(4) == 0 ? Int(c.u16()) % 600 : Int(c.byte())
        packet(kind, id: c.int(16) == 0 ? UInt32(c.byte()) : id, c.take(length))
        id += 1
    }
    return Data(out)
}

var sftpEnvironment: SessionEnvironment!
let sftpSession = FuzzTarget("sftpsession", maxLen: 3000,
    seeds: {
        func be(_ v: UInt32) -> [UInt8] { [UInt8(v >> 24), UInt8(v >> 16 & 255), UInt8(v >> 8 & 255), UInt8(v & 255)] }
        func str(_ s: String) -> [UInt8] { be(UInt32(s.utf8.count)) + Array(s.utf8) }
        func part(_ kind: UInt8, _ body: [UInt8]) -> [UInt8] { [kind, 1, UInt8(body.count), 1] + body }   // kind index, short length, own id
        let realpath = be(1) + str("/home/u") + str("/home/u") + be(0)
        let handle = str("H1")
        let names = be(2) + str("a.txt") + str("long") + be(5) + [0, 0, 0, 0, 0, 0, 0, 9] + be(0o100644) + str("ln") + str("long") + be(4) + be(0o120777)
        let attrs = be(4) + be(0o040755)
        let eof = be(1) + str("eof") + str("")
        let ok = be(0) + str("") + str("")
        let data = str("file data")
        // kinds index: 0 status, 1 handle, 2 data, 3 name, 4 attributes
        return [part(3, realpath) + part(1, handle) + part(3, names) + part(4, attrs) + part(0, eof) + part(0, ok) + part(4, attrs) + part(1, handle) + part(2, data) + part(0, eof) + part(0, ok)]
    },
    setUp: {
        let options = NetworkOptions()
        var values = options.values; values.timeout = 1; options.values = values
        sftpEnvironment = SessionEnvironment(options: options)
        sftpEnvironment.declineMemory = 0
    },
    run: { bytes in
        let file = fzWorkDir + "/conversation.bin"
        FileManager.default.createFile(atPath: file, contents: conversation(bytes))
        let profile = ConnectionProfile(key: ServerKey(scheme: "sftp", host: "fuzz.invalid"), user: "u")
        let session = SFTPSession(profile: profile, environment: sftpEnvironment, transport: SFTPTransport(executable: "/bin/cat", arguments: [file]))
        defer { session.disconnect() }
        guard let home = try? session.connect(cancellation: nil) else { return }
        var seen: [RemoteEntry] = []
        try? session.list(home, showHidden: true, cancellation: nil) { seen += $0; return seen.count < 10_000 }
        for e in seen { _ = e.item(in: base) }
        _ = try? session.entry(at: home + "/a.txt", cancellation: nil)
        if let reader = try? session.openRead(home + "/a.txt", cancellation: nil) {
            var total = 0
            while let block = try? reader.read(upToCount: 32_768), total < 1 << 20 { total += block.count }
            reader.close()
        }
    })

fuzzMain([ftpList, ftpReply, address, saved, sftpDecode, sftpSession])

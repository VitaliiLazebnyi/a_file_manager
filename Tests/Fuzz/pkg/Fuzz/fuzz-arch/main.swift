import Foundation
import FuzzCore

@testable import ArchivesPlugin

// Archives: a mutated archive file is opened the way a panel opens it (ArchiveStore →
// ArchiveFileSystem), listed completely, every member is read to its end, and the whole
// archive is unpacked with the Unpacker into a folder next to a canary folder (Containment.swift).
// `fuzz-arch mkseeds <dir>` packs seeds with the program's own Packer instead.

if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "mkseeds" {
    // ArchiveRig.setUp reads fzWorkDir, which only a worker has; the scratch folder follows TMPDIR.
    let dir = CommandLine.arguments[2]
    ArchiveRig.setUpForSeeds(scratch: dir + "/work.tmp")
    makeOwnSeeds(dir)
    exit(0)
}

/// The tokens of ZIP records and fields.
internal let kZipDict = [
    "PK\u{1}\u{2}", "PK\u{3}\u{4}", "PK\u{5}\u{6}", "PK\u{6}\u{6}", "PK\u{6}\u{7}", "PK\u{7}\u{8}", "../", "/", "\\",
    "\u{1}\u{0}", "UT", "ux", "\u{1}\u{99}"
]

/// The tokens of TAR headers and pax records.
internal let kTarDict = [
    "ustar\u{0}00", "ustar  \u{0}", "../", "/", "././@LongLink", "PaxHeader/", "path=", "size=", "linkpath=",
    "GNU.sparse.", "\n", " ", "=", "0000000", "77777777777"
]

fuzzMain([
    FuzzTarget(
        "ziplist",
        maxLen: 12_000,
        dict: kZipDict,
        fields: zipFields,
        custom: zipCustom,
        setUp: ArchiveRig.setUp
    ) { runList($0, name: "a.zip") },
    FuzzTarget(
        "tarlist",
        maxLen: 24_000,
        dict: kTarDict,
        fields: tarFields,
        custom: tarCustom,
        setUp: ArchiveRig.setUp
    ) { runList($0, name: "a.tar") },
    FuzzTarget(
        "tgzlist",
        maxLen: 8_000,
        dict: kTarDict + ["\u{1F}\u{8B}\u{8}"],
        custom: recompressing(.gzip),
        setUp: ArchiveRig.setUp
    ) { runList($0, name: "a.tar.gz") },
    FuzzTarget(
        "txzlist",
        maxLen: 8_000,
        dict: kTarDict + ["\u{FD}7zXZ\u{0}", "YZ"],
        custom: recompressing(.xz),
        setUp: ArchiveRig.setUp
    ) { runList($0, name: "a.tar.xz") },
    FuzzTarget(
        "zip",
        maxLen: 12_000,
        dict: kZipDict,
        fields: zipFields,
        custom: zipCustom,
        setUp: ArchiveRig.setUp
    ) { runArchive($0, name: "a.zip") },
    FuzzTarget("zippack", maxLen: 4_000, seeds: zipPackSeeds, setUp: ArchiveRig.setUp, run: runZipPack),
    FuzzTarget(
        "zipmod",
        maxLen: 12_000,
        dict: kZipDict,
        fields: zipFields,
        custom: zipCustom,
        setUp: ArchiveRig.setUp,
        run: runZipModify
    ),
    FuzzTarget(
        "tar",
        maxLen: 24_000,
        dict: kTarDict,
        fields: tarFields,
        custom: tarCustom,
        setUp: ArchiveRig.setUp
    ) { runArchive($0, name: "a.tar") },
    FuzzTarget(
        "tgz",
        maxLen: 8_000,
        dict: kTarDict + ["\u{1F}\u{8B}\u{8}"],
        custom: recompressing(.gzip),
        setUp: ArchiveRig.setUp
    ) { runArchive($0, name: "a.tar.gz") },
    FuzzTarget(
        "txz",
        maxLen: 8_000,
        dict: kTarDict + ["\u{FD}7zXZ\u{0}", "YZ"],
        custom: recompressing(.xz),
        setUp: ArchiveRig.setUp
    ) { runArchive($0, name: "a.tar.xz") },
    FuzzTarget("bz", maxLen: 4_000, dict: ["BZh9", "1AY&SY"], setUp: ArchiveRig.setUp) { bytes in
        runArchive(bytes, name: "a.tar.bz2")
    }
])

internal import Foundation
internal import FuzzC

/// The driver's entry point: reads the command line and runs `list`, `fuzz`, `worker`, `run` or `min` on one of
/// `targets`.
///
/// Never returns.
@preconcurrency
@MainActor
public func fuzzMain(_ targets: [FuzzTarget]) -> Never {
    setvbuf(stdout, nil, _IOLBF, 0)
    let arguments = Array(CommandLine.arguments.dropFirst())
    guard let mode = arguments.first else {
        print("usage: list | fuzz <target> --out DIR [--time S] | run <target> FILE... | min <target> FILE OUT")
        exit(2)
    }
    if mode == "list" {
        for target in targets {
            print(target.name)
        }
        exit(0)
    }
    guard arguments.count >= 2, let target = targets.first(where: { $0.name == arguments[1] }) else {
        print("unknown target; have: \(targets.map(\.name))")
        exit(2)
    }
    let rest = Array(arguments.dropFirst(2))
    switch mode {
    case "fuzz":
        FuzzSupervisor(target: target, options: FuzzOptions(rest)).run()

    case "worker":
        FuzzWorker(target: target, options: FuzzOptions(rest)).run()

    case "run":
        runOnce(target, rest)

    case "min":
        FuzzMinimiser(target: target).run(rest)

    default:
        print("unknown mode")
        exit(2)
    }
}

/// Runs each input file once (`run <target> FILE... [--timeout S] [--rss MB]`).
///
/// Exits 0 when none failed: a failure ends the process.
@MainActor
internal func runOnce(_ target: FuzzTarget, _ arguments: [String]) -> Never {
    var files: [String] = []
    var timeout = 2.0
    var rss = 2_048
    var index = 0
    while index < arguments.count {
        let hasValue = index + 1 < arguments.count
        if arguments[index] == "--timeout", hasValue {
            timeout = Double(arguments[index + 1]) ?? 2
            index += 1
        } else if arguments[index] == "--rss", hasValue {
            rss = Int(arguments[index + 1]) ?? 2_048
            index += 1
        } else {
            files.append(arguments[index])
        }
        index += 1
    }
    // Work files go below the system's temporary folder (or where FZ_WORK says), never next to the input.
    fzWorkDir = FuzzFiles.workBase() + "/fzrun-\(getpid())"
    FuzzFiles.makeFolder(fzWorkDir)
    fz_install_handlers()
    target.setUp()
    fz_watchdog_start(timeout, UInt64(rss) << 20)
    for file in files {
        guard let contents = FuzzFiles.read(file) else {
            print("cannot read \(file)")
            continue
        }
        let data = [UInt8](contents)
        let started = fz_now()
        fz_exec_begin()
        autoreleasepool {
            target.run(data)
        }
        fz_exec_end()
        print("ok \(file) \(data.count) bytes \(String(format: "%.1f", (fz_now() - started) * 1_000)) ms")
    }
    FuzzFiles.removeWork(fzWorkDir)
    exit(0)
}

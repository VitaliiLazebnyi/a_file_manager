import FuzzCore

// Target group: the kernel's file masks, the sorter and the panel model.

fuzzMain([
    FileMaskTarget.make(),
    SorterTarget.make(),
    PanelTarget.make("panel", unique: true),
    PanelTarget.make("paneldup", unique: false),
    selfTestTarget()
])

/// The positive control: a crash for inputs that start with "CR", a hang for inputs that start with "HA".
internal func selfTestTarget() -> FuzzTarget {
    FuzzTarget(
        "selftest",
        maxLen: 64,
        seeds: { [Array("hello world".utf8)] },
        run: { bytes in
            if bytes.count > 3, bytes[0] == 0x43, bytes[1] == 0x52 {
                let small = [1, 2, 3]
                _ = small[Int(bytes[2])]
            }
            if bytes.count > 5, bytes[0] == 0x48, bytes[1] == 0x41 {
                while true {
                    // Hangs on purpose: the fuzzer must report a timeout.
                }
            }
        }
    )
}

import FileOperationsPlugin
import Testing

/// The switches a command takes as its parameter (spec 17 › Commands with parameters).
@Suite
internal struct Switches {
    /// Switches with and without values, quoted values and doubled quotes are read into a table.
    @Test
    internal func commandOptionsAreRead() {
        // The example of spec 17 › Commands with parameters.
        let switches = CommandSwitches.parse("/V0H1T=\"c:\\test\\\"W=\"\"\"a test.*\"\" test2.*\"")
        #expect(switches == ["V": "0", "H": "1", "T": "c:\\test\\", "W": "\"a test.*\" test2.*"])
        #expect(CommandSwitches.parse("/O3 /G S") == ["O": "3", "G": "1", "S": "1"])
        #expect(CommandSwitches.parse("N=\"a|b\" G") == ["N": "a|b", "G": "1"])
        #expect(CommandSwitches.parse("").isEmpty)
    }
}

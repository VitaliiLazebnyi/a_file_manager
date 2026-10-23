import FileOperationsPlugin
import Foundation
import TestSupport
import Testing

/// The target field when it names the root folder, whose last part is the slash itself.
@Suite
internal struct TargetSpecSlashTests {
    /// A target that is only a slash is the root folder.
    @Test
    internal func aSlashAloneIsTheRootFolder() throws {
        let box = try Sandbox()
        let (fileSystems, _) = makeFileSystems()
        let source = try box.folder("A")
        func parse(_ text: String) -> TargetSpec {
            TargetSpec.parse(text, sourceDirectory: source, operandCount: 2, fileSystems: fileSystems)
        }
        #expect(parse("/") == TargetSpec(directory: URL(fileURLWithPath: "/")))
    }
}

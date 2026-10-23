import FileOperationsPlugin
import Foundation
import TestSupport
import Testing

/// Target masks, the target field and free names (spec 07 › Wildcard target names).
@Suite
internal struct Targets {
    /// A target mask with `*` and `?` takes the parts of the source name it stands for.
    @Test
    internal func wildcardTargetNames() {
        // The examples of spec 07 › Wildcard target names.
        #expect(TargetMask.apply("h?.txt", to: "test.txt") == "he.txt")
        #expect(TargetMask.apply("f*.txt", to: "test.txt") == "fest.txt")
        #expect(TargetMask.apply("F*Rest.*", to: "test.txt") == "FestRest.txt")
        #expect(TargetMask.apply("start_**_rest.*", to: "test.txt") == "start_test_rest.txt")
        #expect(TargetMask.apply("start_*?do*_rest.*", to: "name.txt") == "start_dome_rest.txt")
        #expect(TargetMask.apply("*.new", to: "a.txt") == "a.new")
        #expect(TargetMask.apply("*.*", to: "a.txt") == "a.txt")
        #expect(TargetMask.apply("renamed.md", to: "a.txt") == "renamed.md")
        #expect(TargetMask.apply("plain", to: "a.txt") == "plain")
    }

    /// The target field gives a folder and a mask, relative or full, on this or another file system.
    @Test
    internal func parsesTheTargetField() throws {
        let box = try Sandbox()
        let (fileSystems, memory) = makeFileSystems()
        try box.folder("B")
        let source = try box.folder("A")
        func parse(_ text: String, count: Int = 1) -> TargetSpec {
            TargetSpec.parse(text, sourceDirectory: source, operandCount: count, fileSystems: fileSystems)
        }
        #expect(parse(box.url("B").path, count: 3) == TargetSpec(directory: box.url("B")))
        #expect(parse(box.url("B").path + "/*.new", count: 3) == TargetSpec(directory: box.url("B"), mask: "*.new"))
        #expect(parse(box.url("B/copy.txt").path) == TargetSpec(directory: box.url("B"), mask: "copy.txt"))
        #expect(parse("renamed.txt") == TargetSpec(directory: source, mask: "renamed.txt"))
        #expect(parse("*.bak", count: 2) == TargetSpec(directory: source, mask: "*.bak"))
        #expect(parse("..") == TargetSpec(directory: box.root))
        #expect(parse(box.url("new/sub").path + "/") == TargetSpec(directory: box.url("new/sub")))
        #expect(parse(box.url("new/sub").path, count: 2) == TargetSpec(directory: box.url("new/sub")))
        #expect(parse("", count: 2) == TargetSpec(directory: source))
        // A target on another file system is written as a full location.
        memory.addDirectory("/inbox")
        #expect(parse("mem:///inbox", count: 2) == TargetSpec(directory: memory.url("/inbox")))
        #expect(parse("mem:///inbox/new.txt") == TargetSpec(directory: memory.url("/inbox"), mask: "new.txt"))
    }

    /// A free name is the name itself, or the name with the first unused number in brackets.
    @Test
    internal func uniqueNames() throws {
        let box = try Sandbox()
        let (fileSystems, _) = makeFileSystems()
        func free(_ name: String) -> String {
            UniqueName.available(for: box.url(name), in: fileSystems).lastPathComponent
        }
        #expect(free("report.txt") == "report.txt")
        try box.file("report.txt")
        #expect(free("report.txt") == "report (2).txt")
        try box.file("report (2).txt")
        try box.folder("docs")
        #expect(free("report.txt") == "report (3).txt")
        #expect(free("docs") == "docs (2)")
    }
}

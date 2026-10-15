import AFMKernel
import Foundation
import TestSupport
import Testing

@testable import NetworkPlugin

/// The helper that carries ssh's questions: what it does with questions that are too long or damaged, and a
/// folder it cannot make its pipes in.
@Suite
internal struct CovNetAskpass {
    /// Writes `text` into the helper's question pipe, as the script would.
    private func ask(_ helper: AskpassHelper, _ text: String) throws {
        let pipe = try FileHandle(forWritingTo: helper.directory.appendingPathComponent("question"))
        defer { try? pipe.close() }
        try pipe.write(contentsOf: Data(text.utf8))
    }

    /// The end marker the helper's script writes after a question.
    private func end(of helper: AskpassHelper) -> String {
        helper.environment["AFM_ASKPASS_END"] ?? ""
    }

    /// A question without the three parts is no question; the next one is read.
    @Test
    internal func aDamagedQuestionIsNoQuestion() throws {
        let helper = try AskpassHelper()
        try ask(helper, "only one line\n\(end(of: helper))\n")
        #expect(helper.pendingQuestion() == nil)
        try ask(helper, "7.1\n\nPassword:\n\(end(of: helper))\n")
        #expect(helper.pendingQuestion() == AskpassHelper.Question(id: "7.1", kind: .entry, text: "Password:"))
    }

    /// Of a question that has no end, only the last part is kept; once it ends, the next question is read.
    @Test
    internal func ofAQuestionWithoutAnEndOnlyTheLastPartIsKept() throws {
        let helper = try AskpassHelper()
        let piece = String(repeating: "x", count: 4_000)
        for _ in 0..<20 {
            try ask(helper, piece)
            #expect(helper.pendingQuestion() == nil)
        }
        try ask(helper, "\n\(end(of: helper))\n")
        #expect(helper.pendingQuestion() == nil)
        try ask(helper, "8.2\nnone\nTouch the key\n\(end(of: helper))\n")
        let question = try #require(helper.pendingQuestion())
        #expect(question.kind == .notice && question.text == "Touch the key")
    }

    /// A folder whose pipes cannot be made leaves nothing behind.
    @Test
    internal func aFolderForNoPipesLeavesNothingBehind() throws {
        let box = try Sandbox()
        // Long enough that the helper's folder can be made, but not the pipes in it.
        // The real path: a link on the way (`/var`) counts towards the longest path.
        let resolved = try #require(realpath(box.root.path, nil))
        defer { free(resolved) }
        var parent = URL(fileURLWithPath: String(cString: resolved))
        while parent.path.utf8.count < 970 {
            parent.appendPathComponent(String(repeating: "p", count: min(200, 970 - parent.path.utf8.count - 1)))
        }
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        #expect(parent.path.utf8.count + 49 < 1_024 && parent.path.utf8.count + 58 > 1_024)
        #expect(throws: POSIXError.self) { _ = try AskpassHelper(in: parent) }
        #expect(try FileManager.default.contentsOfDirectory(atPath: parent.path).isEmpty)
    }
}

import Foundation
import Testing

@testable import ConfigurationPlugin

/// The places of a command line where a value may stand, at the corners the other suites leave.
@Suite
internal struct CovConfigShellLine {
    /// The refusal for a value written after `text`, or nil when it may stand there.
    private static func refusal(after text: String) -> ShellContext.Refusal? {
        switch ShellLine.script([.text(text), .value("v")]) {
        case .success:
            nil

        case .failure(let refusal):
            refusal
        }
    }

    /// Every refusal explains itself in its own words.
    @Test
    internal func everyRefusalHasItsOwnExplanation() {
        let all: [ShellContext.Refusal] = [
            .ansiQuote, .backtick, .hereDocument, .comment, .backslash, .dollar, .arithmetic, .parameterExpansion,
            .caseInSubstitution
        ]
        let texts = all.map(\.explanation)
        #expect(Set(texts).count == all.count && texts.allSatisfy { $0.hasPrefix("A placeholder") })
    }

    /// An escaped quote inside `$'…'` and an escaped backtick inside backticks do not end them.
    @Test
    internal func escapedClosersDoNotEndTheirQuote() {
        #expect(Self.refusal(after: "echo $'a\\'' ") == nil)
        #expect(Self.refusal(after: "echo $'a\\' ") == .ansiQuote)
        #expect(Self.refusal(after: "echo `a\\`` ") == nil)
        #expect(Self.refusal(after: "echo `a\\` ") == .backtick)
    }

    /// Parentheses inside `$((…))` are counted, and a quote there cannot be followed.
    @Test
    internal func arithmeticCountsParenthesesAndRefusesQuotes() {
        #expect(Self.refusal(after: "echo $(( (1 + 2) * 3 )) ") == nil)
        #expect(Self.refusal(after: "echo $(( (1 + 2) ") == .arithmetic)
        #expect(Self.refusal(after: "echo $(( '1' )) ") == .arithmetic)
    }

    /// Inside double quotes `${…}` is followed and `$[…]` is arithmetic.
    @Test
    internal func bracesAndBracketsInDoubleQuotes() {
        #expect(Self.refusal(after: "echo \"${HOME} ") == nil)
        #expect(Self.refusal(after: "echo \"${HOME") == .parameterExpansion)
        #expect(Self.refusal(after: "echo \"$[1] ") == .arithmetic)
    }

    /// A `case` that ends at the `)` of its `$(…)` is refused.
    @Test
    internal func aCaseEndingAtItsSubstitutionIsRefused() {
        #expect(Self.refusal(after: "echo $(case) ") == .caseInSubstitution)
    }

    /// An empty value is a word of its own only when nothing is written right after it.
    @Test
    internal func anEmptyValueIsAWordOnlyBeforeASpace() {
        #expect(ShellLine.display([.text("echo "), .value(""), .value("x")]) == "echo x")
        #expect(ShellLine.display([.text("echo "), .value(""), .text("")]) == "echo ")
        #expect(ShellLine.display([.text("echo "), .value(""), .text(" y")]) == "echo \"\" y")
    }

    /// Values that are empty or begin or end with a space are never shown as text to type over.
    @Test
    internal func valuesWithOuterSpacesAreNotTame() {
        #expect(!ShellLine.isTame("") && !ShellLine.isTame(" a") && !ShellLine.isTame("a ") && ShellLine.isTame("a b"))
        let shown = ShellLine.prompt([.text("echo "), .value(" a")])
        #expect(shown.text == "echo \"${__afm_1}\"" && shown.values == [" a"])
    }

    /// A value where none can stand is shown as a plain reference, and a long list of values is cut short.
    @Test
    internal func thePromptShowsRefusedPlacesAndCutsTheLegend() {
        let refused = ShellLine.prompt([.text("echo `"), .value("a;b")])
        #expect(refused.text == "echo `${__afm_1}" && refused.values == ["a;b"])
        let many = ShellLine.prompt((0..<14).flatMap { [.text(" "), .value("v;\($0)")] })
        let legend = many.legend.split(separator: "\n")
        #expect(many.values.count == 14 && legend.count == 13 && legend.last == "… and 2 more")
    }
}

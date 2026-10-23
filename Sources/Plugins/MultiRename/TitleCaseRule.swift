import Foundation

/// The words "First of each word uppercase (English in Titles)" leaves in lower case
/// (spec 18 › Case switches, the `LowercaseStrings` setting).
internal struct TitleCaseRule: Equatable {
    /// The setting of a fresh install: the English articles, conjunctions and short prepositions.
    internal static let defaultSetting =
        "English in Titles:a,an,the,at,by,for,in,of,on,to,from,up,and,as,but,or,nor,yet,so,vs"
    /// The rule of `defaultSetting`.
    internal static let standard = Self(setting: defaultSetting)

    /// What the rule is called in the menu of the case conversions.
    internal let label: String
    /// The words kept in lower case, in lower case.
    internal let words: Set<String>
    /// A `!` at the end of the label: the last word may stay in lower case too.
    internal let allowsLowercaseLastWord: Bool

    /// `<description>:<word list>`.
    internal init(setting: String) {
        // Without a label the whole setting is the word list.
        let colon = setting.firstIndex(of: ":")
        var title = colon.map { String(setting[..<$0]) } ?? "English in Titles"
        allowsLowercaseLastWord = title.hasSuffix("!")
        if allowsLowercaseLastWord {
            title.removeLast()
        }
        label = title
        let list = colon.map { setting[setting.index(after: $0)...] } ?? Substring(setting)
        words = Set(
            list.split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
                .filter { !$0.isEmpty }
        )
    }
}

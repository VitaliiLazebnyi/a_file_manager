/// What is kept for looking names up in one list: a single question walks the list, which is
/// cheaper than making an index; a caller that keeps asking gets an index of all names.
///
/// For one thread.
internal struct NameLookups {
    /// Finds every name as it is written; made after a few questions, or handed in along with
    /// a list worked out in the background.
    internal var index: NameIndex?
    /// Questions asked since the list changed, while there is no index.
    private var count = 0
    /// The shown rows of the names that hold more than ASCII; made when names written
    /// differently from every entry keep being asked for.
    private var alike: AlikeNames?
    /// Such questions asked since what is shown changed, while there is no `alike`.
    private var alikeCount = 0

    /// Lookups in a list that start with the index, if one was made of it.
    internal init(index: NameIndex?) {
        self.index = index
    }

    /// Lookups in a list of which nothing is known yet.
    internal init() {
        index = nil
    }

    /// Every place of `listed` whose entry is written exactly like `name`, rising.
    internal mutating func places(ofExactly name: String, in listed: [FileItem]) -> [Int] {
        if index == nil {
            count += 1
            if count > 2, listed.count > 64 { index = NameIndex(listed) }
        }
        guard let index else {
            return listed.indices.filter { ExactName.areSame(listed[$0].name, name) }
        }
        return index.places(of: name, in: listed)
    }

    /// The row of a shown entry whose name reads like `name`; for a name written as no entry
    /// is (`é` as one character where the entry has `e` and an accent).
    internal mutating func row(alike name: String, in shown: [FileItem]) -> Int? {
        if let alike {
            return alike.row(of: name)
        }
        alikeCount += 1
        guard alikeCount > 2, shown.count > 64 else {
            return shown.firstIndex { $0.name == name }
        }
        let made = AlikeNames(shown)
        alike = made
        return made.row(of: name)
    }

    /// What is shown has changed (another filter, another list): the rows of names that read
    /// alike are no longer true.
    internal mutating func shownChanged() {
        (alike, alikeCount) = (nil, 0)
    }
}

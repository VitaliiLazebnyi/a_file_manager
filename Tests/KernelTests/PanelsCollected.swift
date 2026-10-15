@testable import AFMKernel

/// Items collected in batches, as a directory that arrives in pieces is: the batches as one
/// list in `order`, items of earlier batches ahead of equal items of later ones.
internal func panelsCollected(_ batches: [[FileItem]], by order: ListOrder) -> [FileItem] {
    var list = SortedFileList(order: order)
    for batch in batches { list.add(batch) }
    return list.items
}

/// Whether `first` belongs before `second` in `order`, as the order of names is defined
/// (`Sorter.exactOrder`), with the keys of the user's language.
internal func panelsInOrder(_ first: FileItem, _ second: FileItem, by order: ListOrder) -> Bool {
    Sorter.exactOrder(first, second, by: order, collator: .current) < 0
}

/// Whether `first` belongs before `second` in `order`, with the keys of `collator`.
internal func panelsInOrder(_ first: FileItem, _ second: FileItem, by order: ListOrder, collator: NameCollator)
    -> Bool
{
    Sorter.exactOrder(first, second, by: order, collator: collator) < 0
}

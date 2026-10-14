import FuzzCore

// Group 7: CompareContent (Myers, TextDiff, inline highlights, the loader's decoding, BinaryDiff),
// MultiRename (RenameMask, RenameRules, RenamePlanner), FileOperations NameTemplate.

fuzzMain([
    myersTarget(), textDiffTarget(), inlineTarget(), loaderTarget(), renameMaskTarget(), renameRegexTarget(),
    plannerTarget(), nameTemplateTarget()
])

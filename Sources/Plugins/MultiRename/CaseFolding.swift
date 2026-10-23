/// How the volume of a folder treats names that differ only in letter case.
internal enum CaseFolding {
    /// `A.txt` and `a.txt` are two names.
    case distinct
    /// `A.txt` and `a.txt` are the same name.
    case folded
}

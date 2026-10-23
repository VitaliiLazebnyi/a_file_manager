/// How Unpack is to work (spec 08 › Unpack › Fields and options).
internal struct UnpackOptions {
    /// Which files to take, by name: `*.txt *.md`.
    internal var mask = "*.*"
    /// Keeps the paths stored with the files; without, every file goes straight into the target.
    internal var keepsPaths = true
    /// Each archive goes into a folder of its own, named after the archive.
    internal var separateFolders = false
    /// Existing files are replaced without asking.
    internal var overwrites = false
}

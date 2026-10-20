import AVFoundation

/// What the media player mode plays with: AVFoundation's player (`SystemMediaPlayback`), or a
/// test's that only records what it is asked (a player that plays opens the audio device, and
/// in a session someone watches that can ask for the microphone). Main thread only.
@MainActor
internal protocol MediaPlayback: AnyObject {
    /// The player the controls on screen drive; nil for one that plays nothing.
    var player: AVPlayer? { get }
    /// From 0 to 1.
    var volume: Float { get set }
    /// Whether nothing is heard, whatever the volume.
    var isMuted: Bool { get set }
    /// Whether the loaded file is playing.
    var isPlaying: Bool { get }
    /// Whether a file is loaded.
    var hasItem: Bool { get }
    /// Whether the loaded file goes on by frames (a film that is ready); a sound does not.
    var canStepForward: Bool { get }
    /// Where the loaded file is, in seconds.
    var currentSeconds: Double { get }

    /// Loads the file at `url`; `ended` is called when it has played to its end. A player is
    /// loaded once: the Lister makes one for each file it plays (`MediaView`).
    func load(_ url: URL, ended: @escaping @MainActor () -> Void)
    /// Lets go of the loaded file.
    func unload()
    /// Plays the loaded file from where it is.
    func play()
    /// Stops the loaded file where it is.
    func pause()
    /// Goes to a place, exactly.
    func seek(toSeconds seconds: Double)
    /// Goes on by one frame.
    func stepForward()
}

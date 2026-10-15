import AVFoundation
import Foundation

@testable import ViewerPlugin

/// A media player that plays nothing (no test may open the audio device) and keeps what it was
/// asked: the files loaded, play and pause, the places sought, the frames stepped.
@MainActor
internal final class CovViewPlayback: MediaPlayback {
    /// Makes a playback of this kind for every view (`MediaView.playback` is the one it got).
    internal static let factory: @MainActor () -> any MediaPlayback = { CovViewPlayback() }

    /// What was asked, in order: `load name`, `unload`, `play`, `pause`, `seek 1.5`, `step`.
    internal private(set) var calls: [String] = []
    /// The files loaded, in order.
    internal private(set) var loaded: [URL] = []
    /// The volume set.
    internal var volume: Float = 1
    /// The muting set.
    internal var isMuted = false
    /// Between play and pause.
    internal private(set) var isPlaying = false
    /// Whether the file goes on by frames (a film); set by the test.
    internal var canStepForward = false
    /// Where the file is; seeking and stepping move it.
    internal var currentSeconds = 0.0
    private var ended: (@MainActor () -> Void)?

    /// None: nothing is shown.
    internal var player: AVPlayer? { nil }
    /// Between load and unload.
    internal var hasItem: Bool { ended != nil }

    /// Keeps the file and whom to tell of its end.
    internal func load(_ url: URL, ended: @escaping @MainActor () -> Void) {
        calls.append("load " + url.lastPathComponent)
        loaded.append(url)
        self.ended = ended
        currentSeconds = 0
    }

    /// Forgets the file.
    internal func unload() {
        calls.append("unload")
        ended = nil
        isPlaying = false
    }

    /// Records it.
    internal func play() {
        calls.append("play")
        isPlaying = true
    }

    /// Records it.
    internal func pause() {
        calls.append("pause")
        isPlaying = false
    }

    /// Records it and goes there.
    internal func seek(toSeconds seconds: Double) {
        calls.append("seek \(seconds)")
        currentSeconds = seconds
    }

    /// Records it and goes on by a frame of 30 a second.
    internal func stepForward() {
        calls.append("step")
        currentSeconds += 1.0 / 30
    }

    /// The loaded file has played to its end.
    internal func finish() {
        isPlaying = false
        ended?()
    }

    deinit {
        // Nothing to release.
    }
}

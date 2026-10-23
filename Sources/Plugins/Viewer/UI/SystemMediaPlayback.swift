import AVFoundation

/// AVFoundation's player: what the Lister plays files with.
///
/// It opens the audio device, so only the program and its UI tests use it; each member hands its
/// call on.
@MainActor
internal final class SystemMediaPlayback: MediaPlayback {
    private let avPlayer = AVPlayer()
    /// Set on the main thread, read in `deinit`.
    nonisolated(unsafe) private var endObserver: (any NSObjectProtocol)?

    /// The player itself, for the controls on screen.
    internal var player: AVPlayer? { avPlayer }

    /// The player's volume.
    internal var volume: Float {
        get { avPlayer.volume }
        set { avPlayer.volume = newValue }
    }

    /// The player's muting.
    internal var isMuted: Bool {
        get { avPlayer.isMuted }
        set { avPlayer.isMuted = newValue }
    }

    /// Whether the player runs.
    internal var isPlaying: Bool { avPlayer.rate != 0 }
    /// Whether the player has a file.
    internal var hasItem: Bool { avPlayer.currentItem != nil }
    /// Whether the player's file goes on by frames.
    internal var canStepForward: Bool { avPlayer.currentItem?.canStepForward == true }
    /// The player's place.
    internal var currentSeconds: Double { avPlayer.currentTime().seconds }

    /// Gives the player its file, and tells `ended` when it played to its end; once.
    internal func load(_ url: URL, ended: @escaping @MainActor () -> Void) {
        let item = AVPlayerItem(url: url)
        // Delivered on the main queue.
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { _ in MainActor.assumeIsolated { ended() } }
        avPlayer.replaceCurrentItem(with: item)
    }

    /// Takes the file from the player.
    internal func unload() { avPlayer.replaceCurrentItem(with: nil) }
    /// Starts the player.
    internal func play() { avPlayer.play() }
    /// Stops the player.
    internal func pause() { avPlayer.pause() }

    /// Moves the player, exactly.
    internal func seek(toSeconds seconds: Double) {
        avPlayer.seek(
            to: CMTime(seconds: seconds, preferredTimescale: 600),
            toleranceBefore: .zero,
            toleranceAfter: .zero
        )
    }

    /// Moves the player's file on by a frame.
    internal func stepForward() { avPlayer.currentItem?.step(byCount: 1) }

    deinit {
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
    }
}

import AVKit
import AppKit

/// The media player mode (spec 10 › Media player mode), on AVKit.
///
/// It plays with a `MediaPlayback`: the system's in the program, a recording one in tests. Main
/// thread only.
internal final class MediaView: NSView {
    private let playerView = AVPlayerView()
    /// What it plays with.
    internal let playback: any MediaPlayback
    /// Called when the track has played to its end (a playlist then moves on).
    internal var onEnd: () -> Void = {
        // Nothing moves on until the pane sets this.
    }
    /// Called with "track – artist" when the file's tags name them.
    internal var onTitle: ((String) -> Void)?

    /// The volume of the player, 0…1.
    internal var volume: Float { playback.volume }

    /// A player view that plays with `playback`, its controls floating over the picture.
    internal init(frame: NSRect, playback: any MediaPlayback) {
        self.playback = playback
        super.init(frame: frame)
        playerView.player = playback.player
        playerView.controlsStyle = .floating
        playerView.autoresizingMask = [.width, .height]
        playerView.frame = bounds
        addSubview(playerView)
    }

    /// Made in code only: an archive gives none.
    internal required init?(coder _: NSCoder) { nil }

    /// Plays the file at `url` at `volume` from its start; its tags give the title in the background.
    internal func play(_ url: URL, volume: Float) {
        playback.load(url) { [weak self] in self?.onEnd() }
        playback.volume = volume
        playback.play()
        let asset = AVURLAsset(url: url)
        // Reading the tags may take a moment on a slow disk; it is not done on the main thread.
        Task { [weak self] in
            guard let metadata = try? await asset.load(.commonMetadata) else {
                return
            }
            var values: [AVMetadataKey: String] = [:]
            for item in metadata {
                guard let key = item.commonKey, let value = try? await item.load(.stringValue) else { continue }
                values[key] = value
            }
            guard let title = values[.commonKeyTitle] else {
                return
            }
            let text = values[.commonKeyArtist].map { "\(title) – \($0)" } ?? title
            await MainActor.run { self?.onTitle?(text) }
        }
    }

    /// Stops playing and lets go of the file.
    internal func stop() {
        playback.pause()
        playback.unload()
    }

    /// Plays when paused, pauses when playing (Space).
    internal func togglePlaying() {
        if playback.isPlaying { playback.pause() } else { playback.play() }
    }

    /// Mutes the sound, or turns it on again (key M).
    internal func toggleMute() { playback.isMuted.toggle() }

    /// Turns the volume up or down by `delta`, between 0 and 1.
    internal func changeVolume(by delta: Float) {
        playback.volume = min(1, max(0, playback.volume + delta))
    }

    /// Moves by `seconds`, not before the start.
    internal func seek(by seconds: Double) {
        playback.seek(toSeconds: max(0, playback.currentSeconds + seconds))
    }

    /// One video frame, or a tenth of a second of audio (key E).
    internal func step() {
        playback.pause()
        guard playback.hasItem else {
            return
        }
        if playback.canStepForward { playback.stepForward() } else { seek(by: 0.1) }
    }

    /// Fit the video to the window, or fill the window with it (key F).
    internal func toggleFit() {
        playerView.videoGravity = playerView.videoGravity == .resizeAspect ? .resizeAspectFill : .resizeAspect
    }
}

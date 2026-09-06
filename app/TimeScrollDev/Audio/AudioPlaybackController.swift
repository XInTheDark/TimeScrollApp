import Foundation
import AVFoundation

@MainActor
final class AudioPlaybackController: NSObject, ObservableObject, AVAudioPlayerDelegate {
    @Published private(set) var isPlaying = false
    @Published private(set) var currentTime: TimeInterval = 0
    @Published private(set) var duration: TimeInterval = 0

    private var player: AVAudioPlayer?
    private var updateTimer: Timer?
    private var loadedPath: String?

    deinit {
        updateTimer?.invalidate()
        updateTimer = nil
        player?.delegate = nil
        player?.stop()
    }

    func load(url: URL) {
        guard loadedPath != url.path else { return }
        teardownPlayer(resetTimelineState: true, resetLoadedPath: false)
        loadedPath = url.path
        do {
            let player = try buildPlayer(for: url)
            player.delegate = self
            player.prepareToPlay()
            self.player = player
            self.duration = player.duration
            self.currentTime = 0
        } catch {
            loadedPath = nil
            fputs("[Audio][Playback] Failed to prepare player for \(url.lastPathComponent): \(error.localizedDescription)\n", stderr)
        }
    }

    func togglePlayback() {
        if isPlaying {
            pause()
        } else {
            play()
        }
    }

    func play() {
        guard let player else { return }
        if player.duration > 0,
           player.currentTime >= max(0, player.duration - 0.05) {
            player.currentTime = 0
            currentTime = 0
        }
        player.play()
        isPlaying = player.isPlaying
        startTimerIfNeeded()
    }

    func pause() {
        player?.pause()
        isPlaying = false
        stopTimer()
        currentTime = player?.currentTime ?? currentTime
    }

    func seek(to seconds: TimeInterval) {
        guard let player else { return }
        let clamped = max(0, min(seconds, duration))
        player.currentTime = clamped
        currentTime = clamped
    }

    func stop() {
        teardownPlayer(resetTimelineState: true, resetLoadedPath: true)
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            self.isPlaying = false
            self.currentTime = self.duration
            self.stopTimer()
        }
    }

    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        Task { @MainActor in
            self.isPlaying = false
            self.stopTimer()
            if let error {
                fputs("[Audio][Playback] Decode error: \(error.localizedDescription)\n", stderr)
            }
        }
    }

    private func buildPlayer(for url: URL) throws -> AVAudioPlayer {
        if url.pathExtension.lowercased() == "tse" {
            let (_, data) = try FileCrypter.shared.decryptTSE(at: url)
            return try AVAudioPlayer(data: data)
        }
        return try AVAudioPlayer(contentsOf: url)
    }

    private func startTimerIfNeeded() {
        guard updateTimer == nil else { return }
        updateTimer = Timer.scheduledTimer(timeInterval: 0.05,
                                           target: self,
                                           selector: #selector(handleTimerTick),
                                           userInfo: nil,
                                           repeats: true)
        updateTimer?.tolerance = 0.02
    }

    @objc
    private func handleTimerTick() {
        currentTime = player?.currentTime ?? currentTime
        duration = player?.duration ?? duration
        isPlaying = player?.isPlaying ?? false
        if isPlaying == false {
            stopTimer()
        }
    }

    private func stopTimer() {
        updateTimer?.invalidate()
        updateTimer = nil
    }

    private func teardownPlayer(resetTimelineState: Bool, resetLoadedPath: Bool) {
        stopTimer()
        if let player {
            player.delegate = nil
            if player.isPlaying {
                player.stop()
            }
        }
        player = nil
        isPlaying = false
        if resetTimelineState {
            currentTime = 0
            duration = 0
        }
        if resetLoadedPath {
            loadedPath = nil
        }
    }
}

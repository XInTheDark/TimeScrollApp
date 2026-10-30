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
        let path = url.path
        loadedPath = path
        guard url.pathExtension.lowercased() == "tse" else {
            install(Result { try AVAudioPlayer(contentsOf: url) }, for: url)
            return
        }
        // Decrypting a long recording takes a while; keep it off the main thread.
        DispatchQueue.global(qos: .userInitiated).async {
            let decrypted = Result { try FileCrypter.shared.decryptTSE(at: url).1 }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.loadedPath == path, self.player == nil else { return }
                self.install(decrypted.flatMap { data in Result { try AVAudioPlayer(data: data) } }, for: url)
            }
        }
    }

    private func install(_ result: Result<AVAudioPlayer, Error>, for url: URL) {
        switch result {
        case .success(let player):
            player.delegate = self
            player.prepareToPlay()
            self.player = player
            self.duration = player.duration
            self.currentTime = 0
        case .failure(let error):
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
        // Assign only on change: every @Published write re-renders observers, 20 times a second.
        let time = player?.currentTime ?? currentTime
        if time != currentTime { currentTime = time }
        let total = player?.duration ?? duration
        if total != duration { duration = total }
        let playing = player?.isPlaying ?? false
        if playing != isPlaying { isPlaying = playing }
        if playing == false {
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

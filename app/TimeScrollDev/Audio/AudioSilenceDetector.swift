import AVFoundation

/// Cheap loudness check run before an audio segment is stored or transcribed.
enum AudioSilenceDetector {
    /// RMS level (about -45 dBFS) above which a 100 ms window counts as sound.
    private static let windowRMSThreshold: Float = 0.0056
    /// Total sound required for a segment to be kept.
    private static let minimumSoundSeconds: Double = 0.5

    /// True when the file is readable and contains less than `minimumSoundSeconds` of sound.
    /// Unreadable files are treated as not silent so they are never discarded by mistake.
    static func isSilent(fileAt url: URL) -> Bool {
        guard let file = try? AVAudioFile(forReading: url) else { return false }
        let format = file.processingFormat
        let windowFrames = AVAudioFrameCount(max(1, format.sampleRate / 10))
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: windowFrames) else { return false }
        let requiredWindows = Int((minimumSoundSeconds * 10).rounded(.up))
        var loudWindows = 0
        while file.framePosition < file.length {
            do { try file.read(into: buffer, frameCount: windowFrames) } catch { return false }
            guard buffer.frameLength > 0, let channels = buffer.floatChannelData else { break }
            let frames = Int(buffer.frameLength)
            var loudest: Float = 0
            for channel in 0..<Int(format.channelCount) {
                var sumSquares: Float = 0
                let samples = channels[channel]
                for index in 0..<frames { sumSquares += samples[index] * samples[index] }
                loudest = max(loudest, (sumSquares / Float(frames)).squareRoot())
            }
            if loudest >= windowRMSThreshold {
                loudWindows += 1
                if loudWindows >= requiredWindows { return false }
            }
        }
        return true
    }
}

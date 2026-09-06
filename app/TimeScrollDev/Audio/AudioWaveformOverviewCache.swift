import Foundation
import AVFoundation
import CoreMedia

struct AudioWaveformOverview: Sendable, Hashable {
    let bins: [Float]
}

final class AudioWaveformOverviewCache {
    static let shared = AudioWaveformOverviewCache()

    private let stateQueue = DispatchQueue(label: "com.timescroll.audio.waveform-cache")
    private var cache: [String: AudioWaveformOverview] = [:]
    private var inFlight: Set<String> = []
    private var waiters: [String: [@Sendable (AudioWaveformOverview?) -> Void]] = [:]

    private init() {}

    func cachedOverview(for path: String) -> AudioWaveformOverview? {
        stateQueue.sync { cache[path] }
    }

    func loadOverviewAsync(for path: String,
                           sampleCount: Int = 96,
                           completion: @escaping @Sendable (AudioWaveformOverview?) -> Void) {
        if let cached = cachedOverview(for: path) {
            DispatchQueue.main.async {
                completion(cached)
            }
            return
        }

        let shouldStartLoad: Bool = stateQueue.sync {
            waiters[path, default: []].append(completion)
            if inFlight.contains(path) {
                return false
            }
            inFlight.insert(path)
            return true
        }

        guard shouldStartLoad else { return }

        DispatchQueue.global(qos: .utility).async {
            let overview = Self.buildOverview(for: path, sampleCount: sampleCount)
            let completions: [@Sendable (AudioWaveformOverview?) -> Void] = self.stateQueue.sync {
                if let overview {
                    self.cache[path] = overview
                }
                self.inFlight.remove(path)
                let completions = self.waiters[path] ?? []
                self.waiters[path] = nil
                return completions
            }

            DispatchQueue.main.async {
                completions.forEach { $0(overview) }
            }
        }
    }

    private static func buildOverview(for path: String, sampleCount: Int) -> AudioWaveformOverview? {
        let sourceURL = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: sourceURL.path) else { return nil }

        do {
            let (playableURL, cleanup) = try makePlayableURL(for: sourceURL)
            defer { cleanup() }

            let asset = AVURLAsset(url: playableURL)
            guard let track = asset.tracks(withMediaType: .audio).first else { return nil }
            let reader = try AVAssetReader(asset: asset)
            let outputSettings: [String: Any] = [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVLinearPCMIsFloatKey: true,
                AVLinearPCMBitDepthKey: 32,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false
            ]
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: outputSettings)
            output.alwaysCopiesSampleData = false
            guard reader.canAdd(output) else { return nil }
            reader.add(output)
            guard reader.startReading() else { return nil }

            var chunkPeaks: [Float] = []
            chunkPeaks.reserveCapacity(320)

            while let sampleBuffer = output.copyNextSampleBuffer() {
                defer { CMSampleBufferInvalidate(sampleBuffer) }
                guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { continue }
                let length = CMBlockBufferGetDataLength(blockBuffer)
                guard length > 0 else { continue }

                var data = Data(count: length)
                let copied = data.withUnsafeMutableBytes { rawBuffer -> OSStatus in
                    guard let baseAddress = rawBuffer.baseAddress else { return -1 }
                    return CMBlockBufferCopyDataBytes(blockBuffer,
                                                      atOffset: 0,
                                                      dataLength: length,
                                                      destination: baseAddress)
                }
                guard copied == kCMBlockBufferNoErr else { continue }

                let peak = data.withUnsafeBytes { rawBuffer -> Float in
                    let samples = rawBuffer.bindMemory(to: Float.self)
                    guard !samples.isEmpty else { return 0 }
                    var peak: Float = 0
                    for sample in samples {
                        peak = max(peak, abs(sample))
                    }
                    return peak
                }
                chunkPeaks.append(peak)
            }

            guard !chunkPeaks.isEmpty else { return nil }

            let normalized = normalize(chunkPeaks, bucketCount: sampleCount)
            return AudioWaveformOverview(bins: normalized)
        } catch {
            fputs("[Audio][Waveform] Failed to build overview for \(sourceURL.lastPathComponent): \(error.localizedDescription)\n", stderr)
            return nil
        }
    }

    private static func normalize(_ peaks: [Float], bucketCount: Int) -> [Float] {
        let desiredCount = max(12, bucketCount)
        let reduced: [Float]

        if peaks.count <= desiredCount {
            reduced = peaks
        } else {
            reduced = (0..<desiredCount).map { index in
                let start = Int((Double(index) / Double(desiredCount)) * Double(peaks.count))
                let end = max(start + 1, Int((Double(index + 1) / Double(desiredCount)) * Double(peaks.count)))
                let slice = peaks[start..<min(end, peaks.count)]
                return slice.max() ?? 0
            }
        }

        let maxPeak = max(0.001, reduced.max() ?? 0.001)
        return reduced.map { max(0.08, min(1.0, $0 / maxPeak)) }
    }

    private static func makePlayableURL(for url: URL) throws -> (URL, () -> Void) {
        guard url.pathExtension.lowercased() == "tse" else {
            return (url, {})
        }

        let (_, data) = try FileCrypter.shared.decryptTSE(at: url)
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("timescroll-waveform-\(UUID().uuidString)")
            .appendingPathExtension("m4a")
        try data.write(to: tempURL, options: .atomic)
        return (tempURL, {
            try? FileManager.default.removeItem(at: tempURL)
        })
    }
}

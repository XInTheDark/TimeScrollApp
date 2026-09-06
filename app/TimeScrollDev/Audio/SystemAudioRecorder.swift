import Foundation
import AVFoundation
import ScreenCaptureKit
import CoreMedia

final class SystemAudioRecorder: NSObject, SCStreamOutput, @unchecked Sendable {
    private let segmentDuration: TimeInterval
    private let onSegmentFinished: @Sendable (RecordedAudioSegment) -> Void

    private let queue = DispatchQueue(label: "TimeScroll.Audio.System")
    private var stream: SCStream?
    private var rotationTimer: DispatchSourceTimer?
    private var pendingRotation = false
    private var writer: AVAssetWriter?
    private var writerInput: AVAssetWriterInput?
    private var currentURL: URL?
    private var currentStartedAtMs: Int64?
    private var latestEndedAtMs: Int64?
    private var currentSampleRate: Int?
    private var currentChannels: Int?

    init(segmentDuration: TimeInterval,
         onSegmentFinished: @escaping @Sendable (RecordedAudioSegment) -> Void) {
        self.segmentDuration = segmentDuration
        self.onSegmentFinished = onSegmentFinished
        super.init()
    }

    func start() async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first else {
            throw NSError(domain: "TimeScroll.Audio", code: -40, userInfo: [NSLocalizedDescriptionKey: "No display is available for system-audio capture."])
        }

        let configuration = SCStreamConfiguration()
        configuration.width = 2
        configuration.height = 2
        configuration.queueDepth = 3
        configuration.capturesAudio = true
        configuration.sampleRate = 48_000
        configuration.channelCount = 2
        configuration.excludesCurrentProcessAudio = true

        let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
        let stream = SCStream(filter: filter, configuration: configuration, delegate: nil)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
        self.stream = stream
        scheduleRotationTimer()
        try await stream.startCapture()
    }

    func stop() async {
        let activeStream: SCStream? = await withCheckedContinuation { continuation in
            queue.async {
                self.rotationTimer?.cancel()
                self.rotationTimer = nil
                let activeStream = self.stream
                self.stream = nil
                continuation.resume(returning: activeStream)
            }
        }
        if let activeStream {
            try? await activeStream.stopCapture()
        }
        await finishCurrentSegmentAsync()
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of outputType: SCStreamOutputType) {
        guard outputType == .audio, CMSampleBufferDataIsReady(sampleBuffer) else { return }

        if pendingRotation {
            pendingRotation = false
            finishCurrentSegmentLocked()
        }

        do {
            if writer == nil {
                try startWriterLocked(with: sampleBuffer)
            }
            guard let writer, let writerInput else { return }
            let presentationTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            if writer.status == .unknown {
                writer.startWriting()
                writer.startSession(atSourceTime: presentationTime)
            }
            if writerInput.isReadyForMoreMediaData {
                if writerInput.append(sampleBuffer) {
                    latestEndedAtMs = Int64(Date().timeIntervalSince1970 * 1000)
                }
            }
        } catch {
            fputs("[Audio][System] Failed to append system audio buffer: \(error.localizedDescription)\n", stderr)
            finishCurrentSegmentLocked(removeFile: true)
        }
    }

    private func scheduleRotationTimer() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + segmentDuration, repeating: segmentDuration)
        timer.setEventHandler { [weak self] in
            self?.pendingRotation = true
        }
        timer.resume()
        rotationTimer = timer
    }

    private func startWriterLocked(with sampleBuffer: CMSampleBuffer) throws {
        let outputURL = AudioStore.makeStagingURL(sourceKind: .system)
        let assetWriter = try AVAssetWriter(outputURL: outputURL, fileType: .m4a)

        let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer)
        let asbd = formatDescription.flatMap(CMAudioFormatDescriptionGetStreamBasicDescription)?.pointee
        let sampleRate = asbd.map { Int($0.mSampleRate.rounded()) } ?? 48_000
        let channels = asbd.map { Int($0.mChannelsPerFrame) } ?? 2
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: max(1, channels),
            AVEncoderBitRateKey: 128_000,
        ]
        let input = AVAssetWriterInput(mediaType: .audio,
                                       outputSettings: settings,
                                       sourceFormatHint: formatDescription)
        input.expectsMediaDataInRealTime = true
        guard assetWriter.canAdd(input) else {
            throw NSError(domain: "TimeScroll.Audio", code: -41, userInfo: [NSLocalizedDescriptionKey: "Unable to configure system-audio writer input."])
        }
        assetWriter.add(input)

        writer = assetWriter
        writerInput = input
        currentURL = outputURL
        currentStartedAtMs = Int64(Date().timeIntervalSince1970 * 1000)
        latestEndedAtMs = currentStartedAtMs
        currentSampleRate = sampleRate
        currentChannels = channels
    }

    private func finishCurrentSegmentAsync() async {
        await withCheckedContinuation { continuation in
            queue.async {
                self.finishCurrentSegmentLocked {
                    continuation.resume()
                }
            }
        }
    }

    private func finishCurrentSegmentLocked(removeFile: Bool = false, completion: (() -> Void)? = nil) {
        guard let writer, let writerInput, let currentURL, let currentStartedAtMs else {
            resetWriterState()
            completion?()
            return
        }

        let finishedEndedAtMs = max(latestEndedAtMs ?? currentStartedAtMs,
                                    Int64(Date().timeIntervalSince1970 * 1000))
        let sampleRate = currentSampleRate
        let channels = currentChannels
        resetWriterState()

        writerInput.markAsFinished()
        writer.finishWriting {
            if removeFile || writer.status != .completed {
                try? FileManager.default.removeItem(at: currentURL)
            } else {
                let segment = RecordedAudioSegment(sourceKind: .system,
                                                   sourceDisplayName: AudioSourceKind.system.displayName,
                                                   tempURL: currentURL,
                                                   startedAtMs: currentStartedAtMs,
                                                   endedAtMs: finishedEndedAtMs,
                                                   mime: "audio/mp4",
                                                   sampleRate: sampleRate,
                                                   channels: channels)
                self.onSegmentFinished(segment)
            }
            completion?()
        }
    }

    private func resetWriterState() {
        writer = nil
        writerInput = nil
        currentURL = nil
        currentStartedAtMs = nil
        latestEndedAtMs = nil
        currentSampleRate = nil
        currentChannels = nil
    }
}

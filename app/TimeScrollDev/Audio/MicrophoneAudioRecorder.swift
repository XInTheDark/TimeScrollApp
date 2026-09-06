import Foundation
import AVFoundation

final class MicrophoneAudioRecorder: NSObject, @unchecked Sendable {
    private let selectedDeviceID: String?
    private let segmentDuration: TimeInterval
    private let onSegmentFinished: @Sendable (RecordedAudioSegment) -> Void

    private let session = AVCaptureSession()
    private let audioOutput = AVCaptureAudioFileOutput()
    private let sessionQueue = DispatchQueue(label: "TimeScroll.Audio.Microphone")

    private var segmentTimer: DispatchSourceTimer?
    private var activeOutputURL: URL?
    private var activeStartedAtMs: Int64?
    private var currentSourceDisplayName: String = AudioSourceKind.microphone.displayName
    private var configured = false
    private var stopping = false
    private var shouldStartNextSegmentAfterFinish = false
    private var stopContinuations: [CheckedContinuation<Void, Never>] = []

    init(selectedDeviceID: String?,
         segmentDuration: TimeInterval,
         onSegmentFinished: @escaping @Sendable (RecordedAudioSegment) -> Void) {
        self.selectedDeviceID = selectedDeviceID
        self.segmentDuration = segmentDuration
        self.onSegmentFinished = onSegmentFinished
        super.init()
    }

    func start() throws {
        try sessionQueue.sync {
            if !configured {
                try configureSessionLocked()
                configured = true
            }

            stopping = false
            shouldStartNextSegmentAfterFinish = false

            if !session.isRunning {
                session.startRunning()
            }

            startSegmentLocked()
            scheduleRotationLocked()
        }
    }

    func stop() async {
        await withCheckedContinuation { continuation in
          sessionQueue.async {
            self.stopContinuations.append(continuation)
            self.stopping = true
            self.shouldStartNextSegmentAfterFinish = false
            self.segmentTimer?.cancel()
            self.segmentTimer = nil

            if self.audioOutput.isRecording {
                self.audioOutput.stopRecording()
            } else {
                if self.session.isRunning {
                    self.session.stopRunning()
                }
                self.resumeStopContinuationsLocked()
            }
          }
        }
    }

    private func configureSessionLocked() throws {
        guard let device = AudioInputDeviceCatalog.device(uniqueID: selectedDeviceID) else {
            throw NSError(
                domain: "TimeScroll.Audio",
                code: -30,
                userInfo: [NSLocalizedDescriptionKey: "No microphone input is available."]
            )
        }

        currentSourceDisplayName = AudioInputDeviceCatalog.displayName(for: device.uniqueID) ?? device.localizedName
        let input = try AVCaptureDeviceInput(device: device)

        session.beginConfiguration()
        defer { session.commitConfiguration() }

        if session.canAddInput(input) {
            session.addInput(input)
        } else {
            throw NSError(
                domain: "TimeScroll.Audio",
                code: -31,
                userInfo: [NSLocalizedDescriptionKey: "Unable to add the selected microphone input."]
            )
        }

        if session.canAddOutput(audioOutput) {
            session.addOutput(audioOutput)
        } else {
            throw NSError(
                domain: "TimeScroll.Audio",
                code: -32,
                userInfo: [NSLocalizedDescriptionKey: "Unable to configure microphone recording output."]
            )
        }

        audioOutput.audioSettings = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVEncoderBitRateKey: 128_000,
        ]
    }

    private func scheduleRotationLocked() {
        segmentTimer?.cancel()

        let timer = DispatchSource.makeTimerSource(queue: sessionQueue)
        timer.schedule(deadline: .now() + segmentDuration, repeating: segmentDuration)
        timer.setEventHandler { [weak self] in
            self?.rotateSegmentLocked()
        }
        timer.resume()
        segmentTimer = timer
    }

    private func rotateSegmentLocked() {
        guard session.isRunning, !stopping else { return }

        if audioOutput.isRecording {
            shouldStartNextSegmentAfterFinish = true
            audioOutput.stopRecording()
        } else {
            startSegmentLocked()
        }
    }

    private func startSegmentLocked() {
        guard session.isRunning, !audioOutput.isRecording else { return }

        let outputURL = AudioStore.makeStagingURL(sourceKind: .microphone)
        activeOutputURL = outputURL
        activeStartedAtMs = Int64(Date().timeIntervalSince1970 * 1000)

        let availableFileTypes = AVCaptureAudioFileOutput.availableOutputFileTypes()
        let fileType = availableFileTypes.contains(.m4a)
            ? AVFileType.m4a
            : (availableFileTypes.first ?? .caf)
        audioOutput.startRecording(to: outputURL, outputFileType: fileType, recordingDelegate: self)
    }
}

extension MicrophoneAudioRecorder: AVCaptureFileOutputRecordingDelegate {
    func fileOutput(_ output: AVCaptureFileOutput,
                    didFinishRecordingTo outputFileURL: URL,
                    from connections: [AVCaptureConnection],
                    error: Error?) {
        sessionQueue.async {
            let startedAtMs = self.activeStartedAtMs ?? Int64(Date().timeIntervalSince1970 * 1000)
            self.activeStartedAtMs = nil
            self.activeOutputURL = nil

            if let error {
                fputs("[Audio][Microphone] Recording finished with error: \(error.localizedDescription)\n", stderr)
            }

            let fileExists = FileManager.default.fileExists(atPath: outputFileURL.path)
            if fileExists {
                let segment = RecordedAudioSegment(
                    sourceKind: .microphone,
                    sourceDisplayName: self.currentSourceDisplayName,
                    tempURL: outputFileURL,
                    startedAtMs: startedAtMs,
                    endedAtMs: Int64(Date().timeIntervalSince1970 * 1000),
                    mime: "audio/mp4",
                    sampleRate: nil,
                    channels: nil
                )
                self.onSegmentFinished(segment)
            }

            if self.stopping {
                if self.session.isRunning {
                    self.session.stopRunning()
                }
                self.resumeStopContinuationsLocked()
                return
            }

            if self.shouldStartNextSegmentAfterFinish {
                self.shouldStartNextSegmentAfterFinish = false
                self.startSegmentLocked()
            }
        }
    }

    private func resumeStopContinuationsLocked() {
        let continuations = stopContinuations
        stopContinuations.removeAll()
        continuations.forEach { $0.resume() }
    }
}

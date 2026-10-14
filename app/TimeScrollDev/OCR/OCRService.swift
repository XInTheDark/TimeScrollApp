import Foundation
import Vision
import CoreVideo
import CoreGraphics

struct OCRLine: Codable { let text: String; let box: CGRect }
struct OCRResult { let text: String; let lines: [OCRLine] }

final class OCRService {
    enum WatchdogError: Error {
        /// Vision did not return within the timeout; the call was abandoned.
        case timedOut
        /// An earlier abandoned call is still stuck inside Vision, so OCR is skipped.
        case stalled
    }

    /// How long one recognition may take before it is abandoned.
    static let defaultTimeout: TimeInterval = 20

    private var request: VNRecognizeTextRequest
    private var lastAccurate: Bool
    private let timeout: TimeInterval
    private let perform: (VNImageRequestHandler, VNRecognizeTextRequest) throws -> Void

    // Vision has been seen never returning from a text request. Running it on its own queue lets
    // the caller (the capture pipeline) give up instead of freezing with it.
    private let visionQueue = DispatchQueue(label: "TimeScroll.OCR.Vision", qos: .utility)
    private let lock = NSLock()
    private var stalled = false

    private final class Call {
        var finished = false
        var abandoned = false
        var error: Error?
    }

    init(timeout: TimeInterval = OCRService.defaultTimeout,
         perform: @escaping (VNImageRequestHandler, VNRecognizeTextRequest) throws -> Void = { try $0.perform([$1]) }) {
        let accurate = Self.accurateModeFromDefaults()
        self.request = Self.makeRequest(accurate: accurate)
        self.lastAccurate = accurate
        self.timeout = timeout
        self.perform = perform
    }

    var isStalled: Bool {
        lock.lock(); defer { lock.unlock() }
        return stalled
    }

    func recognize(from pixelBuffer: CVPixelBuffer) throws -> OCRResult {
        // A new call would queue behind the stuck one (pinning its frame buffer); skip until it returns.
        if isStalled { throw WatchdogError.stalled }
        applyModeFromDefaultsIfNeeded()
        let request = self.request
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .up)
        let call = Call()
        let done = DispatchSemaphore(value: 0)

        visionQueue.async { [perform] in
            var error: Error?
            do { try perform(handler, request) } catch let e { error = e }
            self.lock.lock()
            call.finished = true
            call.error = error
            if call.abandoned { self.stalled = false }
            self.lock.unlock()
            done.signal()
        }

        if done.wait(timeout: .now() + timeout) == .timedOut {
            lock.lock()
            let abandon = !call.finished
            if abandon {
                call.abandoned = true
                stalled = true
            }
            lock.unlock()
            if abandon {
                request.cancel()
                self.request = Self.makeRequest(accurate: lastAccurate)
                fputs("[OCR] Text recognition did not finish within \(Int(timeout))s; skipping OCR until it returns.\n", stderr)
                throw WatchdogError.timedOut
            }
        }

        lock.lock()
        let error = call.error
        lock.unlock()
        if let error { throw error }

        let observations = request.results ?? []
        var text = ""
        var lines: [OCRLine] = []
        for o in observations {
            if let top = o.topCandidates(1).first {
                text.append(top.string)
                text.append("\n")
                lines.append(OCRLine(text: top.string, box: o.boundingBox))
            }
        }
        return OCRResult(text: text, lines: lines)
    }

    private static func accurateModeFromDefaults() -> Bool {
        let raw = UserDefaults.standard.string(forKey: "settings.ocrMode") ?? SettingsStore.defaultOCRMode.rawValue
        return raw == SettingsStore.OCRMode.accurate.rawValue
    }

    private static func makeRequest(accurate: Bool) -> VNRecognizeTextRequest {
        let req = VNRecognizeTextRequest()
        req.recognitionLevel = accurate ? .accurate : .fast
        req.usesLanguageCorrection = accurate
        return req
    }

    private func applyModeFromDefaultsIfNeeded() {
        let accurate = Self.accurateModeFromDefaults()
        if accurate != lastAccurate {
            request.recognitionLevel = accurate ? .accurate : .fast
            request.usesLanguageCorrection = accurate
            lastAccurate = accurate
        }
    }
}

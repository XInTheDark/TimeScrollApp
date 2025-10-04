import Foundation
import Vision
import CoreVideo
import CoreGraphics

struct OCRLine: Codable { let text: String; let box: CGRect }
struct OCRResult { let text: String; let lines: [OCRLine] }

final class OCRService {
    private let request: VNRecognizeTextRequest
    private var lastAccurate: Bool

    init() {
        let req = VNRecognizeTextRequest()
        let raw = UserDefaults.standard.string(forKey: "settings.ocrMode") ?? "accurate"
        let accurate = (raw == "accurate")
        req.recognitionLevel = accurate ? .accurate : .fast
        req.usesLanguageCorrection = accurate
        self.request = req
        self.lastAccurate = accurate
    }

    func recognize(from pixelBuffer: CVPixelBuffer) throws -> OCRResult {
        applyModeFromDefaultsIfNeeded()
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .up)
        try handler.perform([request])
        let observations = request.results as? [VNRecognizedTextObservation] ?? []
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

    private func applyModeFromDefaultsIfNeeded() {
        let raw = UserDefaults.standard.string(forKey: "settings.ocrMode") ?? "accurate"
        let accurate = (raw == "accurate")
        if accurate != lastAccurate {
            request.recognitionLevel = accurate ? .accurate : .fast
            request.usesLanguageCorrection = accurate
            lastAccurate = accurate
        }
    }
}

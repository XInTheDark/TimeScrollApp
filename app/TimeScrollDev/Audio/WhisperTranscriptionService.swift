import Foundation
import WhisperKit

actor WhisperTranscriptionService {
    static let shared = WhisperTranscriptionService()

    private var loadedModelID: String?
    private var whisperKit: WhisperKit?

    func transcribe(audioURL: URL, modelID: String) async throws -> [AudioTranscriptSegment] {
        guard WhisperModelStore.isModelAvailable(modelID) else {
            throw NSError(domain: "TimeScroll.Audio",
                          code: -60,
                          userInfo: [NSLocalizedDescriptionKey: "The selected Whisper model or tokenizer is not installed."])
        }

        let kit = try await whisperKit(for: modelID)
        let results = try await kit.transcribe(audioPath: audioURL.path,
                                               decodeOptions: DecodingOptions(verbose: false,
                                                                              usePrefillPrompt: true,
                                                                              detectLanguage: true,
                                                                              wordTimestamps: true,
                                                                              chunkingStrategy: .vad))
        let segments = results
            .flatMap(\.segments)
            .sorted { lhs, rhs in
                if lhs.start == rhs.start {
                    return lhs.id < rhs.id
                }
                return lhs.start < rhs.start
            }
        return segments.enumerated().compactMap { index, segment in
            let text = sanitizeTranscriptText(segment.text)
            guard !text.isEmpty else { return nil }
            return AudioTranscriptSegment(id: index,
                                          relativeStartMs: Int64((segment.start * 1000).rounded()),
                                          relativeEndMs: Int64((segment.end * 1000).rounded()),
                                          text: text)
        }
    }

    private func whisperKit(for modelID: String) async throws -> WhisperKit {
        if loadedModelID == modelID, let whisperKit {
            return whisperKit
        }

        guard let modelDirectory = WhisperModelStore.resolvedModelDirectory(for: modelID) else {
            throw NSError(
                domain: "TimeScroll.Audio",
                code: -60,
                userInfo: [NSLocalizedDescriptionKey: "The selected Whisper model is not installed yet."]
            )
        }

        let config = WhisperKitConfig(model: modelID,
                                      downloadBase: WhisperModelStore.modelsBaseURL(),
                                      modelFolder: modelDirectory.path,
                                      tokenizerFolder: WhisperModelStore.modelsBaseURL(),
                                      verbose: false,
                                      prewarm: false,
                                      download: false,
                                      useBackgroundDownloadSession: false)
        let whisperKit = try await WhisperKit(config)
        self.whisperKit = whisperKit
        self.loadedModelID = modelID
        return whisperKit
    }

    private func sanitizeTranscriptText(_ rawText: String) -> String {
        let withoutSpecialTokens = rawText.replacingOccurrences(
            of: #"<\|[^|]+?\|>"#,
            with: " ",
            options: .regularExpression
        )
        let withoutSilenceMarkers = withoutSpecialTokens.replacingOccurrences(
            of: #"\[\s*silence\s*\]"#,
            with: " ",
            options: [.regularExpression, .caseInsensitive]
        )
        let collapsedWhitespace = withoutSilenceMarkers.replacingOccurrences(
            of: #"\s+"#,
            with: " ",
            options: .regularExpression
        )
        return collapsedWhitespace.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

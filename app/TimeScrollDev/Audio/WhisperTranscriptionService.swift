import Foundation
import WhisperKit

actor WhisperTranscriptionService {
    static let shared = WhisperTranscriptionService()

    private var loadedModelID: String?
    private var whisperKit: WhisperKit?
    private var idleUnloadTask: Task<Void, Never>?
    /// Models hold hundreds of MB; release them when transcription has been idle this long.
    private static let idleUnloadNanoseconds: UInt64 = 5 * 60 * 1_000_000_000

    /// Transcribes a file. Pass `language` to skip language detection; the returned language
    /// is the one used (detected or given).
    func transcribe(audioURL: URL, modelID: String, language: String? = nil) async throws -> (segments: [AudioTranscriptSegment], language: String?) {
        idleUnloadTask?.cancel()
        defer { scheduleIdleUnload() }
        guard WhisperModelStore.isModelAvailable(modelID) else {
            throw NSError(domain: "TimeScroll.Audio",
                          code: -60,
                          userInfo: [NSLocalizedDescriptionKey: "The selected Whisper model or tokenizer is not installed."])
        }

        let kit = try await whisperKit(for: modelID)
        let results = try await kit.transcribe(audioPath: audioURL.path,
                                               decodeOptions: DecodingOptions(verbose: false,
                                                                              language: language,
                                                                              usePrefillPrompt: true,
                                                                              detectLanguage: language == nil,
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
        let transcript: [AudioTranscriptSegment] = segments.enumerated().compactMap { index, segment in
            let text = sanitizeTranscriptText(segment.text)
            guard !text.isEmpty else { return nil }
            return AudioTranscriptSegment(id: index,
                                          relativeStartMs: Int64((segment.start * 1000).rounded()),
                                          relativeEndMs: Int64((segment.end * 1000).rounded()),
                                          text: text)
        }
        return (transcript, results.first?.language ?? language)
    }

    private func scheduleIdleUnload() {
        idleUnloadTask?.cancel()
        idleUnloadTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: Self.idleUnloadNanoseconds)
            guard !Task.isCancelled else { return }
            await self?.unloadModel()
        }
    }

    private func unloadModel() async {
        guard let kit = whisperKit else { return }
        whisperKit = nil
        loadedModelID = nil
        await kit.unloadModels()
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

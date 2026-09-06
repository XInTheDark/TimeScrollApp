import Foundation

struct RecordedAudioSegment: Sendable {
    let sourceKind: AudioSourceKind
    let sourceDisplayName: String
    let tempURL: URL
    let startedAtMs: Int64
    let endedAtMs: Int64
    let mime: String
    let sampleRate: Int?
    let channels: Int?
}

actor AudioSegmentProcessor {
    static let shared = AudioSegmentProcessor()

    private var workerRunning = false
    private var processingPaused = false
    private var pauseGeneration = 0
    private var activeTranscriptionInputURL: URL?
    private var drainContinuations: [UUID: CheckedContinuation<Bool, Never>] = [:]

    func submit(_ segment: RecordedAudioSegment, modelID: String) {
        guard FileManager.default.fileExists(atPath: segment.tempURL.path) else { return }

        var finalizedURL: URL?
        do {
            let finalized = try AudioStore.finalizeRecordedSegment(at: segment.tempURL,
                                                                   startedAtMs: segment.startedAtMs,
                                                                   sourceKind: segment.sourceKind,
                                                                   mime: segment.mime)
            finalizedURL = finalized.url
            let durationMs = max(0, segment.endedAtMs - segment.startedAtMs)
            _ = try DB.shared.insertPendingAudioCapture(startedAtMs: segment.startedAtMs,
                                                       endedAtMs: segment.endedAtMs,
                                                       path: finalized.url.path,
                                                       sourceKind: segment.sourceKind,
                                                       sourceDisplayName: segment.sourceDisplayName,
                                                       bytes: finalized.bytes,
                                                       durationMs: durationMs,
                                                       mime: segment.mime,
                                                       sampleRate: segment.sampleRate,
                                                       channels: segment.channels,
                                                       modelID: modelID)
            Task { @MainActor in
                AppState.shared.lastSnapshotTick &+= 1
            }
            startWorkerIfNeeded()
        } catch {
            fputs("[Audio] Failed to accept audio segment \(segment.tempURL.lastPathComponent): \(error.localizedDescription)\n", stderr)
            if let finalizedURL {
                try? FileManager.default.removeItem(at: finalizedURL)
            }
        }
    }

    func resumePendingWork() {
        processingPaused = false
        AudioStore.cleanupAbandonedTranscriptionInputs()
        let requestedModel = UserDefaults.standard.string(forKey: "settings.whisperModelID")?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let modelID = requestedModel?.isEmpty == false ? requestedModel! : SettingsStore.defaultWhisperModelID
        for segment in AudioStore.abandonedRecordedSegments() {
            submit(segment, modelID: modelID)
        }
        startWorkerIfNeeded()
    }

    func pauseForVaultLock() {
        processingPaused = true
        pauseGeneration &+= 1
        if let activeTranscriptionInputURL {
            AudioStore.removeTranscriptionInputIfTemporary(activeTranscriptionInputURL)
        }
    }

    func retry(assetID: Int64, modelID: String) throws {
        guard WhisperModelStore.isModelAvailable(modelID) else {
            throw NSError(domain: "TimeScroll.Audio",
                          code: -62,
                          userInfo: [NSLocalizedDescriptionKey: "Download the selected Whisper model before retrying."])
        }
        try DB.shared.markAudioTranscriptionPending(assetID: assetID, modelID: modelID)
        startWorkerIfNeeded()
    }

    func hasPendingWork(modelID: String) -> Bool {
        (try? DB.shared.hasPendingAudioTranscriptions(modelID: modelID)) ?? false
    }

    @discardableResult
    func drain(timeoutNanoseconds: UInt64? = nil) async -> Bool {
        startWorkerIfNeeded()
        guard workerRunning else { return true }
        let id = UUID()
        return await withCheckedContinuation { continuation in
            drainContinuations[id] = continuation
            if let timeoutNanoseconds {
                Task {
                    try? await Task.sleep(nanoseconds: timeoutNanoseconds)
                    self.timeoutDrain(id: id)
                }
            }
        }
    }

    private func startWorkerIfNeeded() {
        guard !workerRunning, !processingPaused else { return }
        guard (try? DB.shared.nextPendingAudioTranscription()) != nil else {
            finishDraining()
            return
        }
        workerRunning = true
        Task { await runWorker() }
    }

    private func runWorker() async {
        while !processingPaused, let job = try? DB.shared.nextPendingAudioTranscription() {
            await process(job)
        }
        workerRunning = false
        finishDraining()
    }

    private func process(_ job: AudioTranscriptionJob) async {
        let processingGeneration = pauseGeneration
        let modelID = job.asset.transcriptionModelID ?? SettingsStore.defaultWhisperModelID
        let storedURL = URL(fileURLWithPath: job.asset.path)
        let inputURL: URL

        do {
            inputURL = try AudioStore.transcriptionInputURL(for: storedURL)
        } catch {
            recordFailure(job: job, error: error)
            return
        }
        activeTranscriptionInputURL = inputURL
        defer {
            AudioStore.removeTranscriptionInputIfTemporary(inputURL)
            activeTranscriptionInputURL = nil
        }

        do {
            let segments = try await WhisperTranscriptionService.shared.transcribe(audioURL: inputURL, modelID: modelID)
            guard !processingPaused, pauseGeneration == processingGeneration else { return }
            let text = segments
                .map(\.text)
                .joined(separator: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            try DB.shared.completeAudioTranscription(assetID: job.asset.id,
                                                     snapshotID: job.snapshotID,
                                                     segments: segments,
                                                     text: text)
            storeEmbeddingIfNeeded(snapshotID: job.snapshotID, transcriptText: text)
            await notifyTimelineChanged()
        } catch {
            guard !processingPaused, pauseGeneration == processingGeneration else { return }
            recordFailure(job: job, error: error)
        }
    }

    private func recordFailure(job: AudioTranscriptionJob, error: Error) {
        let message = error.localizedDescription
        fputs("[Audio][Whisper] Transcription failed for \(job.asset.path): \(message)\n", stderr)
        try? DB.shared.failAudioTranscription(assetID: job.asset.id, errorMessage: message)
        Task { await notifyTimelineChanged() }
    }

    private func notifyTimelineChanged() async {
        await MainActor.run {
            AppState.shared.lastSnapshotTick &+= 1
        }
    }

    private func finishDraining() {
        let continuations = drainContinuations.values
        drainContinuations.removeAll()
        continuations.forEach { $0.resume(returning: true) }
    }

    private func timeoutDrain(id: UUID) {
        guard let continuation = drainContinuations.removeValue(forKey: id) else { return }
        continuation.resume(returning: false)
    }

    private func storeEmbeddingIfNeeded(snapshotID: Int64, transcriptText: String) {
        let trimmed = transcriptText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let defaults = UserDefaults.standard
        guard defaults.bool(forKey: "settings.aiEmbeddingsEnabled") else { return }

        let service = EmbeddingService.shared
        service.reloadFromSettings(onlyIfSelectionChanged: true)
        guard service.dim > 0 else { return }

        let vector = service.embed(trimmed, usage: .document)
        guard !vector.isEmpty else { return }

        do {
            let updatedAtMs = try DB.shared.upsertEmbedding(snapshotId: snapshotID,
                                                            dim: vector.count,
                                                            vec: vector,
                                                            provider: service.providerID,
                                                            model: service.modelID)
            guard let meta = try DB.shared.snapshotMetaById(snapshotID) else { return }
            let identity = VectorSearchIdentity(provider: service.providerID,
                                                model: service.modelID,
                                                dim: vector.count,
                                                dbPath: DB.shared.dbURL?.path ?? StoragePaths.dbURL().path)
            EmbeddingANNIndexStore.shared.recordUpsert(identity: identity,
                                                       snapshotId: snapshotID,
                                                       startedAtMs: meta.startedAtMs,
                                                       appBundleId: meta.appBundleId,
                                                       vector: vector,
                                                       updatedAtMs: updatedAtMs)
        } catch {
            fputs("[Audio][Embedding] Failed to index transcript: \(error.localizedDescription)\n", stderr)
        }
    }
}

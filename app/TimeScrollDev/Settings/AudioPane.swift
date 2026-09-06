import SwiftUI

@MainActor
struct AudioPane: View {
    @ObservedObject var settings: SettingsStore
    @ObservedObject private var appState = AppState.shared

    @State private var activeDownloadModelID: String?
    @State private var downloadTask: Task<Void, Never>?
    @State private var downloadGeneration: Int = 0
    @State private var downloadProgress: Double = 0
    @State private var didRepairInterruptedDownloads = false
    @State private var message: String?
    @State private var microphonePermissionGranted = Permissions.isMicrophoneGranted()

    private var availableDevices: [AudioInputDevice] {
        AudioInputDeviceCatalog.availableDevices()
    }

    private var isDownloadingModel: Bool {
        activeDownloadModelID != nil
    }

    private var isSelectedModelDownloading: Bool {
        activeDownloadModelID == settings.whisperModelID
    }

    private var activeDownloadTitle: String {
        guard let activeDownloadModelID else { return "Whisper model" }
        return WhisperModelCatalog.descriptor(for: activeDownloadModelID)?.title ?? activeDownloadModelID
    }

    var body: some View {
        SettingsPaneScrollView {
            SettingsSectionCard(
                title: "Audio Capture",
                subtitle: "Keep raw recordings and Whisper transcripts in the same timeline and search flow."
            ) {
                Toggle("Enable optional audio recording", isOn: restartingBinding($settings.audioFeatureEnabled))

                if settings.audioFeatureEnabled {
                    Divider()

                    Toggle("Record screen snapshots", isOn: restartingBinding($settings.captureScreenEnabled))
                    Toggle("Include audio when capture starts", isOn: restartingBinding($settings.captureAudioEnabled))
                    Toggle("Record microphone audio", isOn: restartingBinding($settings.captureMicrophoneEnabled))
                        .disabled(!settings.captureAudioEnabled)
                    Toggle("Record system audio", isOn: restartingBinding($settings.captureSystemAudioEnabled))
                        .disabled(!settings.captureAudioEnabled)

                    LabeledContent("Segment length") {
                        Picker("Segment length", selection: restartingBinding($settings.audioSegmentDurationSeconds)) {
                            Text("10 sec").tag(10)
                            Text("15 sec").tag(15)
                            Text("30 sec").tag(30)
                            Text("60 sec").tag(60)
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                    }

                    if !settings.captureScreenEnabled && (!settings.captureAudioEnabled || (!settings.captureMicrophoneEnabled && !settings.captureSystemAudioEnabled)) {
                        Label("Enable at least one source before starting capture.", systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.secondary)
                    }

                    if hasSelectedAudioSource && !WhisperModelStore.isModelAvailable(settings.whisperModelID) {
                        Label("Download the selected Whisper model before audio capture can start.", systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                    }
                } else {
                    Text("When audio is off, TimeScroll keeps its current screen-only capture behavior.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }

            if settings.audioFeatureEnabled {
                SettingsSectionCard(
                    title: "Microphone Input",
                    subtitle: "Choose which input device is used for microphone segments."
                ) {
                    LabeledContent("Permission") {
                        HStack(spacing: 8) {
                            Image(systemName: microphonePermissionGranted ? "checkmark.circle.fill" : "exclamationmark.circle")
                                .foregroundStyle(microphonePermissionGranted ? .green : .orange)
                            Text(microphonePermissionGranted ? "Granted" : "Required")
                        }
                    }

                    if settings.captureMicrophoneEnabled {
                        Picker("Input", selection: restartingBinding($settings.selectedAudioInputDeviceID)) {
                            Text("System Default")
                                .tag("")
                            ForEach(availableDevices) { device in
                                Text(device.name)
                                    .tag(device.uniqueID)
                            }
                        }
                        .pickerStyle(.menu)

                        Button("Request Microphone Access") {
                            Task {
                                microphonePermissionGranted = await Permissions.requestMicrophone()
                                if microphonePermissionGranted {
                                    await AppState.shared.retryNewlyAuthorizedSourcesIfNeeded()
                                }
                            }
                        }
                        .buttonStyle(.bordered)
                    }
                }

                SettingsSectionCard(
                    title: "Whisper Models",
                    subtitle: "Models are downloaded on demand and reused for future captures."
                ) {
                    Picker("Model", selection: restartingBinding($settings.whisperModelID)) {
                        ForEach(WhisperModelCatalog.descriptors) { descriptor in
                            Text(descriptor.recommended ? "\(descriptor.title) — Recommended" : descriptor.title)
                                .tag(descriptor.id)
                        }
                    }
                    .pickerStyle(.menu)
                    .disabled(isDownloadingModel)

                    if let descriptor = WhisperModelCatalog.descriptor(for: settings.whisperModelID) {
                        Text(descriptor.subtitle)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }

                    HStack(spacing: 10) {
                        if isSelectedModelDownloading {
                            Label("Downloading", systemImage: "arrow.down.circle.fill")
                                .foregroundStyle(.blue)

                            Button("Cancel Download") {
                                cancelDownload()
                            }
                            .buttonStyle(.bordered)
                        } else if WhisperModelStore.isModelAvailable(settings.whisperModelID) {
                            Label("Installed", systemImage: "checkmark.circle.fill")
                                .foregroundStyle(.green)

                            Button("Remove Model") {
                                removeSelectedModel()
                            }
                            .buttonStyle(.bordered)
                            .disabled(isDownloadingModel || appState.isCapturing)
                        } else {
                            Button("Download Model") {
                                downloadSelectedModel()
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(isDownloadingModel)
                        }
                    }

                    if isSelectedModelDownloading {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Downloading \(activeDownloadTitle)…")
                                .font(.subheadline.weight(.medium))
                            ProgressView(value: downloadProgress)
                                .progressViewStyle(.linear)
                        }
                    }

                    if let message {
                        Text(message)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .onAppear {
            microphonePermissionGranted = Permissions.isMicrophoneGranted()
            repairInterruptedDownloadsIfNeeded()
        }
    }

    private var hasSelectedAudioSource: Bool {
        settings.captureAudioEnabled && (settings.captureMicrophoneEnabled || settings.captureSystemAudioEnabled)
    }

    private func restartingBinding<T>(_ binding: Binding<T>) -> Binding<T> {
        Binding(
            get: { binding.wrappedValue },
            set: { newValue in
                binding.wrappedValue = newValue
                Task { @MainActor in
                    await AppState.shared.restartCaptureIfRunning()
                }
            }
        )
    }

    private func removeSelectedModel() {
        let modelID = settings.whisperModelID
        Task {
            if await AudioSegmentProcessor.shared.hasPendingWork(modelID: modelID) {
                message = "Wait for pending \(modelID) transcriptions to finish before removing the model."
                return
            }
            do {
                try WhisperModelStore.remove(modelID: modelID)
                message = "Removed \(modelID)."
            } catch {
                message = error.localizedDescription
            }
        }
    }

    private func downloadSelectedModel() {
        guard !isDownloadingModel else { return }
        let modelID = settings.whisperModelID
        downloadGeneration &+= 1
        let generation = downloadGeneration
        activeDownloadModelID = modelID
        downloadProgress = 0
        message = nil

        downloadTask = Task {
            do {
                _ = try await Task.detached(priority: .utility) {
                    try WhisperModelStore.cleanupInterruptedDownload(modelID: modelID)
                }.value

                _ = try await WhisperModelStore.download(modelID: modelID) { progress in
                    Task { @MainActor in
                        guard downloadGeneration == generation else { return }
                        downloadProgress = progress.fractionCompleted
                    }
                }
                await MainActor.run {
                    guard downloadGeneration == generation else { return }
                    message = "\(modelID) is ready for future captures."
                    activeDownloadModelID = nil
                    downloadProgress = 0
                    downloadTask = nil
                }
                await AppState.shared.retryNewlyAuthorizedSourcesIfNeeded()
            } catch is CancellationError {
                await MainActor.run {
                    guard downloadGeneration == generation else { return }
                    activeDownloadModelID = nil
                    downloadProgress = 0
                    downloadTask = nil
                    if message == nil {
                        message = "Cancelled \(modelID) download."
                    }
                }
            } catch {
                await MainActor.run {
                    guard downloadGeneration == generation else { return }
                    message = error.localizedDescription
                    activeDownloadModelID = nil
                    downloadProgress = 0
                    downloadTask = nil
                }
            }
        }
    }

    private func cancelDownload() {
        guard let modelID = activeDownloadModelID else { return }

        downloadGeneration &+= 1
        let generation = downloadGeneration
        downloadTask?.cancel()
        downloadTask = nil
        activeDownloadModelID = nil
        downloadProgress = 0
        message = "Cancelling \(modelID)…"

        Task {
            let nextMessage: String
            do {
                _ = try await Task.detached(priority: .utility) {
                    try WhisperModelStore.cleanupInterruptedDownload(modelID: modelID)
                }.value
                nextMessage = "Cancelled \(modelID) download."
            } catch {
                nextMessage = "Cancelled \(modelID) download, but couldn’t clear partial files: \(error.localizedDescription)"
            }

            await MainActor.run {
                guard downloadGeneration == generation else { return }
                message = nextMessage
            }
        }
    }

    private func repairInterruptedDownloadsIfNeeded() {
        guard !didRepairInterruptedDownloads else { return }
        didRepairInterruptedDownloads = true

        Task {
            let cleanedModels = await Task.detached(priority: .utility) { () -> [String] in
                WhisperModelCatalog.descriptors.compactMap { descriptor in
                    do {
                        return try WhisperModelStore.cleanupInterruptedDownload(modelID: descriptor.id) ? descriptor.id : nil
                    } catch {
                        return nil
                    }
                }
            }.value

            guard !cleanedModels.isEmpty else { return }

            await MainActor.run {
                if cleanedModels.count == 1, let first = cleanedModels.first {
                    message = "Cleared an interrupted download for \(first). You can start it again."
                } else {
                    message = "Cleared interrupted Whisper downloads. You can start them again."
                }
            }
        }
    }
}

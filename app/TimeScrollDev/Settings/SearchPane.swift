import SwiftUI
import AppKit

@MainActor
struct SearchPane: View {
    @ObservedObject var settings: SettingsStore
    @ObservedObject private var rebuildController = EmbeddingRebuildController.shared
    @State private var isInstallingModel = false
    @State private var installError: String?
    @State private var availableOllamaModels: [String] = []
    @State private var loadingModels = false
    @State private var modelInstalled = false
    @State private var checkingModelInstall = false
    @State private var mobileCLIPRelease: MobileCLIPLatestRelease?
    @State private var loadingMobileCLIPRelease = false
    @State private var mobileCLIPActionInFlight = false
    @State private var mobileCLIPIsRemoving = false
    @State private var mobileCLIPDownloadProgress: Double?
    @State private var mobileCLIPError: String?
    @State private var showAdvancedRanking = false

    var body: some View {
        SettingsPaneScrollView {
            SettingsSectionCard(
                title: "Search Behavior",
                subtitle: "Highlight boxes only appear when OCR box data exists for a snapshot."
            ) {
                VStack(alignment: .leading, spacing: 14) {
                    LabeledContent("Fuzziness") {
                        Picker("", selection: $settings.fuzziness) {
                            ForEach(SettingsStore.Fuzziness.allCases) { fuzziness in
                                Text(fuzziness.rawValue.capitalized).tag(fuzziness)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.segmented)
                        .frame(maxWidth: 280)
                    }

                    Toggle("Show highlight boxes", isOn: $settings.showHighlights)
                    Toggle("Use intelligent OCR matching", isOn: $settings.intelligentAccuracy)
                }
            }

            SettingsSectionCard(title: "AI Search", subtitle: aiSectionSubtitle) {
                VStack(alignment: .leading, spacing: 14) {
                    Toggle("Enable AI search", isOn: $settings.aiEmbeddingsEnabled)

                    if settings.aiEmbeddingsEnabled {
                        LabeledContent("Provider") {
                            Picker("", selection: $settings.embeddingProvider) {
                                ForEach(EmbeddingService.Provider.allCases, id: \.rawValue) { provider in
                                    Text(provider.displayName).tag(provider.rawValue)
                                }
                            }
                            .labelsHidden()
                            .pickerStyle(.menu)
                            .frame(width: 280)
                        }

                        if settings.embeddingProvider == "ollama" {
                            ollamaModelCard
                        } else if settings.embeddingProvider == "mobileclip2" {
                            mobileCLIPModelCard
                        }

                        Toggle("Default searches to AI mode", isOn: $settings.aiModeOn)

                        DisclosureGroup("Advanced ranking", isExpanded: $showAdvancedRanking) {
                            VStack(alignment: .leading, spacing: 12) {
                                LabeledContent("Similarity threshold") {
                                    HStack {
                                    Slider(value: $settings.aiThreshold, in: 0.0...0.6, step: 0.05)
                                    Text(String(format: "%.2f", settings.aiThreshold))
                                        .monospacedDigit()
                                        .frame(width: 44, alignment: .trailing)
                                }
                            }

                                LabeledContent("Max candidates") {
                                    HStack(spacing: 6) {
                                        TextField("", value: $settings.aiMaxCandidates, formatter: Self.aiIntFormatter)
                                            .frame(width: 90)
                                        Text("rows")
                                            .foregroundColor(.secondary)
                                    }
                            }
                        }
                        .padding(.top, 8)
                    }

                    if settings.embeddingProvider == "mobileclip2" {
                        Text("MobileCLIP2 usually needs a lower similarity threshold than text-only embedding models.")
                            .font(.footnote)
                            .foregroundColor(.secondary)
                    }

                    embeddingLibraryCard
                }
            }
            }
        }
        .onAppear {
            ensureValidModelSelectionForProvider()
            if settings.aiEmbeddingsEnabled && settings.embeddingProvider == "ollama" {
                loadOllamaModelsIfNeeded()
                refreshModelInstallState()
            } else if settings.aiEmbeddingsEnabled && settings.embeddingProvider == "mobileclip2" {
                refreshMobileCLIPReleaseIfNeeded()
            }
        }
        .onChange(of: settings.aiEmbeddingsEnabled) { enabled in
            if enabled && settings.embeddingProvider == "ollama" {
                loadOllamaModelsIfNeeded()
                refreshModelInstallState()
            } else if enabled && settings.embeddingProvider == "mobileclip2" {
                refreshMobileCLIPReleaseIfNeeded(force: true)
            }
        }
        .onChange(of: settings.embeddingProvider) { _ in
            ensureValidModelSelectionForProvider()
            if settings.embeddingProvider == "ollama" {
                loadOllamaModelsIfNeeded()
            } else if settings.embeddingProvider == "mobileclip2" {
                refreshMobileCLIPReleaseIfNeeded()
            }
            refreshModelInstallState()
        }
        .onChange(of: settings.embeddingModel) { _ in
            refreshModelInstallState()
            mobileCLIPError = nil
        }
    }

    private var aiSectionSubtitle: String {
        settings.aiEmbeddingsEnabled
        ? "AI search improves ranking with local embeddings and may use more disk space and energy."
        : "Turn this on to use local embeddings for more semantic search results."
    }

    private var ollamaModelCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text("Ollama Model")
                    .font(.headline)

                Spacer()

                if loadingModels {
                    ProgressView()
                        .controlSize(.small)
                }
            }

            if loadingModels {
                HStack(spacing: 8) {
                    ProgressView()
                    Text("Discovering models…")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }
            } else {
                LabeledContent("Model") {
                    Picker("", selection: $settings.embeddingModel) {
                        ForEach(availableOllamaModels, id: \.self) { model in
                            Text(model).tag(model)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(width: 300)
                }
            }

            modelStatusView
        }
        .settingsInsetCard()
    }

    private var mobileCLIPModelCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text("MobileCLIP2")
                    .font(.headline)

                Spacer()

                if let release = mobileCLIPRelease {
                    Text("Release \(release.tagName)")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }
            }

            LabeledContent("Model") {
                Picker("", selection: $settings.embeddingModel) {
                    ForEach(MobileCLIPModelCatalog.Model.allCases) { model in
                        Text("\(model.displayName) — \(model.subtitle)").tag(model.rawValue)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(width: 320)
            }

            mobileCLIPStatusView

            Toggle("Blend extracted text into multimodal embeddings", isOn: $settings.multimodalIncludeExtractedText)
                .toggleStyle(.switch)

            Text("Assets are pulled from the latest release in XInTheDark/MobileCLIP2-coreml.")
                .font(.footnote)
                .foregroundColor(.secondary)
        }
        .settingsInsetCard()
    }

    private var embeddingLibraryCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text("Embedding Library")
                    .font(.headline)

                Spacer()

                Text(activeEmbeddingSummary)
                    .font(.footnote)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            HStack(spacing: 10) {
                Button(rebuildController.isRunning ? "Rebuilding…" : "Rebuild embeddings") {
                    rebuildController.start()
                }
                .buttonStyle(.borderedProminent)
                .disabled(rebuildController.isRunning || EmbeddingService.shared.dim == 0)

                if let rebuildStatusText {
                    Text(rebuildStatusText)
                        .font(.footnote)
                        .foregroundColor(.secondary)
                        .monospacedDigit()
                }
            }

            Text("Changing provider or model only affects new captures until you rebuild.")
                .font(.footnote)
                .foregroundColor(.secondary)
        }
        .settingsInsetCard()
    }

    private var activeEmbeddingSummary: String {
        let providerName = EmbeddingService.Provider(rawValue: settings.embeddingProvider)?.displayName ?? settings.embeddingProvider
        guard !settings.embeddingModel.isEmpty else { return providerName }
        return "\(providerName) • \(settings.embeddingModel)"
    }

    private var rebuildStatusText: String? {
        if rebuildController.isRunning {
            let total = max(rebuildController.total, rebuildController.processed)
            let percent = Self.percentString(for: rebuildController.fractionCompleted)
            return "\(percent) • \(rebuildController.processed)/\(total)"
        }

        return rebuildController.lastMessage
    }

    @ViewBuilder
    private var modelStatusView: some View {
        if settings.embeddingModel.isEmpty {
            Text("Select a model to continue.")
                .font(.footnote)
                .foregroundColor(.secondary)
        } else if checkingModelInstall {
            HStack(spacing: 8) {
                ProgressView()
                Text("Checking install status…")
                    .font(.footnote)
                    .foregroundColor(.secondary)
            }
        } else if modelInstalled {
            Label("Model installed", systemImage: "checkmark.circle.fill")
                .font(.footnote)
                .foregroundColor(.secondary)
        } else {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Label("Model not installed", systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote)
                        .foregroundColor(.secondary)

                    Spacer()

                    Button(isInstallingModel ? "Installing…" : "Install") {
                        installOllamaModel()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isInstallingModel)
                }

                if let installError {
                    Text(installError)
                        .font(.footnote)
                        .foregroundColor(.red)
                }
            }
        }
    }

    @ViewBuilder
    private var mobileCLIPStatusView: some View {
        if loadingMobileCLIPRelease {
            HStack(spacing: 8) {
                ProgressView()
                Text("Checking latest release…")
                    .font(.footnote)
                    .foregroundColor(.secondary)
            }
        } else if let selectedModel = selectedMobileCLIPModel {
            let installed = MobileCLIPModelStore.isInstalled(selectedModel)
            let asset = mobileCLIPRelease?.asset(for: selectedModel)

            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    mobileCLIPStateLabel(installed: installed, assetAvailable: asset != nil)

                    Spacer()

                    if installed {
                        Button(mobileCLIPIsRemoving ? "Removing…" : "Remove") {
                            removeSelectedMobileCLIPModel()
                        }
                        .buttonStyle(.bordered)
                        .disabled(mobileCLIPActionInFlight)
                    } else if asset != nil {
                        Button(mobileCLIPDownloadButtonTitle) {
                            installSelectedMobileCLIPModel()
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(mobileCLIPActionInFlight)
                    }
                }

                Text(mobileCLIPStatusDetailText(asset: asset))
                    .font(.footnote)
                    .foregroundColor(.secondary)
                    .monospacedDigit()

                if let mobileCLIPError {
                    Text(mobileCLIPError)
                        .font(.footnote)
                        .foregroundColor(.red)
                }
            }
        } else {
            Text("Select a MobileCLIP2 model to continue.")
                .font(.footnote)
                .foregroundColor(.secondary)
        }
    }
}

extension SearchPane {
    private static var aiIntFormatter: NumberFormatter {
        let formatter = NumberFormatter()
        formatter.numberStyle = .none
        formatter.minimum = 100
        formatter.maximum = 100000
        return formatter
    }

    private static var byteCountFormatter: ByteCountFormatter {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowedUnits = [.useMB, .useGB]
        return formatter
    }

    private static var percentFormatter: NumberFormatter {
        let formatter = NumberFormatter()
        formatter.numberStyle = .percent
        formatter.maximumFractionDigits = 0
        return formatter
    }

    private static func percentString(for value: Double) -> String {
        let clamped = max(0, min(1, value))
        return percentFormatter.string(from: NSNumber(value: clamped)) ?? "\(Int((clamped * 100).rounded()))%"
    }

    private var selectedMobileCLIPModel: MobileCLIPModelCatalog.Model? {
        MobileCLIPModelCatalog.Model(rawValue: settings.embeddingModel)
    }

    private var mobileCLIPDownloadButtonTitle: String {
        guard mobileCLIPActionInFlight else { return "Download" }
        if let progress = mobileCLIPDownloadProgress, progress < 0.995 {
            return "Downloading \(Self.percentString(for: progress))"
        }
        return "Installing…"
    }

    @ViewBuilder
    private func mobileCLIPStateLabel(installed: Bool, assetAvailable: Bool) -> some View {
        if mobileCLIPIsRemoving {
            Label("Removing…", systemImage: "trash")
                .font(.footnote)
                .foregroundColor(.secondary)
        } else if installed {
            Label("Installed", systemImage: "checkmark.circle.fill")
                .font(.footnote)
                .foregroundColor(.secondary)
        } else if let progress = mobileCLIPDownloadProgress, mobileCLIPActionInFlight {
            if progress < 0.995 {
                Label("Downloading \(Self.percentString(for: progress))", systemImage: "arrow.down.circle.fill")
                    .font(.footnote)
                    .foregroundColor(.secondary)
            } else {
                Label("Installing…", systemImage: "shippingbox.fill")
                    .font(.footnote)
                    .foregroundColor(.secondary)
            }
        } else if !assetAvailable {
            Label("Not published in the latest release", systemImage: "xmark.circle.fill")
                .font(.footnote)
                .foregroundColor(.secondary)
        } else {
            Label("Not installed", systemImage: "arrow.down.circle")
                .font(.footnote)
                .foregroundColor(.secondary)
        }
    }

    private func mobileCLIPStatusDetailText(asset: MobileCLIPReleaseAsset?) -> String {
        if mobileCLIPIsRemoving {
            return "Removing the installed model files from Application Support…"
        }

        if let asset, let progress = mobileCLIPDownloadProgress, mobileCLIPActionInFlight {
            if progress < 0.995 {
                let downloadedBytes = Int64(Double(asset.byteCount) * progress)
                return "Downloading \(Self.percentString(for: progress)) (\(Self.byteCountFormatter.string(fromByteCount: downloadedBytes)) of \(Self.byteCountFormatter.string(fromByteCount: asset.byteCount)))"
            }
            return "Verifying and installing model files…"
        }

        if let asset {
            return "Download: \(Self.byteCountFormatter.string(fromByteCount: asset.byteCount))"
        }

        return "This model will appear here after its zip is published in the linked release feed."
    }

    private func loadOllamaModelsIfNeeded() {
        guard availableOllamaModels.isEmpty, !loadingModels else { return }
        loadingModels = true
        DispatchQueue.global(qos: .userInitiated).async {
            let models = OllamaEmbeddingProvider.listModels()
            DispatchQueue.main.async {
                availableOllamaModels = models.isEmpty ? ["snowflake-arctic-embed:33m"] : models
                loadingModels = false
            }
        }
    }

    private func installOllamaModel() {
        isInstallingModel = true
        installError = nil

        let model = settings.embeddingModel.isEmpty ? "snowflake-arctic-embed:33m" : settings.embeddingModel
        OllamaEmbeddingProvider.pullModel(model) { success, error in
            DispatchQueue.main.async {
                isInstallingModel = false
                if success {
                    refreshModelInstallState()
                } else {
                    installError = error ?? "Failed to install model"
                }
            }
        }
    }

    private func ensureValidModelSelectionForProvider() {
        switch settings.embeddingProvider {
        case "mobileclip2":
            if MobileCLIPModelCatalog.Model(rawValue: settings.embeddingModel) == nil {
                settings.embeddingModel = MobileCLIPModelCatalog.Model.s0.rawValue
            }
        case "ollama":
            if settings.embeddingModel.isEmpty || MobileCLIPModelCatalog.Model(rawValue: settings.embeddingModel) != nil {
                settings.embeddingModel = "snowflake-arctic-embed:33m"
            }
        default:
            break
        }
    }

    private func refreshMobileCLIPReleaseIfNeeded(force: Bool = false) {
        guard !loadingMobileCLIPRelease else { return }
        if mobileCLIPRelease != nil, !force { return }
        loadingMobileCLIPRelease = true
        mobileCLIPError = nil
        Task {
            do {
                let release = try await MobileCLIPReleaseService.fetchLatestRelease()
                await MainActor.run {
                    mobileCLIPRelease = release
                    loadingMobileCLIPRelease = false
                }
            } catch {
                await MainActor.run {
                    loadingMobileCLIPRelease = false
                    mobileCLIPError = error.localizedDescription
                }
            }
        }
    }

    private func installSelectedMobileCLIPModel() {
        guard let model = selectedMobileCLIPModel, !mobileCLIPActionInFlight else { return }
        mobileCLIPActionInFlight = true
        mobileCLIPIsRemoving = false
        mobileCLIPDownloadProgress = 0
        mobileCLIPError = nil

        Task {
            do {
                let release = try await MobileCLIPInstaller.install(model: model) { fraction in
                    Task { @MainActor in
                        mobileCLIPDownloadProgress = fraction
                    }
                }
                await MainActor.run {
                    mobileCLIPRelease = release
                    mobileCLIPActionInFlight = false
                    mobileCLIPDownloadProgress = nil
                    MobileCLIP2EmbeddingProvider.invalidate(modelName: model.rawValue)
                    EmbeddingService.shared.reloadFromSettings()
                }
            } catch {
                await MainActor.run {
                    mobileCLIPActionInFlight = false
                    mobileCLIPDownloadProgress = nil
                    mobileCLIPError = error.localizedDescription
                }
            }
        }
    }

    private func removeSelectedMobileCLIPModel() {
        guard let model = selectedMobileCLIPModel, !mobileCLIPActionInFlight else { return }
        mobileCLIPActionInFlight = true
        mobileCLIPIsRemoving = true
        mobileCLIPDownloadProgress = nil
        mobileCLIPError = nil
        DispatchQueue.global(qos: .utility).async {
            do {
                try MobileCLIPInstaller.remove(model: model)
                DispatchQueue.main.async {
                    mobileCLIPActionInFlight = false
                    mobileCLIPIsRemoving = false
                    MobileCLIP2EmbeddingProvider.invalidate(modelName: model.rawValue)
                    EmbeddingService.shared.reloadFromSettings()
                }
            } catch {
                DispatchQueue.main.async {
                    mobileCLIPActionInFlight = false
                    mobileCLIPIsRemoving = false
                    mobileCLIPError = error.localizedDescription
                }
            }
        }
    }

    private func refreshModelInstallState() {
        guard settings.embeddingProvider == "ollama", !settings.embeddingModel.isEmpty else {
            checkingModelInstall = false
            modelInstalled = false
            return
        }
        let model = settings.embeddingModel
        checkingModelInstall = true
        DispatchQueue.global(qos: .userInitiated).async {
            let installed = OllamaEmbeddingProvider.isModelInstalled(model)
            DispatchQueue.main.async {
                modelInstalled = (settings.embeddingModel == model) ? installed : modelInstalled
                checkingModelInstall = false
            }
        }
    }
}

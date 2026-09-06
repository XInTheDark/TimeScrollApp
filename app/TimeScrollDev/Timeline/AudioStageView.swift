import SwiftUI
import AppKit

struct AudioStageView: View {
    @ObservedObject var model: TimelineModel
    @StateObject private var playback = AudioPlaybackController()

    @State private var asset: AudioAssetRecord?
    @State private var isLoading = false
    @State private var loadToken = 0
    @State private var showTranscript = false
    @State private var isRetryingTranscription = false
    @State private var retryMessage: String?

    var body: some View {
        Group {
            if let meta = model.selected, meta.captureKind == .audio {
                content(for: meta)
                    .onAppear { loadAssetIfNeeded() }
                    .onChange(of: model.selected?.id) { _, _ in loadAssetIfNeeded() }
            } else {
                Text("No audio selected")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onDisappear {
            playback.stop()
            model.playbackTimeMs = nil
        }
        .onReceive(playback.$currentTime) { currentTime in
            syncPlaybackIndicator(currentTimeSeconds: currentTime)
        }
        .onReceive(playback.$isPlaying) { isPlaying in
            if !isPlaying {
                model.playbackTimeMs = nil
            }
        }
    }

    @ViewBuilder
    private func content(for meta: SnapshotMeta) -> some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color.accentColor.opacity(0.12),
                    Color.accentColor.opacity(0.03),
                    Color.clear
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            VStack(spacing: 28) {
                Spacer(minLength: 12)

                audioHeroCard(for: meta)
                    .frame(maxWidth: 560)

                Spacer(minLength: 12)
            }

            if let path = asset?.path ?? model.selected?.path {
                VStack {
                    HStack {
                        Spacer()

                        TimelineStripVisibilityButton()

                        Button {
                            SnapshotActions.revealInFinder(URL(fileURLWithPath: path))
                        } label: {
                            Label("Reveal", systemImage: "folder")
                        }
                        .buttonStyle(.bordered)
                    }
                    Spacer()
                }
                .padding(18)
            }

            AudioFloatingOverlay(
                model: model,
                playback: playback,
                assetDurationSeconds: assetDurationSeconds,
                canPlay: asset != nil || model.selected != nil,
                onShowTranscript: { showTranscript = true }
            )

            if isLoading {
                VStack(spacing: 8) {
                    ProgressView()
                        .progressViewStyle(.circular)
                    Text("Loading audio…")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .padding(14)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .padding(.top, 18)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .sheet(isPresented: $showTranscript) {
            AudioTranscriptSheet(
                meta: meta,
                asset: asset,
                isLoading: isLoading,
                playback: playback,
                assetDurationSeconds: assetDurationSeconds,
                transcriptText: transcriptText,
                isRetrying: isRetryingTranscription,
                retryMessage: retryMessage,
                onRetry: retryTranscription
            )
        }
    }

    private func audioHeroCard(for meta: SnapshotMeta) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .center, spacing: 16) {
                ZStack {
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .fill(Color.accentColor.opacity(0.12))
                    Image(systemName: meta.audioSourceKind?.systemImage ?? CaptureKind.audio.systemImage)
                        .font(.system(size: 34, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                }
                .frame(width: 92, height: 92)

                VStack(alignment: .leading, spacing: 6) {
                    Text(meta.appName ?? meta.audioSourceKind?.displayName ?? "Audio")
                        .font(.title2.weight(.semibold))
                    Text(dateString(ms: meta.startedAtMs))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                    HStack(spacing: 8) {
                        AudioMetaTag(title: meta.captureKind.displayName, systemImage: meta.captureKind.systemImage)
                        if let source = meta.audioSourceKind {
                            AudioMetaTag(title: source.displayName, systemImage: source.systemImage)
                        }
                        if let duration = meta.audioDurationMs {
                            AudioMetaTag(title: durationString(ms: duration), systemImage: "clock")
                        }
                    }
                }

                Spacer(minLength: 0)
            }

            AudioWaveformDecoration()
                .frame(height: 54)

            if asset?.transcriptionStatus == .pending || isRetryingTranscription {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Transcribing recording…")
                        .foregroundStyle(.secondary)
                }
            } else if asset?.transcriptionStatus == .failed {
                VStack(alignment: .leading, spacing: 8) {
                    Label("Transcription failed", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                    Text(asset?.transcriptionError ?? retryMessage ?? "The recording was kept and can be retried.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Button("Retry Transcription", action: retryTranscription)
                        .buttonStyle(.bordered)
                }
            } else if let transcriptText {
                Text(transcriptText)
                    .font(.body)
                    .foregroundStyle(.primary)
                    .lineLimit(3)
            } else if isLoading {
                Text("Preparing the recording and transcript…")
                    .font(.body)
                    .foregroundStyle(.secondary)
            } else {
                Text("Open Transcript to follow the recording with synced timestamps.")
                    .font(.body)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(24)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .stroke(Color.primary.opacity(0.06), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.08), radius: 18, x: 0, y: 10)
    }

    private var transcriptText: String? {
        let joined = asset?.transcriptSegments
            .map(\.text)
            .joined(separator: " ") ?? ""
        let trimmed = joined.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private var assetDurationSeconds: Double {
        Double(asset?.durationMs ?? model.selected?.audioDurationMs ?? 0) / 1000
    }

    private func loadAssetIfNeeded() {
        guard let selected = model.selected, selected.captureKind == .audio else {
            asset = nil
            showTranscript = false
            playback.stop()
            model.playbackTimeMs = nil
            return
        }

        loadToken &+= 1
        let token = loadToken
        isLoading = true

        DispatchQueue.global(qos: .userInitiated).async {
            let asset = try? DB.shared.audioAsset(forSnapshotId: selected.id)
            DispatchQueue.main.async {
                guard token == loadToken else { return }
                self.asset = asset
                self.isLoading = false

                let path = asset?.path ?? selected.path
                playback.load(url: URL(fileURLWithPath: path))
            }
        }
    }

    private func retryTranscription() {
        guard let asset, !isRetryingTranscription else { return }
        let requestedModel = UserDefaults.standard.string(forKey: "settings.whisperModelID")?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let modelID = requestedModel?.isEmpty == false ? requestedModel! : SettingsStore.defaultWhisperModelID
        isRetryingTranscription = true
        retryMessage = nil
        Task {
            do {
                try await AudioSegmentProcessor.shared.retry(assetID: asset.id, modelID: modelID)
                await AudioSegmentProcessor.shared.drain()
            } catch {
                retryMessage = error.localizedDescription
            }
            isRetryingTranscription = false
            loadAssetIfNeeded()
        }
    }

    private func syncPlaybackIndicator(currentTimeSeconds: TimeInterval) {
        guard playback.isPlaying,
              let selected = model.selected,
              selected.captureKind == .audio else {
            return
        }
        model.playbackTimeMs = selected.startedAtMs + Int64((currentTimeSeconds * 1000).rounded())
    }

    private func dateString(ms: Int64) -> String {
        Self.dateFormatter.string(from: Date(timeIntervalSince1970: TimeInterval(ms) / 1000))
    }

    private func durationString(ms: Int64) -> String {
        let totalSeconds = max(0, Int(ms / 1000))
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()
}

private struct AudioFloatingOverlay: View {
    @ObservedObject var model: TimelineModel
    @ObservedObject var playback: AudioPlaybackController
    let assetDurationSeconds: Double
    let canPlay: Bool
    let onShowTranscript: () -> Void

    @State private var dragStartX: Double = 0
    @State private var dragStartY: Double = 0

    var body: some View {
        HStack(spacing: 12) {
            navigationPill
            audioControlsPill
        }
        .shadow(color: .black.opacity(0.22), radius: 6, x: 0, y: 2)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        .offset(x: model.overlayOffsetX, y: model.overlayOffsetY)
        .fixedSize()
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    if dragStartX == 0 && dragStartY == 0 {
                        dragStartX = model.overlayOffsetX
                        dragStartY = model.overlayOffsetY
                    }
                    model.overlayOffsetX = dragStartX + Double(value.translation.width)
                    model.overlayOffsetY = dragStartY + Double(value.translation.height)
                }
                .onEnded { _ in
                    dragStartX = 0
                    dragStartY = 0
                }
        )
    }

    private var pillBackground: Color {
        Color.black.opacity(0.48)
    }

    private var navigationPill: some View {
        HStack(spacing: 12) {
            Button(action: { model.prev() }) {
                Image(systemName: "chevron.left.circle.fill")
                    .font(.system(size: 28))
                    .foregroundColor(.white.opacity(model.selectedIndex + 1 < model.metas.count ? 0.95 : 0.35))
            }
            .buttonStyle(.plain)
            .disabled(!(model.selectedIndex + 1 < model.metas.count))

            Text(model.selected.map { Self.dateFormatter.string(from: Date(timeIntervalSince1970: TimeInterval($0.startedAtMs) / 1000)) } ?? "")
                .font(.system(size: 16, weight: .medium, design: .monospaced))
                .foregroundColor(.white)

            Button(action: { model.next() }) {
                Image(systemName: "chevron.right.circle.fill")
                    .font(.system(size: 28))
                    .foregroundColor(.white.opacity(model.selectedIndex - 1 >= 0 ? 0.95 : 0.35))
            }
            .buttonStyle(.plain)
            .disabled(!(model.selectedIndex - 1 >= 0))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(pillBackground)
        .clipShape(Capsule(style: .continuous))
    }

    private var audioControlsPill: some View {
        HStack(spacing: 10) {
            Button {
                playback.togglePlayback()
            } label: {
                Image(systemName: playback.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 34, height: 34)
                    .background(Color.white.opacity(0.08), in: Circle())
            }
            .buttonStyle(.plain)
            .disabled(!canPlay)

            Rectangle()
                .fill(Color.white.opacity(0.14))
                .frame(width: 1, height: 20)

            Button(action: onShowTranscript) {
                HStack(spacing: 8) {
                    Image(systemName: "quote.bubble")
                    Text("Transcript")
                    Text(Self.timecode(playback.currentTime))
                        .monospacedDigit()
                        .foregroundStyle(.white.opacity(0.8))
                    Text("/")
                        .foregroundStyle(.white.opacity(0.5))
                    Text(Self.timecode(max(playback.duration, assetDurationSeconds)))
                        .monospacedDigit()
                        .foregroundStyle(.white.opacity(0.8))
                }
                .foregroundStyle(.white)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(pillBackground, in: Capsule(style: .continuous))
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .medium
        return formatter
    }()

    private static func timecode(_ seconds: TimeInterval) -> String {
        let totalSeconds = max(0, Int(seconds.rounded(.towardZero)))
        let minutes = totalSeconds / 60
        let secs = totalSeconds % 60
        return String(format: "%02d:%02d", minutes, secs)
    }
}

struct AudioTranscriptSheet: View {
    let meta: SnapshotMeta
    let asset: AudioAssetRecord?
    let isLoading: Bool
    @ObservedObject var playback: AudioPlaybackController
    let assetDurationSeconds: Double
    let transcriptText: String?
    let isRetrying: Bool
    let retryMessage: String?
    let onRetry: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            transportBar
            Divider()
            transcriptBody
        }
        .frame(minWidth: 560, minHeight: 520)
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(meta.appName ?? meta.audioSourceKind?.displayName ?? "Audio")
                    .font(.title3.weight(.semibold))
                Text(Self.dateFormatter.string(from: Date(timeIntervalSince1970: TimeInterval(meta.startedAtMs) / 1000)))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if let transcriptText {
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(transcriptText, forType: .string)
                } label: {
                    Label("Copy Transcript", systemImage: "doc.on.doc")
                }
                .buttonStyle(.bordered)
            }

            Button {
                SnapshotActions.revealInFinder(URL(fileURLWithPath: asset?.path ?? meta.path))
            } label: {
                Label("Reveal", systemImage: "folder")
            }
            .buttonStyle(.bordered)
        }
        .padding(20)
    }

    private var transportBar: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Button {
                    playback.togglePlayback()
                } label: {
                    Label(playback.isPlaying ? "Pause" : "Play",
                          systemImage: playback.isPlaying ? "pause.fill" : "play.fill")
                }
                .buttonStyle(.borderedProminent)
                .disabled(asset == nil && !isLoading)

                Text(Self.timecode(playback.currentTime))
                    .monospacedDigit()
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                Slider(
                    value: Binding(
                        get: { playback.duration > 0 ? playback.currentTime : 0 },
                        set: { playback.seek(to: $0) }
                    ),
                    in: 0...max(playback.duration, assetDurationSeconds)
                )
                .disabled(max(playback.duration, assetDurationSeconds) <= 0)

                Text(Self.timecode(max(playback.duration, assetDurationSeconds)))
                    .monospacedDigit()
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Text("The transcript follows playback and auto-scrolls to the active timestamp.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding(20)
    }

    @ViewBuilder
    private var transcriptBody: some View {
        if let asset {
            if asset.transcriptionStatus == .pending || isRetrying {
                VStack(spacing: 10) {
                    ProgressView()
                    Text("Transcribing recording…")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if asset.transcriptSegments.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "text.bubble")
                        .font(.system(size: 28))
                        .foregroundStyle(.secondary)
                    Text(asset.transcriptionStatus == .failed ? "Transcription failed" : "No speech detected")
                        .font(.headline)
                    Text(asset.transcriptionError ?? retryMessage ?? "The recording does not contain any transcript segments.")
                        .foregroundStyle(.secondary)
                    if asset.transcriptionStatus == .failed {
                        Button(isRetrying ? "Retrying…" : "Retry Transcription", action: onRetry)
                            .buttonStyle(.borderedProminent)
                            .disabled(isRetrying)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 10) {
                            ForEach(asset.transcriptSegments) { segment in
                                Button {
                                    playback.seek(to: TimeInterval(segment.relativeStartMs) / 1000)
                                } label: {
                                    HStack(alignment: .top, spacing: 12) {
                                        Text(Self.timecode(TimeInterval(segment.relativeStartMs) / 1000))
                                            .font(.caption.monospacedDigit())
                                            .foregroundStyle(.secondary)
                                            .frame(width: 64, alignment: .leading)

                                        Text(segment.text)
                                            .font(.body)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                    }
                                    .padding(14)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .background(transcriptRowBackground(for: segment), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                                }
                                .buttonStyle(.plain)
                                .id(segment.id)
                            }
                        }
                        .padding(20)
                    }
                    .onAppear {
                        scrollToActiveSegment(using: proxy)
                    }
                    .onChange(of: activeSegmentID) { _, _ in
                        scrollToActiveSegment(using: proxy)
                    }
                }
            }
        } else if isLoading {
            VStack(spacing: 10) {
                ProgressView()
                Text("Loading transcript…")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            Text("Unable to load the selected recording.")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var activeSegmentID: Int? {
        guard let asset else { return nil }
        let currentMs = Int64((playback.currentTime * 1000).rounded())
        return asset.transcriptSegments.first(where: { segment in
            currentMs >= segment.relativeStartMs && currentMs <= segment.relativeEndMs
        })?.id
    }

    private func transcriptRowBackground(for segment: AudioTranscriptSegment) -> Color {
        activeSegmentID == segment.id
            ? Color.accentColor.opacity(0.14)
            : Color(nsColor: .controlBackgroundColor)
    }

    private func scrollToActiveSegment(using proxy: ScrollViewProxy) {
        guard let activeSegmentID else { return }
        withAnimation(.easeInOut(duration: 0.18)) {
            proxy.scrollTo(activeSegmentID, anchor: .center)
        }
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    private static func timecode(_ seconds: TimeInterval) -> String {
        let totalSeconds = max(0, Int(seconds.rounded(.towardZero)))
        let minutes = totalSeconds / 60
        let secs = totalSeconds % 60
        return String(format: "%02d:%02d", minutes, secs)
    }
}

private struct AudioMetaTag: View {
    let title: String
    let systemImage: String

    var body: some View {
        Label(title, systemImage: systemImage)
            .font(.caption.weight(.medium))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color(nsColor: .controlBackgroundColor), in: Capsule(style: .continuous))
    }
}

private struct AudioWaveformDecoration: View {
    var body: some View {
        GeometryReader { geometry in
            let barCount = max(12, Int(geometry.size.width / 10))
            HStack(alignment: .center, spacing: 4) {
                ForEach(0..<barCount, id: \.self) { index in
                    Capsule(style: .continuous)
                        .fill(index.isMultiple(of: 3) ? Color.accentColor.opacity(0.85) : Color.accentColor.opacity(0.45))
                        .frame(width: 4, height: barHeight(for: index, maxHeight: geometry.size.height))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        }
    }

    private func barHeight(for index: Int, maxHeight: CGFloat) -> CGFloat {
        let normalized = (sin(Double(index) * 0.72) + cos(Double(index) * 0.33) + 2) / 4
        return max(10, maxHeight * CGFloat(0.24 + normalized * 0.76))
    }
}

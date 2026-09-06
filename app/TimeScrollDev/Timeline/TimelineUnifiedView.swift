import SwiftUI
import AppKit

struct TimelineUnifiedView: View {
    @ObservedObject var appState = AppState.shared
    @StateObject var model = TimelineModel()
    @StateObject private var liveRefresh = TimelineLiveRefreshScheduler()
    @EnvironmentObject var settings: SettingsStore
    @ObservedObject var vault = VaultManager.shared
    @AppStorage("ui.timeline.compressed") private var compressedTimeline: Bool = true
    @AppStorage("ui.timeline.invertScrollDirection") private var invertTimelineScrollDirection: Bool = false
    @AppStorage("ui.timeline.showScreenStrips") private var showScreenTimelineStrips: Bool = true
    @AppStorage("ui.timeline.showAudioStrips") private var showAudioTimelineStrips: Bool = true
    @AppStorage("ui.timeline.height") private var storedTimelineHeight: Double = 116

    @State private var query: String = ""
    @State private var showFilters: Bool = false
    @State private var startDate: Date? = nil
    @State private var endDate: Date? = nil
    @State private var keyMonitor: Any? = nil
    @State private var showingResults: Bool = false
    @State private var preserveOpenedResultContextOnRefresh: Bool = false
    @State private var showCaptureModePopover: Bool = false
    @State private var timelineResizeStartHeight: Double?

    private let minMsPerPt: Double = 100             // 100ms per pt at max zoom-in
    private let maxMsPerPt: Double = 300_000         // 5m per pt at max zoom-out (keeps things "pretty small")
    private let zoomStep: Double = 1.25

    private var activeFilterCount: Int {
        (model.startMs != nil ? 1 : 0)
        + (model.endMs != nil ? 1 : 0)
        + (model.selectedAppBundleIds.isEmpty ? 0 : 1)
        + (model.selectedCaptureKinds.isEmpty ? 0 : 1)
        + (model.selectedAudioSourceKinds.isEmpty ? 0 : 1)
    }

    private var visibleTimelineCaptureKinds: Set<CaptureKind> {
        var visible: Set<CaptureKind> = []
        if showScreenTimelineStrips {
            visible.insert(.screen)
        }
        if settings.audioFeatureEnabled && showAudioTimelineStrips {
            visible.insert(.audio)
        }
        return visible.isEmpty ? [.screen] : visible
    }

    private var bottomTimelineHeight: CGFloat {
        CGFloat(clampedTimelineHeight)
    }

    private var isAudioCaptureModeEnabled: Bool {
        settings.audioFeatureEnabled && settings.captureAudioEnabled
    }

    private var isWhisperModelInstalled: Bool {
        WhisperModelStore.isModelAvailable(settings.whisperModelID)
    }

    private var clampedTimelineHeight: Double {
        min(280, max(92, storedTimelineHeight))
    }

    private var timelineCanvasHeight: CGFloat {
        max(72, bottomTimelineHeight - 14)
    }

    var body: some View {
        VStack(spacing: 0) {
            topBar
            Divider()
            centerStage
            Divider()
            bottomTimeline
        }
        .onAppear {
            _ = SnapshotStore.shared.snapshotsDir
            appState.enforceRetention()
            model.load()
            installKeyMonitor()
            // Keep the text field in sync with the applied model query
            query = model.query
            // Clamp any previously persisted msPerPoint into the new, saner range
            model.msPerPoint = min(max(model.msPerPoint, minMsPerPt), maxMsPerPt)
        }
        .onDisappear { removeKeyMonitor() }
        .onChange(of: vault.isUnlocked) { _, unlocked in
            // When the vault gets unlocked, reload timeline and show a loading state
            if unlocked { model.load() }
        }
        .onChange(of: appState.lastSnapshotTick) { _, _ in
            liveRefresh.notify()
        }
        .background(TimelineRefreshObserver(scheduler: liveRefresh,
            refresh: { reloadTimelineKeepingSelection() },
            isReady: { !model.isLoading },
            isEnabled: { settings.refreshOnNewSnapshot && (!settings.vaultEnabled || vault.isUnlocked) })
            .frame(width: 0, height: 0))
        // If the user clears the search field, automatically return to timeline
        .onChange(of: query) { _, newVal in
            let trimmed = newVal.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty && showingResults {
                // Clear applied query on the model and reload latest
                preserveOpenedResultContextOnRefresh = false
                model.query = ""
                model.load()
                showingResults = false
            }
        }
        // Keep text field reflecting the currently applied model query (e.g. after programmatic changes)
        .onChange(of: model.query) { _, newVal in
            if query != newVal { query = newVal }
        }
        .onChange(of: showScreenTimelineStrips) { _, _ in
            ensureSelectionMatchesVisibleTimelineTracks()
        }
        .onChange(of: showAudioTimelineStrips) { _, _ in
            ensureSelectionMatchesVisibleTimelineTracks()
        }
        .onChange(of: settings.audioFeatureEnabled) { _, _ in
            ensureSelectionMatchesVisibleTimelineTracks()
        }
        .frame(minWidth: 1000, minHeight: 700)
    }

    @MainActor
    private func reloadTimelineKeepingSelection() {
        if preserveOpenedResultContextOnRefresh,
           !showingResults,
           let selected = model.selected {
            model.openSnapshot(id: selected.id, anchorStartedAtMs: selected.startedAtMs)
            return
        }

        model.load()
        if model.followLatest {
            model.jumpToEndToken &+= 1
        }
    }

    @State private var debugOpen: Bool = false

    private var captureButtonGroup: some View {
        HStack(spacing: 0) {
            Button {
                toggleCapture()
            } label: {
                Label((appState.isCapturing || appState.isCaptureStarting) ? "Stop Capture" : "Start Capture",
                      systemImage: (appState.isCapturing || appState.isCaptureStarting) ? "stop.circle.fill" : "record.circle.fill")
            }
            .buttonStyle(.borderedProminent)
            .tint((appState.isCapturing || appState.isCaptureStarting) ? .red : .accentColor)
            .controlSize(.large)

            if settings.audioFeatureEnabled {
                Button {
                    showCaptureModePopover.toggle()
                } label: {
                    Image(systemName: "chevron.down")
                        .font(.subheadline.weight(.semibold))
                        .frame(width: 24)
                }
                .buttonStyle(.borderedProminent)
                .tint((appState.isCapturing || appState.isCaptureStarting) ? .red : .accentColor)
                .controlSize(.large)
                .popover(isPresented: $showCaptureModePopover, arrowEdge: .bottom) {
                    captureModePopover
                        .padding(12)
                        .frame(width: 250)
                }
            }
        }
    }

    private var topBar: some View {
        HStack(spacing: 12) {
            captureButtonGroup

            TimelineToolbarSection {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)

                TextField("Search snapshots", text: $query)
                    .textFieldStyle(.plain)
                    .frame(maxWidth: .infinity)
                    .submitLabel(.search)
                    .onSubmit { showResults() }

                Divider().frame(height: 22)

                Button {
                    showFilters.toggle()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: activeFilterCount > 0 ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
                        Text("Filters")
                        if activeFilterCount > 0 {
                            TimelineToolbarCountBadge(count: activeFilterCount)
                        }
                    }
                }
                .buttonStyle(.bordered)
                .popover(isPresented: $showFilters, arrowEdge: .bottom) {
                    filtersPopover
                        .padding(12)
                        .frame(minWidth: 400)
                }

                Menu {
                    Button("Show Results") { showResults() }
                    Button("Search & Jump") { searchAndJump() }
                        .keyboardShortcut(.return, modifiers: [.command])
                } label: {
                    Text(showingResults ? "Refresh" : "Search")
                } primaryAction: {
                    showResults()
                }
                .menuStyle(.borderedButton)
                .fixedSize(horizontal: true, vertical: false)
            }
            .frame(maxWidth: .infinity)

            if settings.vaultEnabled {
                TimelineToolbarSection {
                    if vault.queuedCount > 0 {
                        Label("Queued \(vault.queuedCount)", systemImage: "tray.and.arrow.down.fill")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.secondary)
                    }

                    Button(vault.isUnlocked ? "Lock" : "Unlock…") {
                        if vault.isUnlocked {
                            Task { await vault.lock() }
                        } else {
                            Task { await vault.unlock(presentingWindow: NSApp.keyWindow) }
                        }
                    }
                    .buttonStyle(.bordered)
                }
            }

            TimelineToolbarSection {
                Button(action: { model.msPerPoint = min(maxMsPerPt, model.msPerPoint * zoomStep) }) {
                    Image(systemName: "minus")
                }
                .buttonStyle(.bordered)

                Slider(value: Binding(get: {
                    let clamped = min(max(model.msPerPoint, minMsPerPt), maxMsPerPt)
                    let logMin = log(minMsPerPt)
                    let logMax = log(maxMsPerPt)
                    let logVal = log(clamped)
                    return (logMax - logVal) / (logMax - logMin)
                }, set: { value in
                    let logMin = log(minMsPerPt)
                    let logMax = log(maxMsPerPt)
                    let logVal = logMax - value * (logMax - logMin)
                    let msPerPoint = exp(logVal)
                    model.msPerPoint = min(max(msPerPoint, minMsPerPt), maxMsPerPt)
                }))
                .frame(width: 140)

                Button(action: { model.msPerPoint = max(minMsPerPt, model.msPerPoint / zoomStep) }) {
                    Image(systemName: "plus")
                }
                .buttonStyle(.bordered)

                Divider().frame(height: 22)

                TimelineLiveToggle(isOn: $model.followLatest)
            }
            .fixedSize(horizontal: true, vertical: false)

            if settings.debugMode {
                Button("Debug DB") { debugOpen = true }
                    .buttonStyle(.bordered)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .sheet(isPresented: $debugOpen) { DebugView() }
    }

    private var captureModePopover: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Capture Modes")
                .font(.headline)

            Toggle("Screen", isOn: captureModeBinding(kind: .screen))
                .toggleStyle(.checkbox)

            Toggle("Audio", isOn: captureModeBinding(kind: .audio))
                .toggleStyle(.checkbox)

            if isAudioCaptureModeEnabled && !isWhisperModelInstalled {
                Label("Download the selected Whisper model in Preferences before audio capture can start.",
                      systemImage: "exclamationmark.triangle")
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }

            if let error = appState.screenCaptureStatus.errorMessage {
                Label("Screen: \(error)", systemImage: "exclamationmark.triangle")
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }

            if let error = appState.microphoneCaptureStatus.errorMessage {
                Label("Microphone: \(error)", systemImage: "exclamationmark.triangle")
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }

            if let error = appState.systemAudioCaptureStatus.errorMessage {
                Label("System audio: \(error)", systemImage: "exclamationmark.triangle")
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }

            if appState.microphoneCaptureStatus == .pausedForVault
                || appState.systemAudioCaptureStatus == .pausedForVault {
                Label("Audio is paused while the vault is locked.", systemImage: "lock")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Text("Audio uses the microphone and system-audio sources you’ve enabled in Preferences → Audio.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private var filtersPopover: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Text("From:")
                DatePicker("From", selection: Binding(get: { startDate ?? Date() }, set: { startDate = $0 }), displayedComponents: [.date, .hourAndMinute])
                    .labelsHidden()
            }
            HStack(spacing: 8) {
                Text("To:")
                DatePicker("To", selection: Binding(get: { endDate ?? Date() }, set: { endDate = $0 }), displayedComponents: [.date, .hourAndMinute])
                    .labelsHidden()
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("Apps:")
                TimelineAppMultiFilter(selected: $model.selectedAppBundleIds)
                    .frame(minHeight: 140, maxHeight: 220)
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("Media:")
                HStack(spacing: 16) {
                    Toggle("Screen", isOn: Binding(
                        get: { model.selectedCaptureKinds.contains(.screen) },
                        set: { enabled in
                            if enabled { model.selectedCaptureKinds.insert(.screen) }
                            else { model.selectedCaptureKinds.remove(.screen) }
                        }
                    ))
                    .toggleStyle(.checkbox)

                    Toggle("Audio", isOn: Binding(
                        get: { model.selectedCaptureKinds.contains(.audio) },
                        set: { enabled in
                            if enabled { model.selectedCaptureKinds.insert(.audio) }
                            else {
                                model.selectedCaptureKinds.remove(.audio)
                                model.selectedAudioSourceKinds.removeAll()
                            }
                        }
                    ))
                    .toggleStyle(.checkbox)
                }

                if model.selectedCaptureKinds.contains(.audio) || !model.selectedAudioSourceKinds.isEmpty {
                    HStack(spacing: 16) {
                        Toggle("Microphone", isOn: Binding(
                            get: { model.selectedAudioSourceKinds.contains(.microphone) },
                            set: { enabled in
                                if enabled { model.selectedAudioSourceKinds.insert(.microphone) }
                                else { model.selectedAudioSourceKinds.remove(.microphone) }
                            }
                        ))
                        .toggleStyle(.checkbox)

                        Toggle("System Audio", isOn: Binding(
                            get: { model.selectedAudioSourceKinds.contains(.system) },
                            set: { enabled in
                                if enabled { model.selectedAudioSourceKinds.insert(.system) }
                                else { model.selectedAudioSourceKinds.remove(.system) }
                            }
                        ))
                        .toggleStyle(.checkbox)
                    }
                    .padding(.leading, 14)
                }
            }
            Divider()
            HStack {
                Button("Clear Dates") {
                    startDate = nil
                    endDate = nil
                }
                Button("Clear Apps") {
                    model.selectedAppBundleIds.removeAll()
                }
                Button("Clear Media") {
                    model.selectedCaptureKinds.removeAll()
                    model.selectedAudioSourceKinds.removeAll()
                }
                Spacer()
                Button("Done") { showFilters = false }
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    private var centerStage: some View {
        ZStack {
            if settings.vaultEnabled && !vault.isUnlocked {
                LockedView()
            } else {
            // Use the applied model.query (not the in-flight text field value)
            Group {
                if showingResults {
                    SearchResultsView(query: model.query,
                                      appBundleIds: (model.selectedAppBundleIds.isEmpty ? nil : Array(model.selectedAppBundleIds).sorted()),
                                      startMs: model.startMs,
                                      endMs: model.endMs,
                                      captureKinds: (model.selectedCaptureKinds.isEmpty ? nil : Array(model.selectedCaptureKinds).sorted { $0.rawValue < $1.rawValue }),
                                      audioSourceKinds: (model.selectedAudioSourceKinds.isEmpty ? nil : Array(model.selectedAudioSourceKinds).sorted { $0.rawValue < $1.rawValue }),
                                      onOpen: { row, _ in
                                          preserveOpenedResultContextOnRefresh = true
                                          showingResults = false
                                          model.openSnapshot(id: row.id, anchorStartedAtMs: row.startedAtMs)
                                      },
                                      onClose: {
                                          preserveOpenedResultContextOnRefresh = false
                                          model.load()
                                          showingResults = false
                                      })
                        // Remount the results view when filters change to avoid stale local state
                        .id("\(model.query)|\(((model.selectedAppBundleIds.isEmpty ? ["_"] : Array(model.selectedAppBundleIds)).sorted().joined(separator: ",")))|\(((model.selectedCaptureKinds.isEmpty ? ["all"] : model.selectedCaptureKinds.map(\.rawValue)).sorted().joined(separator: ",")))|\(((model.selectedAudioSourceKinds.isEmpty ? ["all"] : model.selectedAudioSourceKinds.map(\.rawValue)).sorted().joined(separator: ",")))|\(model.startMs ?? -1)|\(model.endMs ?? -1)")
                        .environmentObject(settings)
                } else {
                    CaptureStageView(model: model, globalQuery: model.query)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            // Loading overlay
            if model.isLoading {
                VStack(spacing: 8) {
                    ProgressView()
                        .progressViewStyle(.circular)
                    Text("Loading snapshots\nPlease wait…")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding(16)
                .background(.ultraThinMaterial)
                .cornerRadius(10)
            }
        }
        .frame(minHeight: 480)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var bottomTimeline: some View {
        VStack(spacing: 0) {
            TimelineResizeHandle()
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            if timelineResizeStartHeight == nil {
                                timelineResizeStartHeight = clampedTimelineHeight
                            }
                            let baseHeight = timelineResizeStartHeight ?? clampedTimelineHeight
                            storedTimelineHeight = min(280, max(92, baseHeight - value.translation.height))
                        }
                        .onEnded { _ in
                            timelineResizeStartHeight = nil
                        }
                )

            ZStack(alignment: .bottomTrailing) {
                TimelineBarContainer(model: model,
                                     isCompressed: compressedTimeline,
                                     invertScrollDirection: invertTimelineScrollDirection,
                                     visibleCaptureKinds: visibleTimelineCaptureKinds,
                                     onJump: { time, preferredCaptureKind in
                                         model.jump(to: time,
                                                    preferredCaptureKind: preferredCaptureKind,
                                                    visibleCaptureKinds: visibleTimelineCaptureKinds)
                                     },
                                     onHover: { t in model.hoverTimeMs = t },
                                     onHoverExit: { model.hoverTimeMs = nil })
                    .frame(height: timelineCanvasHeight)

                Button(action: { jumpToEnd() }) {
                    Image(systemName: "chevron.right.to.line")
                }
                .buttonStyle(.plain)
                .padding(8)
            }
        }
        .frame(height: bottomTimelineHeight)
    }

    private func applyFilters() {
        model.query = query
        model.startMs = startDate.map { Int64($0.timeIntervalSince1970 * 1000) }
        model.endMs = endDate.map { Int64($0.timeIntervalSince1970 * 1000) }
    }

    private func toggleCapture() {
        Task {
            if appState.isCapturing || appState.isCaptureStarting {
                await appState.stopCaptureIfNeeded()
            } else {
                await appState.startCaptureIfNeeded()
            }
        }
    }

    private func captureModeBinding(kind: CaptureKind) -> Binding<Bool> {
        Binding(
            get: {
                switch kind {
                case .screen:
                    return settings.captureScreenEnabled
                case .audio:
                    return isAudioCaptureModeEnabled
                }
            },
            set: { enabled in
                switch kind {
                case .screen:
                    guard enabled || isAudioCaptureModeEnabled else {
                        NSSound.beep()
                        return
                    }
                    settings.captureScreenEnabled = enabled
                case .audio:
                    guard settings.audioFeatureEnabled else { return }
                    guard enabled || settings.captureScreenEnabled else {
                        NSSound.beep()
                        return
                    }
                    settings.captureAudioEnabled = enabled
                    if enabled,
                       !settings.captureMicrophoneEnabled,
                       !settings.captureSystemAudioEnabled {
                        settings.captureMicrophoneEnabled = true
                    }
                }

                Task { @MainActor in
                    await AppState.shared.restartCaptureIfRunning()
                }
            }
        )
    }

    private func showResults() {
        preserveOpenedResultContextOnRefresh = false
        applyFilters()
        showingResults = true
        showFilters = false
    }

    private func searchAndJump() {
        preserveOpenedResultContextOnRefresh = false
        applyFilters()
        model.load()
        showingResults = false
        showFilters = false
    }

    private func installKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            // If typing in the search field (NSTextView), intercept Cmd+Return to run Search & Jump
            if let first = NSApp.keyWindow?.firstResponder, first is NSTextView {
                // keyCode 36 = Return, 76 = keypad Enter
                if (event.keyCode == 36 || event.keyCode == 76) && event.modifierFlags.contains(.command) {
                    searchAndJump()
                    return nil
                }
                return event
            }
            // Ignore other modified keypresses
            if event.modifierFlags.contains(.command) || event.modifierFlags.contains(.option) || event.modifierFlags.contains(.control) {
                return event
            }
            switch event.keyCode {
            case 123: // left
                if model.selectedIndex + 1 < model.metas.count { model.prev(); return nil }
            case 124: // right
                if model.selectedIndex - 1 >= 0 { model.next(); return nil }
            case 51, 117: // delete, forward delete
                if let sel = model.selected {
                    let alert = NSAlert()
                    alert.alertStyle = .warning
                    alert.messageText = "Delete Snapshot?"
                    alert.informativeText = "This will permanently delete the selected snapshot from disk and remove it from the timeline."
                    alert.addButton(withTitle: "Delete")
                    alert.addButton(withTitle: "Cancel")
                    if alert.runModal() == .alertFirstButtonReturn {
                        model.deleteSnapshot(id: sel.id)
                        return nil
                    }
                }
            default:
                break
            }
            return event
        }
    }

    private func removeKeyMonitor() {
        if let m = keyMonitor { NSEvent.removeMonitor(m) }
        keyMonitor = nil
    }

    private func jumpToEnd() {
        preserveOpenedResultContextOnRefresh = false
        if !model.metas.isEmpty { model.selectedIndex = 0 }
        model.jumpToEndToken &+= 1
    }

    private func ensureSelectionMatchesVisibleTimelineTracks() {
        guard let selected = model.selected else { return }
        let visibleKinds = visibleTimelineCaptureKinds
        guard !visibleKinds.contains(selected.captureKind) else { return }
        model.jump(to: selected.startedAtMs, visibleCaptureKinds: visibleKinds)
    }
}

// Single-select app filter removed; replaced by TimelineAppMultiFilter

private struct TimelineToolbarSection<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        HStack(spacing: 10) {
            content
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.72))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.primary.opacity(0.06), lineWidth: 1)
        )
    }
}

private struct TimelineToolbarCountBadge: View {
    let count: Int

    var body: some View {
        Text("\(count)")
            .font(.caption2.weight(.bold))
            .foregroundStyle(.white)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                Capsule(style: .continuous)
                    .fill(Color.accentColor)
            )
    }
}

private struct TimelineResizeHandle: View {
    @State private var hovering = false

    var body: some View {
        ZStack {
            Rectangle()
                .fill(Color.clear)
                .frame(height: 14)

            Capsule(style: .continuous)
                .fill(Color.primary.opacity(hovering ? 0.22 : 0.12))
                .frame(width: 72, height: 5)
        }
        .contentShape(Rectangle())
        .onHover { isHovering in
            hovering = isHovering
            if isHovering {
                NSCursor.resizeUpDown.push()
            } else {
                NSCursor.pop()
            }
        }
        .onDisappear {
            if hovering {
                NSCursor.pop()
                hovering = false
            }
        }
    }
}

private struct TimelineLiveToggle: View {
    @Binding var isOn: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "dot.radiowaves.left.and.right")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(isOn ? Color.accentColor : Color.secondary)
                .accessibilityHidden(true)

            Toggle("", isOn: $isOn)
                .labelsHidden()
                .toggleStyle(.switch)
        }
        .fixedSize(horizontal: true, vertical: false)
        .help("Follow newest snapshots")
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Live follow")
    }
}

private struct TimelineAppMultiFilter: View {
    @Binding var selected: Set<String>
    @State private var apps: [(bundleId: String, name: String)] = []
    @State private var filter: String = ""
    @State private var isLoadingApps: Bool = false
    @State private var loadToken: Int = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                TextField("Filter apps", text: $filter)
                    .textFieldStyle(.roundedBorder)
                Button("Clear") { selected.removeAll() }
                Button("All") { selected = Set(apps.map { $0.bundleId }) }
            }
            if isLoadingApps && apps.isEmpty {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Loading apps…")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    ForEach(filteredApps(), id: \.bundleId) { entry in
                        Toggle(isOn: Binding(get: {
                            selected.contains(entry.bundleId)
                        }, set: { val in
                            if val { selected.insert(entry.bundleId) } else { selected.remove(entry.bundleId) }
                        })) {
                            Text(entry.name)
                        }
                        .toggleStyle(.checkbox)
                    }
                }
                .padding(.vertical, 4)
            }
            .frame(minHeight: 120)
        }
        .onAppear { loadIfNeeded() }
    }

    private func filteredApps() -> [(bundleId: String, name: String)] {
        let f = filter.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !f.isEmpty else { return apps }
        return apps.filter { $0.name.lowercased().contains(f) || $0.bundleId.lowercased().contains(f) }
    }

    private func loadIfNeeded(force: Bool = false) {
        guard force || apps.isEmpty else { return }
        loadToken &+= 1
        let token = loadToken
        isLoadingApps = true

        DispatchQueue.global(qos: .userInitiated).async {
            let list = (try? DB.shared.distinctApps()) ?? []
            DispatchQueue.main.async {
                guard token == loadToken else { return }
                apps = list
                isLoadingApps = false
            }
        }
    }
}

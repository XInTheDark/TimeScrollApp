import SwiftUI
import AppKit
import Combine

struct OnboardingView: View {
    @EnvironmentObject var settings: SettingsStore

    @State private var currentStep = 0

    // Step 0: Capture mode
    @State private var useDirectMode = true

    // Step 1: Optional audio capture
    @State private var enableAudioFeature = false
    @State private var captureScreen = true
    @State private var captureMicrophone = false
    @State private var captureSystemAudio = false

    // Step 2: Vault
    @State private var enableVault = false

    // Step 3: AI features
    @AppStorage("settings.mcpEnabled") private var mcpEnabled: Bool = false
    @State private var aiModeEnabled = true

    // Step 4: Permissions
    @State private var hasScreenRecording = Permissions.isScreenRecordingGranted()
    @State private var hasAccessibility = Permissions.isAccessibilityGranted()
    @State private var hasMicrophone = Permissions.isMicrophoneGranted()
    @State private var isRequesting = false

    @State private var wentThroughFullFlow = false
    @State private var modelAvailabilityRevision = 0

    private let totalSteps = 5

    private var captureSelection: CaptureModeSelection {
        CaptureModeSelection(
            audioFeatureEnabled: enableAudioFeature,
            captureScreenEnabled: captureScreen,
            captureAudioEnabled: enableAudioFeature && (captureMicrophone || captureSystemAudio),
            captureMicrophoneEnabled: captureMicrophone,
            captureSystemAudioEnabled: captureSystemAudio
        )
    }

    var body: some View {
        VStack(spacing: 24) {
            header

            switch currentStep {
            case 0:
                captureModeStep
            case 1:
                audioCaptureStep
            case 2:
                vaultStep
            case 3:
                aiStep
            default:
                permissionsStep
            }

            Spacer()

            footer
        }
        .padding(24)
        .frame(width: 620, height: 520)
        .animation(.easeInOut, value: currentStep)
        .onAppear {
            useDirectMode = settings.textProcessingMode == .accessibility
            enableAudioFeature = settings.audioFeatureEnabled
            captureScreen = settings.captureScreenEnabled
            captureMicrophone = settings.captureMicrophoneEnabled
            captureSystemAudio = settings.captureSystemAudioEnabled
            enableVault = settings.vaultEnabled
            aiModeEnabled = settings.aiModeOn
            refreshPermissionState()

            let existingSelection = CaptureModeSelection(settings: settings)
            let hasRequiredPermissions = Permissions.hasRequiredCapturePermissions(
                for: existingSelection,
                textProcessingMode: settings.textProcessingMode
            )

            if settings.onboardingCompleted && !hasRequiredPermissions {
                currentStep = totalSteps - 1
                wentThroughFullFlow = false
            } else {
                wentThroughFullFlow = true
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .whisperModelAvailabilityDidChange)
            .receive(on: RunLoop.main)) { _ in
                modelAvailabilityRevision &+= 1
            }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 16) {
            Image(nsImage: NSApplication.shared.applicationIconImage)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 52, height: 52)
                .clipShape(Circle())
                .overlay(Circle().stroke(Color.primary.opacity(0.1), lineWidth: 1))
                .shadow(color: .black.opacity(0.08), radius: 3, x: 0, y: 1)

            VStack(alignment: .leading, spacing: 4) {
                Text("Welcome to TimeScroll")
                    .font(.title2.weight(.semibold))
                Text(headerSubtitle)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if wentThroughFullFlow {
                stepIndicator
            }
        }
    }

    private var headerSubtitle: String {
        switch currentStep {
        case 0:
            return "Choose how TimeScroll captures text from your screen."
        case 1:
            return "Optionally add microphone or system-audio capture to your timeline."
        case 2:
            return "Keep your data secure with encryption."
        case 3:
            return "Enhance your experience with AI features."
        default:
            return "Grant the permissions needed for your selected capture setup."
        }
    }

    private var stepIndicator: some View {
        HStack(spacing: 6) {
            ForEach(0..<totalSteps, id: \.self) { step in
                Circle()
                    .fill(step == currentStep ? Color.blue : Color.primary.opacity(0.2))
                    .frame(width: 8, height: 8)
            }
        }
    }

    private var captureModeStep: some View {
        VStack(spacing: 12) {
            OptionCard(
                icon: "accessibility",
                title: "Direct Mode",
                description: "Uses Accessibility API to read text directly. Much lower energy usage, but may rarely fail with some apps.",
                isSelected: useDirectMode
            )
            .onTapGesture { useDirectMode = true }

            OptionCard(
                icon: "doc.text.viewfinder",
                title: "Legacy Mode",
                description: "Uses OCR to extract text from screenshots. Works with all apps and content, but uses more energy.",
                isSelected: !useDirectMode
            )
            .onTapGesture { useDirectMode = false }
        }
    }

    private var audioCaptureStep: some View {
        VStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    Image(systemName: "waveform")
                        .font(.system(size: 28))
                        .foregroundStyle(.blue)
                        .frame(width: 40)

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Optional Audio Capture")
                            .font(.headline)
                        Text("Add microphone or system-audio segments with Whisper transcripts, without changing the default screen-only workflow unless you opt in.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }

                Toggle("Enable audio capture features", isOn: $enableAudioFeature)
                    .toggleStyle(.switch)
                    .onChange(of: enableAudioFeature) { enabled in
                        if enabled && !captureScreen && !captureMicrophone && !captureSystemAudio {
                            captureScreen = true
                        }
                    }

                if enableAudioFeature {
                    Divider()

                    Toggle("Keep screen snapshots", isOn: $captureScreen)
                        .toggleStyle(.switch)
                    Toggle("Record microphone audio", isOn: $captureMicrophone)
                        .toggleStyle(.switch)
                    Toggle("Record system audio", isOn: $captureSystemAudio)
                        .toggleStyle(.switch)

                    VStack(alignment: .leading, spacing: 6) {
                        Label("System audio also needs Screen Recording permission.", systemImage: "display")
                        Label("Microphone audio uses a separate microphone permission.", systemImage: "mic")
                    }
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                    if (captureMicrophone || captureSystemAudio),
                       !WhisperModelStore.isModelAvailable(settings.whisperModelID) {
                        VStack(alignment: .leading, spacing: 8) {
                            Label("Download the selected Whisper model before continuing.", systemImage: "exclamationmark.triangle")
                                .foregroundStyle(.orange)
                            Button("Open Audio Preferences") {
                                _ = NSApp.sendAction(Selector(("showPreferencesWindow:")), to: nil, from: nil)
                            }
                            .buttonStyle(.bordered)
                        }
                    }

                    if !captureSelection.hasAnyCaptureEnabled {
                        Label("Enable at least one capture source to continue.", systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                    }
                } else {
                    Text("Leave this off to keep TimeScroll in its current screen-only mode.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(20)
            .background(.regularMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Color.primary.opacity(0.08), lineWidth: 1)
            )
        }
    }

    private var vaultStep: some View {
        VStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    Image(systemName: "lock.shield")
                        .font(.system(size: 32))
                        .foregroundStyle(.blue)
                        .frame(width: 40)

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Encrypted Vault")
                            .font(.headline)
                        Text("Protect your captures with encryption. Your data will be secured with a private key, and you'll need to authenticate to access it.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }

                Toggle("Enable encrypted vault", isOn: $enableVault)
                    .toggleStyle(.switch)
                    .padding(.top, 8)
            }
            .padding(20)
            .background(.regularMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Color.primary.opacity(0.08), lineWidth: 1)
            )
        }
    }

    private var aiStep: some View {
        VStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    Image(systemName: "bolt.horizontal")
                        .font(.system(size: 24))
                        .foregroundStyle(.purple)
                        .frame(width: 32)

                    VStack(alignment: .leading, spacing: 4) {
                        Text("MCP Integration")
                            .font(.headline)
                        Text("Enables tools for AI assistants like Claude to search your TimeScroll history.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Toggle("", isOn: $mcpEnabled)
                        .toggleStyle(.switch)
                        .labelsHidden()
                }
            }
            .padding(16)
            .background(.regularMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Color.primary.opacity(0.08), lineWidth: 1)
            )

            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 24))
                        .foregroundStyle(.orange)
                        .frame(width: 32)

                    VStack(alignment: .leading, spacing: 4) {
                        Text("AI Search Mode")
                            .font(.headline)
                        Text("Use NLP-based search to find content by meaning, not just keywords.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Toggle("", isOn: $aiModeEnabled)
                        .toggleStyle(.switch)
                        .labelsHidden()
                }
            }
            .padding(16)
            .background(.regularMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Color.primary.opacity(0.08), lineWidth: 1)
            )
        }
    }

    private var permissionsStep: some View {
        VStack(spacing: 16) {
            if captureSelection.requiresScreenRecordingPermission {
                screenRecordingCard
            }

            if captureSelection.requiresMicrophonePermission {
                microphoneCard
            }

            if useDirectMode || hasAccessibility {
                accessibilityCard
            }
        }
    }

    private var footer: some View {
        HStack {
            if currentStep > 0 && wentThroughFullFlow {
                Button("Back") {
                    currentStep -= 1
                }
                .keyboardShortcut(.cancelAction)
            }

            Spacer()

            if currentStep < totalSteps - 1 {
                Button("Continue") {
                    currentStep += 1
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(!canContinue)
            } else {
                Button("Start TimeScroll") {
                    startCaptureAndClose()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(!canProceed)
            }
        }
    }

    private var canContinue: Bool {
        if currentStep == 1 {
            guard captureSelection.hasAnyCaptureEnabled else { return false }
            if captureSelection.capturesAudio {
                return WhisperModelStore.isModelAvailable(settings.whisperModelID)
            }
        }
        return true
    }

    private var canProceed: Bool {
        guard captureSelection.hasAnyCaptureEnabled else { return false }
        if captureSelection.requiresScreenRecordingPermission && !hasScreenRecording { return false }
        if captureSelection.requiresMicrophonePermission && !hasMicrophone { return false }
        if useDirectMode && !hasAccessibility { return false }
        return true
    }

    private var screenRecordingCard: some View {
        permissionCard(
            title: "Screen Recording",
            description: captureSelection.capturesSystemAudio && !captureSelection.capturesScreen
                ? "Required for system-audio capture."
                : "Allows TimeScroll to capture screenshots and any system-audio streams you enabled.",
            ok: hasScreenRecording,
            grantedText: "Granted",
            primaryLabel: "Grant Screen Recording",
            primarySystemImage: "hand.raised",
            secondaryLabel: "Open System Settings",
            secondarySystemImage: "gear",
            primaryAction: requestScreenRecording,
            secondaryAction: { _ = Permissions.open(.screenRecording) }
        )
    }

    private var microphoneCard: some View {
        permissionCard(
            title: "Microphone",
            description: "Required to capture microphone audio segments.",
            ok: hasMicrophone,
            grantedText: "Granted",
            primaryLabel: "Grant Microphone",
            primarySystemImage: "mic",
            secondaryLabel: "Open System Settings",
            secondarySystemImage: "gear",
            primaryAction: requestMicrophone,
            secondaryAction: { _ = Permissions.open(.microphone) }
        )
    }

    private var accessibilityCard: some View {
        permissionCard(
            title: "Accessibility",
            description: "Required for Direct mode to read text with low energy.",
            ok: hasAccessibility,
            grantedText: "Granted",
            primaryLabel: "Grant Accessibility",
            primarySystemImage: "hand.tap",
            secondaryLabel: "Open System Settings",
            secondarySystemImage: "gear",
            primaryAction: requestAccessibility,
            secondaryAction: { _ = Permissions.open(.accessibility) }
        )
    }

    private func permissionCard(title: String,
                                description: String,
                                ok: Bool,
                                grantedText: String,
                                primaryLabel: String,
                                primarySystemImage: String,
                                secondaryLabel: String,
                                secondarySystemImage: String,
                                primaryAction: @escaping () -> Void,
                                secondaryAction: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 10) {
                StatusDot(ok: ok)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.headline)
                    Text(description)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            HStack(spacing: 8) {
                if ok {
                    Label(grantedText, systemImage: "checkmark")
                        .foregroundStyle(.green)
                } else {
                    Button(action: primaryAction) {
                        Label(primaryLabel, systemImage: primarySystemImage)
                    }
                    .buttonStyle(.borderedProminent)

                    Button(action: secondaryAction) {
                        Label(secondaryLabel, systemImage: secondarySystemImage)
                    }
                    .buttonStyle(.bordered)
                }
                Spacer()
            }
        }
        .padding(16)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        )
    }

    private func requestScreenRecording() {
        guard !isRequesting else { return }
        if Permissions.isScreenRecordingGranted() {
            hasScreenRecording = true
            return
        }
        isRequesting = true
        Task {
            hasScreenRecording = await Permissions.requestScreenRecording()
            isRequesting = false
        }
    }

    private func requestMicrophone() {
        guard !isRequesting else { return }
        if Permissions.isMicrophoneGranted() {
            hasMicrophone = true
            return
        }
        isRequesting = true
        Task {
            hasMicrophone = await Permissions.requestMicrophone()
            isRequesting = false
        }
    }

    private func requestAccessibility() {
        if Permissions.isAccessibilityGranted() {
            hasAccessibility = true
            return
        }
        Permissions.requestAccessibility()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            refreshPermissionState()
        }
    }

    private func refreshPermissionState() {
        hasScreenRecording = Permissions.isScreenRecordingGranted()
        hasAccessibility = Permissions.isAccessibilityGranted()
        hasMicrophone = Permissions.isMicrophoneGranted()
    }

    private func startCaptureAndClose() {
        if wentThroughFullFlow {
            settings.textProcessingMode = useDirectMode ? .accessibility : .ocr
            settings.audioFeatureEnabled = enableAudioFeature
            settings.captureScreenEnabled = captureScreen
            settings.captureAudioEnabled = enableAudioFeature && (captureMicrophone || captureSystemAudio)
            settings.captureMicrophoneEnabled = captureMicrophone
            settings.captureSystemAudioEnabled = captureSystemAudio
            settings.vaultEnabled = enableVault
            settings.aiModeOn = aiModeEnabled
            settings.onboardingCompleted = true
        }

        Task { @MainActor in
            if wentThroughFullFlow {
                await VaultManager.shared.setVaultEnabled(enableVault)
                if enableVault {
                    await VaultManager.shared.unlock(presentingWindow: NSApp.keyWindow)
                }
            }
            await AppState.shared.startCaptureIfNeeded()
            NSApp.windows.first(where: { $0.identifier?.rawValue == "OnboardingWindow" })?.close()
        }
    }
}

private struct OptionCard: View {
    let icon: String
    let title: String
    let description: String
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 16) {
            Image(systemName: icon)
                .font(.system(size: 24))
                .frame(width: 32)
                .foregroundStyle(isSelected ? .blue : .secondary)

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.headline)
                Text(description)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()

            if isSelected {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.blue)
                    .font(.title3)
            }
        }
        .padding(16)
        .background(isSelected ? Color.blue.opacity(0.1) : Color.primary.opacity(0.03))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(isSelected ? Color.blue : Color.clear, lineWidth: 2)
        )
        .contentShape(Rectangle())
    }
}

private struct StatusDot: View {
    let ok: Bool

    var body: some View {
        Circle()
            .fill(ok ? Color.green : Color.orange)
            .frame(width: 12, height: 12)
            .overlay(Circle().strokeBorder(Color.black.opacity(0.05), lineWidth: 0.5))
            .accessibilityLabel(ok ? "Granted" : "Not Granted")
    }
}

#if DEBUG
struct OnboardingView_Previews: PreviewProvider {
    static var previews: some View {
        OnboardingView()
            .environmentObject(SettingsStore.shared)
            .frame(width: 620)
            .padding()
    }
}
#endif

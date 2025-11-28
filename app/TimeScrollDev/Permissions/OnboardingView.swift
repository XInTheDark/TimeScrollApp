import SwiftUI
import AppKit

struct OnboardingView: View {
  @EnvironmentObject var settings: SettingsStore
  @State private var currentStep = 0

  // Step 0: Capture mode
  @State private var useDirectMode = false  // false = OCR (standard), true = AX (direct)

  // Step 1: Vault
  @State private var enableVault = false

  // Step 2: AI features
  @AppStorage("settings.mcpEnabled") private var mcpEnabled: Bool = false
  @State private var aiModeEnabled = true

  // Step 3: Permissions
  @State private var hasScreenRecording = Permissions.isScreenRecordingGranted()
  @State private var hasAccessibility = Permissions.isAccessibilityGranted()
  @State private var isRequesting = false

  // Track if user went through full flow (vs jumping to permissions only)
  @State private var wentThroughFullFlow = false

  private let totalSteps = 4

  var body: some View {
    VStack(spacing: 24) {
      header

      switch currentStep {
      case 0:
        captureModeStep
      case 1:
        vaultStep
      case 2:
        aiStep
      default:
        permissionsStep
      }

      Spacer()

      footer
    }
    .padding(24)
    .frame(width: 600, height: 500)
    .animation(.easeInOut, value: currentStep)
    .onAppear {
      // Initialize from current settings
      useDirectMode = settings.textProcessingMode == .accessibility
      enableVault = settings.vaultEnabled
      aiModeEnabled = settings.aiModeOn

      if settings.onboardingCompleted && !Permissions.isScreenRecordingGranted() {
        // Returning user who lost permissions: skip to permissions only
        currentStep = 3
        wentThroughFullFlow = false
      } else {
        // First-time user OR user who clicked "Show Onboarding" manually
        wentThroughFullFlow = true
      }
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
          .font(.title2).fontWeight(.semibold)
        Text(headerSubtitle)
          .foregroundStyle(.secondary)
      }
      Spacer()

      // Step indicator (only show for full flow)
      if wentThroughFullFlow {
        stepIndicator
      }
    }
  }

  private var headerSubtitle: String {
    switch currentStep {
    case 0: return "Choose how TimeScroll captures text from your screen."
    case 1: return "Keep your data secure with encryption."
    case 2: return "Enhance your experience with AI features."
    default: return "We need macOS permissions to capture your screen."
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

  // MARK: - Step 0: Capture Mode

  private var captureModeStep: some View {
    VStack(spacing: 12) {
      OptionCard(
        icon: "doc.text.viewfinder",
        title: "Standard Mode",
        description: "Uses OCR to extract text from screenshots. Works with all apps and content.",
        isSelected: !useDirectMode
      )
      .onTapGesture { useDirectMode = false }

      OptionCard(
        icon: "accessibility",
        title: "Direct Mode",
        description: "(Experimental) Uses Accessibility API to read text directly. Much lower energy usage, but may not work with all apps.",
        isSelected: useDirectMode
      )
      .onTapGesture { useDirectMode = true }
    }
  }

  // MARK: - Step 1: Vault

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
            Text("Protect your screenshots with encryption. Your data will be secured with a private key, and you'll need to authenticate to access it.")
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

  // MARK: - Step 2: AI Features

  private var aiStep: some View {
    VStack(spacing: 12) {
      // MCP Toggle
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

      // AI Mode Toggle
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

  // MARK: - Step 3: Permissions

  private var permissionsStep: some View {
    VStack(spacing: 16) {
      permissionCard

      // Show accessibility if user chose Direct mode OR already has it
      if useDirectMode || hasAccessibility {
        accessibilityCard
      }
    }
  }

  private var footer: some View {
    HStack {
      if currentStep > 0 && wentThroughFullFlow {
        Button("Back") { currentStep -= 1 }
          .keyboardShortcut(.cancelAction)
      }
      Spacer()

      if currentStep < 3 {
        Button("Continue") {
          currentStep += 1
        }
        .buttonStyle(.borderedProminent)
        .keyboardShortcut(.defaultAction)
      } else {
        Button("Start TimeScroll") {
          startCaptureAndClose()
        }
        .buttonStyle(.borderedProminent)
        .disabled(!canProceed)
        .keyboardShortcut(.defaultAction)
      }
    }
  }

  private var canProceed: Bool {
    if !hasScreenRecording { return false }
    if useDirectMode && !hasAccessibility { return false }
    return true
  }

  private var permissionCard: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack(alignment: .center, spacing: 10) {
        StatusDot(ok: hasScreenRecording)
        VStack(alignment: .leading, spacing: 2) {
          Text("Screen Recording")
            .font(.headline)
          Text("Allows TimeScroll to capture screenshots for your personal timeline.")
            .font(.subheadline)
            .foregroundStyle(.secondary)
        }
        Spacer()
      }
      HStack(spacing: 8) {
        if hasScreenRecording {
          Label("Granted", systemImage: "checkmark")
            .foregroundStyle(.green)
        } else {
          Button(action: requestScreenRecording) {
            Label("Grant Screen Recording", systemImage: "hand.raised")
          }
          .buttonStyle(.borderedProminent)

          Button(action: { _ = Permissions.open(.screenRecording) }) {
            Label("Open System Settings", systemImage: "gear")
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

  private var accessibilityCard: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack(spacing: 10) {
        StatusDot(ok: hasAccessibility)
        VStack(alignment: .leading, spacing: 2) {
          Text("Accessibility")
            .font(.headline)
          Text("Required for Direct mode to read text with low energy.")
            .font(.subheadline)
            .foregroundStyle(.secondary)
        }
        Spacer()
      }
      HStack(spacing: 8) {
        if hasAccessibility {
          Label("Granted", systemImage: "checkmark")
            .foregroundStyle(.green)
        } else {
          Button(action: {
            if Permissions.isAccessibilityGranted() {
              hasAccessibility = true
              return
            }
            Permissions.requestAccessibility()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
              hasAccessibility = Permissions.isAccessibilityGranted()
            }
          }) {
            Label("Grant Accessibility", systemImage: "hand.tap")
          }.buttonStyle(.borderedProminent)

          Button(action: { _ = Permissions.open(.accessibility) }) {
            Label("Open System Settings", systemImage: "gear")
          }.buttonStyle(.bordered)
        }
        Spacer()
      }
    }
    .padding(16)
    .background(.regularMaterial)
    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
      .stroke(Color.primary.opacity(0.08), lineWidth: 1))
  }

  private func requestScreenRecording() {
    guard !isRequesting else { return }
    if Permissions.isScreenRecordingGranted() {
      hasScreenRecording = true
      return
    }
    isRequesting = true
    Permissions.requestScreenRecording()
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
      isRequesting = false
      recheck()
    }
  }

  private func recheck() {
    hasScreenRecording = Permissions.isScreenRecordingGranted()
  }

  private func startCaptureAndClose() {
    // Apply settings if user went through the full flow (not just permissions-only)
    if wentThroughFullFlow {
      settings.textProcessingMode = useDirectMode ? .accessibility : .ocr
      settings.vaultEnabled = enableVault
      settings.aiModeOn = aiModeEnabled
      // mcpEnabled is already bound to @AppStorage
      settings.onboardingCompleted = true
    }

    Task { @MainActor in
      await AppState.shared.startCaptureIfNeeded()
      NSApp.windows.first(where: { $0.identifier?.rawValue == "OnboardingWindow" })?.close()
    }
  }
}

// MARK: - Option Card

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
    OnboardingView().environmentObject(SettingsStore.shared)
      .frame(width: 600)
      .padding()
  }
}
#endif

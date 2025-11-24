import SwiftUI
import AppKit

struct OnboardingView: View {
    @EnvironmentObject var settings: SettingsStore
    @State private var hasScreenRecording = Permissions.isScreenRecordingGranted()
    @State private var isRequesting = false

    var body: some View {
        VStack(spacing: 24) {
            header
            VStack(spacing: 16) {
                permissionCard
            }
        }
        .padding(24)
        .frame(minWidth: 560, maxWidth: 620)
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
                Text("We need macOS permissions to capture your screen.")
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
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
                    Button(role: .none) { recheck() } label: {
                        Label("Recheck", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.bordered)
                } else {
                    Button(action: requestScreenRecording) {
                        Label("Grant Screen Recording", systemImage: "hand.raised")
                    }
                    .buttonStyle(.borderedProminent)

                    Button(action: { _ = Permissions.open(.screenRecording) }) {
                        Label("Open System Settings", systemImage: "gear")
                    }
                    .buttonStyle(.bordered)

                    Button(action: recheckAndMaybeClose) {
                        Label("Done", systemImage: "checkmark")
                    }
                    .buttonStyle(.bordered)
                    .disabled(isRequesting)
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
        isRequesting = true
        Permissions.requestScreenRecording()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            isRequesting = false
        }
    }

    private func recheck() {
        hasScreenRecording = Permissions.isScreenRecordingGranted()
    }

    private func recheckAndMaybeClose() {
        let granted = Permissions.isScreenRecordingGranted()
        hasScreenRecording = granted
        if granted {
            NSApp.windows.first(where: { $0.identifier?.rawValue == "OnboardingWindow" })?.close()
        }
    }

    private func startCaptureAndClose() {
        Task { @MainActor in
            await AppState.shared.startCaptureIfNeeded()
            // Close the onboarding window
            NSApp.windows.first(where: { $0.identifier?.rawValue == "OnboardingWindow" })?.close()
        }
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

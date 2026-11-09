import SwiftUI

/// Onboarding step that chooses which apps start out excluded from capture.
struct OnboardingExclusionsStep: View {
    @Binding var includeDefaults: Bool
    @Binding var addedBundleIds: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Image(systemName: "eye.slash")
                    .font(.system(size: 28))
                    .foregroundStyle(.blue)
                    .frame(width: 40)

                VStack(alignment: .leading, spacing: 4) {
                    Text("Excluded Apps")
                        .font(.headline)
                    Text("Windows from these apps are never captured. You can change this later in Settings.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }

            Toggle(isOn: $includeDefaults) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Start with the default exclusions")
                    Text("Password managers and the login screen.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            .toggleStyle(.checkbox)
            .padding(.top, 4)

            if !addedBundleIds.isEmpty {
                ScrollView {
                    VStack(spacing: 6) {
                        ForEach(addedBundleIds, id: \.self) { bundleId in
                            HStack {
                                PrivacyAppRow(bundleId: bundleId)
                                Button {
                                    addedBundleIds.removeAll { $0 == bundleId }
                                } label: {
                                    Image(systemName: "minus.circle")
                                }
                                .buttonStyle(.borderless)
                                .accessibilityLabel("Remove")
                            }
                        }
                    }
                }
                .frame(maxHeight: 130)
            }

            Button(action: addApps) {
                Label("Add App…", systemImage: "plus")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        )
    }

    private func addApps() {
        ExcludedAppPicker.pick { bundleIds in
            for bundleId in bundleIds where !addedBundleIds.contains(bundleId) {
                addedBundleIds.append(bundleId)
            }
        }
    }
}

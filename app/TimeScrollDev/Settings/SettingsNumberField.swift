import SwiftUI

/// Bordered, right-aligned numeric field with a unit label, baseline-aligned for settings rows.
struct SettingsNumberField: View {
    @Binding var value: Int
    let formatter: Formatter
    let unit: String
    var width: CGFloat = 64

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            TextField("", value: $value, formatter: formatter)
                .labelsHidden()
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.trailing)
                .monospacedDigit()
                .frame(width: width)
            Text(unit)
                .foregroundStyle(.secondary)
        }
    }
}

import SwiftUI

/// Slider with a trailing value readout. Every settings slider uses the same readout width so
/// slider tracks line up across rows and panes.
struct SettingsSlider<Value: BinaryFloatingPoint>: View where Value.Stride: BinaryFloatingPoint {
    static var valueWidth: CGFloat { 64 }

    @Binding var value: Value
    let range: ClosedRange<Value>
    let step: Value.Stride
    let valueText: String

    init(value: Binding<Value>, in range: ClosedRange<Value>, step: Value.Stride, valueText: String) {
        _value = value
        self.range = range
        self.step = step
        self.valueText = valueText
    }

    var body: some View {
        HStack(spacing: 12) {
            Slider(value: $value, in: range, step: step)
            Text(valueText)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(width: Self.valueWidth, alignment: .trailing)
        }
        .frame(minWidth: 240, maxWidth: 360)
    }
}

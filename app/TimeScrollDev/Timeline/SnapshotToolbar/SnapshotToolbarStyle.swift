import SwiftUI

/// The floating toolbar's surface: Liquid Glass on macOS 26 and later, a translucent material
/// with a hairline and soft shadow before that.
struct SnapshotToolbarSurface: ViewModifier {
  func body(content: Content) -> some View {
    if #available(macOS 26.0, *) {
      content.glassEffect(.regular, in: .capsule)
    } else {
      content
        .background(.regularMaterial, in: Capsule(style: .continuous))
        .overlay(Capsule(style: .continuous).strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.2), radius: 10, y: 3)
    }
  }
}

extension View {
  func snapshotToolbarSurface() -> some View { modifier(SnapshotToolbarSurface()) }
}

/// An icon button in the floating toolbar: a round hit area that highlights on hover and press.
struct SnapshotToolbarIconStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    HoverHighlight(isPressed: configuration.isPressed) { configuration.label }
  }

  private struct HoverHighlight<Label: View>: View {
    let isPressed: Bool
    @ViewBuilder let label: () -> Label
    @State private var isHovering = false
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
      label()
        .font(.system(size: 15, weight: .medium))
        .foregroundStyle(.primary)
        .opacity(isEnabled ? 1 : 0.35)
        .padding(.horizontal, 7)
        .frame(minWidth: 30, minHeight: 30)
        .background(Capsule(style: .continuous).fill(Color.primary.opacity(isPressed ? 0.16 : (isHovering && isEnabled ? 0.08 : 0))))
        .contentShape(Capsule(style: .continuous))
        .onHover { isHovering = $0 }
    }
  }
}

/// A thin divider between the toolbar's groups.
struct SnapshotToolbarDivider: View {
  var body: some View {
    Rectangle()
      .fill(Color.primary.opacity(0.15))
      .frame(width: 1, height: 18)
      .padding(.horizontal, 4)
  }
}

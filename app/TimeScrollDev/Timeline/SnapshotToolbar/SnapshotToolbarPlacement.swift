import CoreGraphics

/// Where the floating toolbar sits: centered plus the user's drag offset, kept fully inside the
/// stage so a wider toolbar or a smaller window never pushes it out of reach. Pure.
enum SnapshotToolbarPlacement {
  static let margin: CGFloat = 12

  static func clamped(offset: CGSize, toolbar: CGSize, in container: CGSize) -> CGSize {
    func clamp(_ value: CGFloat, toolbar: CGFloat, container: CGFloat) -> CGFloat {
      let limit = max(0, (container - toolbar) / 2 - margin)
      return min(max(value, -limit), limit)
    }
    return CGSize(width: clamp(offset.width, toolbar: toolbar.width, container: container.width),
                  height: clamp(offset.height, toolbar: toolbar.height, container: container.height))
  }
}

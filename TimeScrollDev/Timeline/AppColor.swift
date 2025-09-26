import AppKit

enum AppColor {
    static func color(for bundleId: String?) -> NSColor {
        guard let id = bundleId else { return NSColor.systemGray }
        var hasher = Hasher()
        hasher.combine(id)
        let hue = Double(abs(hasher.finalize() % 360)) / 360.0
        return NSColor(calibratedHue: CGFloat(hue), saturation: 0.55, brightness: 0.85, alpha: 1.0)
    }
}

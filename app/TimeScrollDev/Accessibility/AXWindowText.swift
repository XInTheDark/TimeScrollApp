import CoreGraphics

/// A short string and its global frame (top-left origin).
struct AXTextBox: Equatable {
    let text: String
    let frame: CGRect
}

/// The text read from one window: unique strings in reading order, one per line.
struct AXWindowText: Equatable {
    let text: String
    /// Character count of `text`, kept so merging never recounts.
    let count: Int
    let boxes: [AXTextBox]

    static let empty = AXWindowText(text: "", count: 0, boxes: [])
}

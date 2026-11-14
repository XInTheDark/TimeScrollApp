import Combine

/// What the Warp point field shows, and what Return and Escape do.
@MainActor
final class TimeWarpPointNoteModel: ObservableObject {
  @Published var text = ""
  @Published var focusRequest = 0
  var onSave: (String) -> Void = { _ in }
  var onCancel: () -> Void = {}
}

import AppKit
import SwiftUI

/// The Warp point field: a note, Return to save, Escape to cancel.
struct TimeWarpPointNoteView: View {
  @ObservedObject var model: TimeWarpPointNoteModel
  @FocusState private var isFocused: Bool

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Label("Add Warp Point", systemImage: "mappin")
        .font(.headline)
      TextField("Note (optional)", text: $model.text)
        .textFieldStyle(.roundedBorder)
        .focused($isFocused)
        .onSubmit { model.onSave(model.text) }
        .onExitCommand { model.onCancel() }
    }
    .padding(.horizontal, 16)
    .padding(.top, 14)
    .padding(.bottom, 16)
    .frame(width: 380)
    .background(Color(nsColor: .windowBackgroundColor))
    .onChange(of: model.focusRequest) { _, _ in isFocused = true }
    .onAppear { isFocused = true }
  }
}

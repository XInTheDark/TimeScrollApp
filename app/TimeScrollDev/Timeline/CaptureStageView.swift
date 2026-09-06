import SwiftUI

struct CaptureStageView: View {
    @ObservedObject var model: TimelineModel
    let globalQuery: String

    var body: some View {
        if model.selected?.captureKind == .audio {
            AudioStageView(model: model)
        } else {
            SnapshotStageView(model: model, globalQuery: globalQuery)
        }
    }
}

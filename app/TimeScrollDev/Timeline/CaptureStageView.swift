import SwiftUI

struct CaptureStageView: View {
    @ObservedObject var model: TimelineModel
    let globalQuery: String
    let menuActions: TimelineMenuActions

    var body: some View {
        ZStack {
            if model.selected?.captureKind == .audio {
                AudioStageView(model: model, menuActions: menuActions)
            } else {
                SnapshotStageView(model: model, globalQuery: globalQuery, menuActions: menuActions)
            }
            DayCalendarHost(calendar: model.dayCalendar, model: model)
        }
    }
}

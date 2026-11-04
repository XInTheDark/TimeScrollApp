import SwiftUI
import AppKit

/// Native date/time field with macOS's calendar overlay.
struct ExportDatePicker: NSViewRepresentable {
  @Binding var date: Date

  func makeNSView(context: Context) -> NSDatePicker {
    let picker = NSDatePicker()
    picker.datePickerStyle = .textFieldAndStepper
    picker.datePickerElements = [.yearMonthDay, .hourMinuteSecond]
    picker.presentsCalendarOverlay = true
    picker.target = context.coordinator
    picker.action = #selector(Coordinator.changed(_:))
    return picker
  }

  func updateNSView(_ picker: NSDatePicker, context: Context) {
    context.coordinator.date = $date
    picker.dateValue = date
  }

  func makeCoordinator() -> Coordinator { Coordinator(date: $date) }

  final class Coordinator: NSObject {
    var date: Binding<Date>
    init(date: Binding<Date>) { self.date = date }
    @objc func changed(_ sender: NSDatePicker) { date.wrappedValue = sender.dateValue }
  }
}

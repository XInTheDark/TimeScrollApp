import SwiftUI

/// A summary as an overview and titled topics.
struct RangeSummaryText: View {
  let text: String

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      ForEach(Array(SummaryOutput.sections(in: text).enumerated()), id: \.offset) { _, section in
        VStack(alignment: .leading, spacing: 3) {
          if let title = section.title {
            Text(title).fontWeight(.semibold)
          }
          Text(section.body)
        }
        .fixedSize(horizontal: false, vertical: true)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .textSelection(.enabled)
  }
}

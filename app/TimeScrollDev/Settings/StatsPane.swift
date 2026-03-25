import SwiftUI
import AppKit

@MainActor
struct StatsPane: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            StatsView()
        }
    }
}

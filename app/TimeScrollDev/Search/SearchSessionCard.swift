import Foundation

/// A session group ready to show: the group and its best hit with text loaded for the snippet.
struct SearchSessionCard: Identifiable {
  let group: SearchSessionGroup
  let bestRow: SearchResultDisplayRow

  var id: String { group.id }
}

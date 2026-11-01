import Foundation

/// JSON encoding of the list columns of `ts_activity_session`.
enum ActivitySessionColumns {
  private struct App: Codable {
    let b: String?
    let n: String?
    let ms: Int64
  }

  static func encodeApps(_ apps: [ActivitySession.AppShare]) -> String {
    let data = (try? JSONEncoder().encode(apps.map { App(b: $0.bundleId, n: $0.name, ms: $0.ms) })) ?? Data("[]".utf8)
    return String(decoding: data, as: UTF8.self)
  }

  static func decodeApps(_ json: String) -> [ActivitySession.AppShare] {
    ((try? JSONDecoder().decode([App].self, from: Data(json.utf8))) ?? []).map {
      ActivitySession.AppShare(bundleId: $0.b, name: $0.n, ms: $0.ms)
    }
  }

  static func encodeKeywords(_ keywords: [String]) -> String {
    String(decoding: (try? JSONEncoder().encode(keywords)) ?? Data("[]".utf8), as: UTF8.self)
  }

  static func decodeKeywords(_ json: String) -> [String] {
    (try? JSONDecoder().decode([String].self, from: Data(json.utf8))) ?? []
  }
}

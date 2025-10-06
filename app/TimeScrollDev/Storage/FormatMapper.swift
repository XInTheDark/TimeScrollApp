import Foundation

extension SettingsStore.StorageFormat {
    var dbFormatString: String {
        switch self {
        case .hevc: return "hevc"
        case .heic: return "heic"
        case .jpeg: return "jpg"
        case .png:  return "png"
        }
    }
}


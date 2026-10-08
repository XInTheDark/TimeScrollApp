import Foundation
@testable import TimeScroll

/// Saves the storage-root selection before a test points storage at a temporary folder.
/// Tests run hosted in the app and share its settings, so an unrestored root redirects
/// the user's real TimeScroll to a temp folder that macOS later purges.
struct StorageRootSnapshot {
  private let bookmark: Data?
  private let displayPath: String?
  private let markers: [(url: URL, contents: Data?)]

  init() {
    bookmark = StoragePaths.sharedData(forKey: StoragePaths.bookmarkKey)
    displayPath = StoragePaths.sharedString(forKey: StoragePaths.storageDisplayPathKey)
    markers = [StoragePaths.markerFile, StoragePaths.groupMarkerFile].map { ($0, try? Data(contentsOf: $0)) }
  }

  /// Closes the test database and restores the saved root and helper markers.
  func restore() {
    DB.shared.close()
    StoragePaths.setShared(bookmark, forKey: StoragePaths.bookmarkKey)
    StoragePaths.setShared(displayPath, forKey: StoragePaths.storageDisplayPathKey)
    StoragePaths.synchronizeShared()
    for marker in markers {
      if let contents = marker.contents {
        try? contents.write(to: marker.url, options: .atomic)
      } else {
        try? FileManager.default.removeItem(at: marker.url)
      }
    }
  }
}

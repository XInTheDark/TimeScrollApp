import AppKit
import UniformTypeIdentifiers

/// Asks the user to choose apps to exclude from capture.
enum ExcludedAppPicker {
    static func pick(completion: @escaping ([String]) -> Void) {
        let panel = NSOpenPanel()
        panel.title = "Choose Applications to Blacklist"
        panel.allowsMultipleSelection = true
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.application]
        panel.begin { response in
            guard response == .OK else { return }
            completion(panel.urls.compactMap { Bundle(url: $0)?.bundleIdentifier })
        }
    }
}

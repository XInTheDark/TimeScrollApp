import Foundation
import AVFoundation

struct AudioInputDevice: Identifiable, Hashable {
    let uniqueID: String
    let name: String

    var id: String { uniqueID }
}

enum AudioInputDeviceCatalog {
    static func availableDevices() -> [AudioInputDevice] {
        AVCaptureDevice.devices(for: .audio)
            .map { AudioInputDevice(uniqueID: $0.uniqueID, name: $0.localizedName) }
            .sorted { lhs, rhs in
                lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
    }

    static func device(uniqueID: String?) -> AVCaptureDevice? {
        let devices = AVCaptureDevice.devices(for: .audio)
        if let uniqueID, !uniqueID.isEmpty,
           let device = devices.first(where: { $0.uniqueID == uniqueID }) {
            return device
        }
        return AVCaptureDevice.default(for: .audio) ?? devices.first
    }

    static func displayName(for uniqueID: String?) -> String? {
        guard let uniqueID, !uniqueID.isEmpty else { return nil }
        return availableDevices().first(where: { $0.uniqueID == uniqueID })?.name
    }
}

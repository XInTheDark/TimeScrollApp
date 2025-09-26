import Foundation
import CoreGraphics

enum Permissions {
    static func requestScreenRecording() {
        let granted = CGPreflightScreenCaptureAccess()
        if !granted {
            _ = CGRequestScreenCaptureAccess()
        }
    }
}



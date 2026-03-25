import Foundation

extension FrameOutput {
    func applyThermalGovernorIfNeeded() {
        let now = Date().timeIntervalSince1970
        if now - lastThermalAdjustAt < 1.0 { return } // check ~1Hz
        lastThermalAdjustAt = now

        let state = ProcessInfo.processInfo.thermalState
        guard state != lastThermalState else { return }

        switch state {
        case .nominal, .fair:
            // Return to normal; nothing to do (cooldown auto-expires in Indexer)
            break
        case .serious:
            currentInterval = min(maxInterval, max(currentInterval, baseInterval) * 2)
            Indexer.shared.setOCRCooldown(seconds: 30)
            suppressPostersUntil = now + 30
        case .critical:
            currentInterval = min(maxInterval, max(currentInterval, baseInterval) * 3)
            Indexer.shared.setOCRCooldown(seconds: 60)
            suppressPostersUntil = now + 60
        @unknown default:
            break
        }

        lastThermalState = state
        reportProbeIntervalIfNeeded(force: true)
    }
}

import CoreVideo
import Foundation

extension FrameOutput {
    enum SkippedHEVCFrameAction: Equatable {
        /// Append this frame: a live segment writes a frame only once the next one arrives, so
        /// the first frame after a snapshot makes that snapshot readable from disk.
        case appendToFlush
        /// Encode nothing; only close the segment if its minute has passed, as an append would.
        case closeIfExpired
    }

    /// Decides what a frame skipped as a near-duplicate does to the HEVC segment. Only the first
    /// one after each snapshot is encoded; later ones would add frames no snapshot row points at.
    func skippedHEVCFrameAction() -> SkippedHEVCFrameAction {
        guard needsHEVCFlushFrame else { return .closeIfExpired }
        needsHEVCFlushFrame = false
        return .appendToFlush
    }

    func handleSkippedHEVCFrame(_ pixelBuffer: CVPixelBuffer, encrypt: Bool) {
        let tsMs = Int64(Date().timeIntervalSince1970 * 1000)
        switch skippedHEVCFrameAction() {
        case .appendToFlush:
            hevcStore.append(pixelBuffer: pixelBuffer, timestampMs: tsMs, encrypt: encrypt)
        case .closeIfExpired:
            hevcStore.closeIfExpired(nowMs: tsMs)
        }
    }
}

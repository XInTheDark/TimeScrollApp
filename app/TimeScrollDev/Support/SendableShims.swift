import Foundation
import CoreVideo

// CVPixelBuffer is a CFType bridged to Swift without Sendable conformance.
// We use it across GCD queues in a controlled manner; mark as @unchecked Sendable.
extension CVPixelBuffer: @retroactive @unchecked Sendable {}

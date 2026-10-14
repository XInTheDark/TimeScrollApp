//
//  OCRWatchdogTests.swift
//  TimeScrollDevTests
//

import Foundation
import CoreVideo
import Testing
@testable import TimeScroll

struct OCRWatchdogTests {
    private final class HangFirstCall: @unchecked Sendable {
        let release = DispatchSemaphore(value: 0)
        private let lock = NSLock()
        private var calls = 0

        func perform() {
            lock.lock()
            calls += 1
            let isFirst = calls == 1
            lock.unlock()
            if isFirst { release.wait() }
        }
    }

    private func makePixelBuffer() throws -> CVPixelBuffer {
        var pb: CVPixelBuffer?
        let status = CVPixelBufferCreate(nil, 16, 16, kCVPixelFormatType_32BGRA, nil, &pb)
        try #require(status == kCVReturnSuccess)
        return try #require(pb)
    }

    @Test func abandons_stuck_call_skips_while_stalled_then_recovers() throws {
        let vision = HangFirstCall()
        let service = OCRService(timeout: 0.2) { _, _ in vision.perform() }
        let pixelBuffer = try makePixelBuffer()

        #expect(throws: OCRService.WatchdogError.timedOut) { try service.recognize(from: pixelBuffer) }
        #expect(service.isStalled)
        #expect(throws: OCRService.WatchdogError.stalled) { try service.recognize(from: pixelBuffer) }

        // Once Vision finally returns, OCR resumes.
        vision.release.signal()
        let deadline = Date().addingTimeInterval(2)
        while service.isStalled && Date() < deadline { usleep(10_000) }
        #expect(!service.isStalled)
        let result = try service.recognize(from: pixelBuffer)
        #expect(result.text.isEmpty)
    }
}

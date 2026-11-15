import AVFoundation
import CoreVideo
import Foundation
import Testing
@testable import TimeScroll

/// Vault-mode HEVC segments are encoded in memory: only the sealed envelope reaches disk, and
/// the decrypted movie still places every frame at its offset from the segment start.
@Suite(.serialized)
struct EncryptedHEVCSegmentTests {
  private static let magic = Data("TEST-SEALED".utf8)
  /// A minute-aligned timestamp, so offsets inside one segment are known exactly.
  private let segmentStart: Int64 = 1_800_000_000_000 - (1_800_000_000_000 % 60_000)

  private final class Box: @unchecked Sendable {
    var fail = false
    var closed: [Int64] = []
  }

  private func makeStore(dir: URL, box: Box) -> HEVCVideoStore {
    HEVCVideoStore(namespace: "vault-tests",
                   videosDir: { dir },
                   seal: { video, _, _, _ in
                     if box.fail { throw NSError(domain: "test", code: 1) }
                     return Self.magic + video
                   },
                   onSegmentClosed: { start, _ in box.closed.append(start) })
  }

  private func tempDir() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("hevc-vault-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  private func frame(luma: UInt8, width: Int = 640, height: Int = 360) -> CVPixelBuffer {
    var buffer: CVPixelBuffer?
    CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
                        [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &buffer)
    let pb = buffer!
    CVPixelBufferLockBaseAddress(pb, [])
    memset(CVPixelBufferGetBaseAddressOfPlane(pb, 0), Int32(luma), CVPixelBufferGetBytesPerRowOfPlane(pb, 0) * height)
    memset(CVPixelBufferGetBaseAddressOfPlane(pb, 1), 128, CVPixelBufferGetBytesPerRowOfPlane(pb, 1) * height / 2)
    CVPixelBufferUnlockBaseAddress(pb, [])
    return pb
  }

  private func files(in dir: URL) -> [String] {
    ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).sorted()
  }

  private func luma(of asset: AVAsset, atMs ms: Int64) -> UInt8? {
    let generator = AVAssetImageGenerator(asset: asset)
    generator.requestedTimeToleranceBefore = .zero
    generator.requestedTimeToleranceAfter = .zero
    guard let image = try? generator.copyCGImage(at: CMTime(value: ms, timescale: 1000), actualTime: nil),
          let ctx = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 1,
                              space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
    return ctx.data?.load(as: UInt8.self)
  }

  @Test func onlySealedSegmentReachesDiskAndFramesKeepTheirOffsets() throws {
    let dir = try tempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let box = Box()
    let store = makeStore(dir: dir, box: box)
    let offsets: [Int64] = [4_000, 9_500, 21_000, 47_000, 58_000]
    let lumas: [UInt8] = [30, 80, 130, 180, 230]
    for (offset, value) in zip(offsets, lumas) {
      store.append(pixelBuffer: frame(luma: value), timestampMs: segmentStart + offset, encrypt: true)
      // Captures arrive seconds apart; give the encoder time to accept each frame, since
      // frames still queued when a segment closes are dropped by design.
      _ = store.unsavedSegmentCount
      Thread.sleep(forTimeInterval: 0.15)
    }
    _ = store.unsavedSegmentCount // waits for the queued frames
    #expect(files(in: dir).isEmpty, "nothing may be written while the segment is open")

    store.shutdown(timeout: 10)
    let sealedURL = store.urlFor(timestampMs: segmentStart, encrypt: true)
    #expect(files(in: dir) == [sealedURL.lastPathComponent])
    #expect(box.closed == [segmentStart])

    let blob = try Data(contentsOf: sealedURL)
    #expect(blob.starts(with: Self.magic))
    let video = blob.dropFirst(Self.magic.count)
    let playback = try tempDir()
    defer { try? FileManager.default.removeItem(at: playback) }
    let movie = playback.appendingPathComponent("segment.mp4")
    try Data(video).write(to: movie)
    let asset = AVURLAsset(url: movie)
    for (offset, value) in zip(offsets, lumas) {
      let decoded = luma(of: asset, atMs: offset + 200)
      #expect(decoded.map { abs(Int($0) - Int(value)) < 20 } == true, "frame at \(offset) ms decoded as \(String(describing: decoded))")
    }
  }

  @Test func sealingFailureKeepsSegmentInMemoryAndRetries() throws {
    let dir = try tempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let box = Box()
    box.fail = true
    let store = makeStore(dir: dir, box: box)
    store.append(pixelBuffer: frame(luma: 100), timestampMs: segmentStart + 1_000, encrypt: true)
    store.shutdown(timeout: 10)
    #expect(files(in: dir).isEmpty, "a failed seal must not leave plaintext behind")
    #expect(store.unsavedSegmentCount == 1)
    #expect(box.closed.isEmpty, "posters stay while the segment is unsaved")

    box.fail = false
    store.shutdown(timeout: 10)
    #expect(store.unsavedSegmentCount == 0)
    #expect(files(in: dir) == [store.urlFor(timestampMs: segmentStart, encrypt: true).lastPathComponent])
    #expect(box.closed == [segmentStart])
  }

  @Test func unsavedSegmentsAreBounded() throws {
    let dir = try tempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let box = Box()
    box.fail = true
    let store = makeStore(dir: dir, box: box)
    for minute in 0..<7 {
      store.append(pixelBuffer: frame(luma: 50, width: 320, height: 180),
                   timestampMs: segmentStart + Int64(minute) * 60_000 + 500, encrypt: true)
    }
    store.shutdown(timeout: 20)
    #expect(store.unsavedSegmentCount == 4)
    #expect(files(in: dir).isEmpty)
  }

  @Test func vaultOffStillWritesTheLiveMovie() throws {
    let dir = try tempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let store = makeStore(dir: dir, box: Box())
    store.append(pixelBuffer: frame(luma: 90), timestampMs: segmentStart + 2_000, encrypt: false)
    _ = store.unsavedSegmentCount
    #expect(files(in: dir) == [store.urlFor(timestampMs: segmentStart, encrypt: false).lastPathComponent])
    store.shutdown(timeout: 10)
  }

  @Test func memoryAssetContainerFollowsMime() {
    #expect(HEVCMemoryAsset.fileType(forMime: "video/mp4") == .mp4)
    #expect(HEVCMemoryAsset.fileType(forMime: "video/quicktime") == .mov)
    #expect(HEVCMemoryAsset.fileType(forMime: "audio/mp4") == .m4a)
    #expect(HEVCMemoryAsset.fileType(forMime: "audio/x-caf") == .caf)
  }
}

import CoreVideo
import CryptoKit
import Foundation
import Testing
@testable import TimeScroll

/// Cost of one encrypted HEVC segment: the previous path (live plaintext .mov, then read back,
/// seal, write, verify, delete) against in-memory encoding (seal, write, verify). Same frames,
/// same envelope cost. Opt-in: `TEST_RUNNER_TIMESCROLL_BENCHMARKS=1`; with
/// `TIMESCROLL_BENCHMARK_OUTPUT` set, results are appended there as JSON lines.
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["TIMESCROLL_BENCHMARKS"] == "1"))
struct HEVCVaultSegmentBenchmarks {
  private static let width = 1600
  private static let height = 1000
  private static let framesPerSegment = 12 // one capture every 5 s
  private static let segments = 8
  private static let recipient = Curve25519.KeyAgreement.PrivateKey().publicKey

  private func report(_ name: String, _ value: Double, _ unit: String) {
    print(String(format: "BENCH %@ %.3f %@", name, value, unit))
    guard let path = ProcessInfo.processInfo.environment["TIMESCROLL_BENCHMARK_OUTPUT"] else { return }
    let line = "{\"name\":\"\(name)\",\"value\":\(value),\"unit\":\"\(unit)\"}\n"
    if let handle = FileHandle(forWritingAtPath: path) {
      handle.seekToEndOfFile()
      handle.write(Data(line.utf8))
      try? handle.close()
    } else {
      FileManager.default.createFile(atPath: path, contents: Data(line.utf8))
    }
  }

  /// Same work as `FileCrypter.seal`: ephemeral X25519 + HKDF wrap, AES-256-GCM payload.
  private static func seal(_ payload: Data) throws -> Data {
    let fek = SymmetricKey(size: .bits256)
    let ephemeral = Curve25519.KeyAgreement.PrivateKey()
    let wrap = try ephemeral.sharedSecretFromKeyAgreement(with: recipient)
      .hkdfDerivedSymmetricKey(using: SHA256.self, salt: Data(), sharedInfo: Data("bench".utf8), outputByteCount: 32)
    let sealedKey = try AES.GCM.seal(fek.withUnsafeBytes { Data($0) }, using: wrap).combined ?? Data()
    let box = try AES.GCM.seal(payload, using: fek)
    return sealedKey + (box.combined ?? Data())
  }

  /// Screen-like content: a light page with dark text lines, a third of which change per frame.
  private static func frame(segment: Int, index: Int) -> CVPixelBuffer {
    var buffer: CVPixelBuffer?
    CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
                        [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &buffer)
    let pb = buffer!
    CVPixelBufferLockBaseAddress(pb, [])
    let luma = CVPixelBufferGetBaseAddressOfPlane(pb, 0)!.assumingMemoryBound(to: UInt8.self)
    let stride = CVPixelBufferGetBytesPerRowOfPlane(pb, 0)
    memset(luma, 235, stride * height)
    var rng = SystemRandomNumberGenerator()
    for line in 0..<(height / 24) {
      let changes = line % 3 == index % 3
      var seeded = UInt64(segment * 10_000 + line * 31 + (changes ? index : 0))
      let words = 4 + Int(seeded % 9)
      var x = 40
      for _ in 0..<words {
        seeded = seeded &* 6364136223846793005 &+ 1442695040888963407
        let w = 20 + Int(seeded >> 58)
        guard x + w < width - 40 else { break }
        for y in (line * 24 + 6)..<(line * 24 + 18) where y < height {
          memset(luma + y * stride + x, 40, w)
        }
        x += w + 8
      }
      _ = rng.next()
    }
    memset(CVPixelBufferGetBaseAddressOfPlane(pb, 1), 128, CVPixelBufferGetBytesPerRowOfPlane(pb, 1) * height / 2)
    CVPixelBufferUnlockBaseAddress(pb, [])
    return pb
  }

  private static func cpuMs() -> Double {
    var usage = rusage()
    getrusage(RUSAGE_SELF, &usage)
    func ms(_ t: timeval) -> Double { Double(t.tv_sec) * 1000 + Double(t.tv_usec) / 1000 }
    return ms(usage.ru_utime) + ms(usage.ru_stime)
  }

  private struct Sample { var cpuMs: Double; var closeMs: Double; var diskBytes: Double; var sealedBytes: Double }

  private func runSegment(memory: Bool, segment: Int, dir: URL) throws -> Sample {
    let store = HEVCVideoStore(namespace: "bench", videosDir: { dir },
                               seal: { video, _, _, _ in try Self.seal(video) },
                               onSegmentClosed: { _, _ in })
    let start: Int64 = 1_800_000_000_000 - (1_800_000_000_000 % 60_000) + Int64(segment) * 60_000
    let frames = (0..<Self.framesPerSegment).map { Self.frame(segment: segment, index: $0) }
    let cpuBefore = Self.cpuMs()
    for (i, pb) in frames.enumerated() {
      store.append(pixelBuffer: pb, timestampMs: start + Int64(i) * 5_000 + 200, encrypt: memory)
      _ = store.unsavedSegmentCount
      Thread.sleep(forTimeInterval: 0.1)
    }
    let closeStart = DispatchTime.now().uptimeNanoseconds
    store.shutdown(timeout: 30)
    var diskBytes = 0.0
    let sealedURL = store.urlFor(timestampMs: start, encrypt: true)
    if !memory {
      // The previous vault path: read the finished plaintext movie back, seal, write, verify, delete.
      let mov = store.urlFor(timestampMs: start, encrypt: false)
      let data = try Data(contentsOf: mov, options: [.mappedIfSafe])
      diskBytes += Double(data.count)
      let blob = try Self.seal(data)
      try blob.write(to: sealedURL, options: .atomic)
      guard try Data(contentsOf: sealedURL) == blob else { throw NSError(domain: "bench", code: 1) }
      try FileManager.default.removeItem(at: mov)
    }
    let closeMs = Double(DispatchTime.now().uptimeNanoseconds - closeStart) / 1e6
    let cpu = Self.cpuMs() - cpuBefore
    let sealed = Double((try? FileManager.default.attributesOfItem(atPath: sealedURL.path)[.size] as? Int) ?? 0)
    diskBytes += sealed
    return Sample(cpuMs: cpu, closeMs: closeMs, diskBytes: diskBytes, sealedBytes: sealed)
  }

  private func median(_ values: [Double]) -> Double { values.sorted()[values.count / 2] }

  @Test func encryptedSegmentCost() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("hevc-bench-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    // Warm up the encoder and quality probe once per path.
    _ = try runSegment(memory: false, segment: 99, dir: dir)
    _ = try runSegment(memory: true, segment: 98, dir: dir)
    for (label, memory) in [("file_then_seal", false), ("in_memory", true)] {
      var samples: [Sample] = []
      // Alternate segment content per path identically.
      for segment in 0..<Self.segments { samples.append(try runSegment(memory: memory, segment: segment, dir: dir)) }
      report("hevc_vault_segment_\(label)_cpu", median(samples.map(\.cpuMs)), "ms")
      report("hevc_vault_segment_\(label)_close", median(samples.map(\.closeMs)), "ms")
      report("hevc_vault_segment_\(label)_disk_written", median(samples.map(\.diskBytes)) / 1024, "KiB")
      report("hevc_vault_segment_\(label)_sealed_size", median(samples.map(\.sealedBytes)) / 1024, "KiB")
    }
  }
}

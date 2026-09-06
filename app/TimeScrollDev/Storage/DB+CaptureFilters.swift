import Foundation
#if canImport(SQLCipher)
import SQLCipher
#else
import SQLite3
#endif

extension DB {
    func normalizedCaptureFilters(_ captureKinds: [CaptureKind]?, _ audioSourceKinds: [AudioSourceKind]?) -> (captureKinds: [CaptureKind]?, audioSourceKinds: [AudioSourceKind]?) {
        let normalizedCaptureKinds = captureKinds?.isEmpty == false ? captureKinds : nil
        let normalizedAudioSourceKinds = audioSourceKinds?.isEmpty == false ? audioSourceKinds : nil
        return (normalizedCaptureKinds, normalizedAudioSourceKinds)
    }

    func appendCaptureFilterSQL(to sql: inout String,
                                alias: String,
                                captureKinds: [CaptureKind]?,
                                audioSourceKinds: [AudioSourceKind]?) {
        let normalized = normalizedCaptureFilters(captureKinds, audioSourceKinds)
        if let captureKinds = normalized.captureKinds, !captureKinds.isEmpty {
            let placeholders = Array(repeating: "?", count: captureKinds.count).joined(separator: ",")
            sql += " AND \(alias).capture_kind IN (\(placeholders))"
        }
        if let audioSourceKinds = normalized.audioSourceKinds, !audioSourceKinds.isEmpty {
            let placeholders = Array(repeating: "?", count: audioSourceKinds.count).joined(separator: ",")
            sql += " AND \(alias).source_kind IN (\(placeholders))"
        }
    }

    func bindCaptureFilters(stmt: OpaquePointer?,
                            index: inout Int32,
                            captureKinds: [CaptureKind]?,
                            audioSourceKinds: [AudioSourceKind]?) {
        let normalized = normalizedCaptureFilters(captureKinds, audioSourceKinds)
        if let captureKinds = normalized.captureKinds {
            for captureKind in captureKinds {
                sqlite3_bind_text(stmt, index, captureKind.rawValue, -1, SQLITE_TRANSIENT)
                index += 1
            }
        }
        if let audioSourceKinds = normalized.audioSourceKinds {
            for sourceKind in audioSourceKinds {
                sqlite3_bind_text(stmt, index, sourceKind.rawValue, -1, SQLITE_TRANSIENT)
                index += 1
            }
        }
    }

    func captureKindValue(from text: UnsafePointer<UInt8>?) -> CaptureKind {
        guard let text else { return .screen }
        return CaptureKind(rawValue: String(cString: text)) ?? .screen
    }

    func audioSourceKindValue(from text: UnsafePointer<UInt8>?) -> AudioSourceKind? {
        guard let text else { return nil }
        return AudioSourceKind(rawValue: String(cString: text))
    }
}

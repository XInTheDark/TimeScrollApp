import Foundation
struct RPCRequest: Decodable {
    let jsonrpc: String
    let id: RPCID?
    let method: String
    let params: AnyDecodable?
}

enum RPCID: Codable, Equatable {
    case int(Int)
    case string(String)

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let i = try? container.decode(Int.self) {
            self = .int(i)
        } else if let s = try? container.decode(String.self) {
            self = .string(s)
        } else {
            throw DecodingError.typeMismatch(
                RPCID.self,
                DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "RPC id must be string or int")
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .int(let i): try container.encode(i)
        case .string(let s): try container.encode(s)
        }
    }
}

struct RPCResponse<Result: Encodable>: Encodable {
    let jsonrpc = "2.0"
    let id: RPCID
    let result: Result
}

struct RPCErrorObj: Encodable { let code: Int; let message: String }
struct RPCErrorResponse: Encodable { let jsonrpc = "2.0"; let id: RPCID; let error: RPCErrorObj }

final class LineIO {
    func lines() -> AnyIterator<String> {
        AnyIterator {
            guard let s = readLine(strippingNewline: true) else { return nil }
            return s
        }
    }
    func writeJSON<T: Encodable>(_ v: T) {
        do {
            let data = try JSONEncoder().encode(v)
            if let s = String(data: data, encoding: .utf8) { print(s) }
        } catch {
            fputs("[timescroll-mcp] encode error: \(error)\n", stderr)
        }
    }
    func writeError(id: RPCID, code: Int, msg: String) {
        writeJSON(RPCErrorResponse(id: id, error: RPCErrorObj(code: code, message: msg)))
    }
}

// Lightweight file logger for the MCP helper. Keep usage minimal to avoid interfering with stdout.
// Never log request or response bodies: they carry search queries, OCR text and screenshots,
// which must not leave the (possibly encrypted) TimeScroll store as plaintext.
enum MCPFileLogger {
    private static let q = DispatchQueue(label: "timescroll.mcp.logger")
    private static let appGroupID = "group.com.muzhen.TimeScroll.shared"
    /// The log is truncated once it grows past this size so it cannot grow without bound.
    private static let maxLogBytes: UInt64 = 1 * 1024 * 1024
    private static let timestampFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    static var logURL: URL {
        let base = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupID)?
            .appendingPathComponent("Logs", isDirectory: true)
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
                .appendingPathComponent("TimeScrollShared/Logs", isDirectory: true)
        if !FileManager.default.fileExists(atPath: base.path) {
            try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true,
                                                     attributes: [.posixPermissions: 0o700])
        }
        return base.appendingPathComponent("timescroll-mcp.log")
    }

    /// Helpers before this version logged full request and response bodies; drop such a log once.
    static func purgeLegacyLogIfNeeded() {
        let key = "mcp.log.legacyBodiesPurged"
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: key) else { return }
        q.sync { _ = try? FileManager.default.removeItem(at: logURL) }
        defaults.set(true, forKey: key)
    }

    static func log(_ message: String) {
        q.async {
            let line = "\(timestampFormatter.string(from: Date())) \(message)\n"
            // Avoid distributed notifications — blocked in sandbox for helper.
            let url = logURL
            let fm = FileManager.default
            if let size = (try? fm.attributesOfItem(atPath: url.path))?[.size] as? UInt64, size > maxLogBytes {
                try? fm.removeItem(at: url)
            }
            if fm.fileExists(atPath: url.path) == false {
                _ = fm.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600])
            }
            do {
                let handle = try FileHandle(forWritingTo: url)
                defer { try? handle.close() }
                try handle.seekToEnd()
                if let data = line.data(using: .utf8) {
                    try handle.write(contentsOf: data)
                }
            } catch {
                // Swallow logging errors to avoid impacting MCP protocol
            }
        }
    }
}

// Intentionally no distributed notifications: sandboxed helper cannot post them.

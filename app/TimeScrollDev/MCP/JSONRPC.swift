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
enum MCPFileLogger {
    private static let q = DispatchQueue(label: "timescroll.mcp.logger")
    private static let appGroupID = "group.com.muzhen.TimeScroll.shared"

    static var logURL: URL {
        let fm = FileManager.default
        if let container = fm.containerURL(forSecurityApplicationGroupIdentifier: appGroupID) {
            let base = container.appendingPathComponent("Logs", isDirectory: true)
            if !fm.fileExists(atPath: base.path) {
                try? fm.createDirectory(at: base, withIntermediateDirectories: true)
            }
            return base.appendingPathComponent("timescroll-mcp.log")
        } else {
            // Fallback (may be sandbox-denied in helper, but ok in main app)
            let homeBase = fm.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Logs/TimeScroll", isDirectory: true)
            if !fm.fileExists(atPath: homeBase.path) {
                try? fm.createDirectory(at: homeBase, withIntermediateDirectories: true)
            }
            return homeBase.appendingPathComponent("timescroll-mcp.log")
        }
    }

    static func log(_ message: String) {
        q.async {
            let ts: String = {
                let f = ISO8601DateFormatter()
                f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                return f.string(from: Date())
            }()
            let line = "\(ts) \(message)\n"
            // Avoid distributed notifications — blocked in sandbox for helper.
            let url = logURL
            if FileManager.default.fileExists(atPath: url.path) == false {
                _ = FileManager.default.createFile(atPath: url.path, contents: nil)
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

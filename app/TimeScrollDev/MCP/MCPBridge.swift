import Foundation

/// Local IPC between the MCP helper (client) and the TimeScroll app (server). Each connection
/// carries one newline-terminated JSON request and one newline-terminated JSON response over a
/// Unix-domain socket that only the current user can open.
enum MCPBridge {
    static let helperBundleIdentifier = "com.muzhen.TimeScroll.mcp"
    static let appBundleIdentifier = "com.muzhen.TimeScroll"
    private static let maxMessageBytes = 64 * 1024 * 1024

    static var socketURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TimeScrollShared", isDirectory: true)
            .appendingPathComponent("mcp-bridge.sock")
    }

    struct SearchRequest: Codable {
        let query: String?
        let maxResults: Int
        let includeImages: Bool
        let startMs: Int64?
        let endMs: Int64?
        let textOnly: Bool
        let apps: [String]?
        let imageMaxPixel: Int?
    }

    struct SearchRow: Codable {
        let time: String
        let app: String
        let ocrText: String
        let imageJPEG: Data?
    }

    struct SearchResponse: Codable {
        let rows: [SearchRow]?
        let error: String?
    }

    static func socketAddress() throws -> sockaddr_un {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let path = Array(socketURL.path.utf8CString)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard path.count <= capacity else {
            throw NSError(domain: "TS.MCPBridge", code: 1, userInfo: [NSLocalizedDescriptionKey: "Socket path is too long."])
        }
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            path.withUnsafeBytes { raw.copyMemory(from: $0) }
        }
        return address
    }

    static func setTimeouts(_ fd: Int32, seconds: Int) {
        var timeout = timeval(tv_sec: seconds, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var noSigPipe: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
    }

    static func writeMessage<T: Encodable>(_ value: T, to fd: Int32) throws {
        var data = try JSONEncoder().encode(value)
        data.append(UInt8(ascii: "\n"))
        try data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let written = Darwin.write(fd, raw.baseAddress! + offset, raw.count - offset)
                if written < 0 {
                    if errno == EINTR { continue }
                    throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
                }
                offset += written
            }
        }
    }

    static func readMessage<T: Decodable>(_ type: T.Type, from fd: Int32) throws -> T {
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = Darwin.read(fd, &chunk, chunk.count)
            if count < 0 {
                if errno == EINTR { continue }
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [NSLocalizedDescriptionKey: "Timed out waiting for TimeScroll."])
            }
            if count == 0 { break }
            if let newline = chunk[0..<count].firstIndex(of: UInt8(ascii: "\n")) {
                buffer.append(contentsOf: chunk[0..<newline])
                break
            }
            buffer.append(contentsOf: chunk[0..<count])
            guard buffer.count <= maxMessageBytes else {
                throw NSError(domain: "TS.MCPBridge", code: 2, userInfo: [NSLocalizedDescriptionKey: "Message too large."])
            }
        }
        guard !buffer.isEmpty else {
            throw NSError(domain: "TS.MCPBridge", code: 3, userInfo: [NSLocalizedDescriptionKey: "Connection closed."])
        }
        return try JSONDecoder().decode(T.self, from: buffer)
    }
}

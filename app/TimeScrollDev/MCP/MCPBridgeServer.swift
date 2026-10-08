import Foundation

/// App side of the MCP bridge: accepts connections from the MCP helper and answers searches
/// using the app's own (already unlocked) database, so the helper never needs vault keys.
final class MCPBridgeServer {
    static let shared = MCPBridgeServer()
    private init() {}

    private static let ocrCharacterLimit = 50_000
    private let workQueue = DispatchQueue(label: "TimeScroll.MCPBridge", qos: .userInitiated, attributes: .concurrent)
    private var listenFD: Int32 = -1

    func start() {
        guard listenFD < 0 else { return }
        do {
            listenFD = try makeListeningSocket()
        } catch {
            fputs("[MCPBridge] could not listen: \(error.localizedDescription)\n", stderr)
            return
        }
        let fd = listenFD
        Thread.detachNewThread { [weak self] in
            while true {
                let client = accept(fd, nil, nil)
                if client < 0 {
                    if errno == EINTR { continue }
                    return // listening socket closed
                }
                self?.workQueue.async { self?.handle(client) }
            }
        }
    }

    func stop() {
        guard listenFD >= 0 else { return }
        close(listenFD)
        listenFD = -1
        unlink(MCPBridge.socketURL.path)
    }

    private func makeListeningSocket() throws -> Int32 {
        let url = MCPBridge.socketURL
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        unlink(url.path)
        var address = try MCPBridge.socketAddress()
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0, chmod(url.path, 0o600) == 0, listen(fd, 8) == 0 else {
            let code = errno
            close(fd)
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(code))
        }
        return fd
    }

    private func handle(_ fd: Int32) {
        defer { close(fd) }
        MCPBridge.setTimeouts(fd, seconds: 30)
        guard MCPBridgePeerVerifier.isTrusted(fd) else {
            try? MCPBridge.writeMessage(MCPBridge.SearchResponse(rows: nil, error: "Untrusted client."), to: fd)
            return
        }
        let response: MCPBridge.SearchResponse
        do {
            let request = try MCPBridge.readMessage(MCPBridge.SearchRequest.self, from: fd)
            response = search(request)
        } catch {
            response = MCPBridge.SearchResponse(rows: nil, error: error.localizedDescription)
        }
        try? MCPBridge.writeMessage(response, to: fd)
    }

    private func search(_ request: MCPBridge.SearchRequest) -> MCPBridge.SearchResponse {
        guard UserDefaults.standard.bool(forKey: "settings.mcpEnabled") else {
            return .init(rows: nil, error: "MCP tools are turned off. Enable them in TimeScroll ▸ Settings ▸ MCP.")
        }
        let args = SearchArgs(query: request.query,
                              maxResults: request.maxResults,
                              includeImages: request.includeImages,
                              startMs: request.startMs,
                              endMs: request.endMs,
                              textOnly: request.textOnly,
                              apps: request.apps,
                              imageMaxPixel: request.imageMaxPixel)
        let result = BlockingResult<[RowOut]>()
        Task.detached(priority: .userInitiated) {
            do {
                result.set(.success(try await SearchFacade().run(args, ocrLimit: Self.ocrCharacterLimit)))
            } catch {
                result.set(.failure(error))
            }
        }
        switch result.wait() {
        case .success(let rows):
            return .init(rows: rows.map { .init(time: $0.timeISO8601, app: $0.app, ocrText: $0.ocrText, imageJPEG: $0.imageJPEG) }, error: nil)
        case .failure(let error):
            let ns = error as NSError
            let locked = ns.domain == "TimeScroll.Vault"
            return .init(rows: nil, error: locked ? "The TimeScroll vault is locked. Unlock it in TimeScroll, then try again." : error.localizedDescription)
        }
    }
}

/// Hands an async result to a blocking caller on a background thread.
private final class BlockingResult<Value>: @unchecked Sendable {
    private let semaphore = DispatchSemaphore(value: 0)
    private var value: Result<Value, Error>?

    func set(_ value: Result<Value, Error>) {
        self.value = value
        semaphore.signal()
    }

    func wait() -> Result<Value, Error> {
        semaphore.wait()
        return value!
    }
}

import Foundation

/// Helper side of the MCP bridge: sends a search to the running TimeScroll app, launching it
/// in the background first if needed.
enum MCPBridgeClient {
    private static let launchWaitSeconds: Double = 20
    private static let responseTimeoutSeconds = 120

    static func search(_ request: MCPBridge.SearchRequest) throws -> MCPBridge.SearchResponse {
        let fd = try connectLaunchingAppIfNeeded()
        defer { close(fd) }
        MCPBridge.setTimeouts(fd, seconds: responseTimeoutSeconds)
        try MCPBridge.writeMessage(request, to: fd)
        return try MCPBridge.readMessage(MCPBridge.SearchResponse.self, from: fd)
    }

    private static func connectLaunchingAppIfNeeded() throws -> Int32 {
        if let fd = connect() { return fd }
        MCPFileLogger.log("bridge: app not reachable, launching TimeScroll")
        launchApp()
        let deadline = Date().addingTimeInterval(launchWaitSeconds)
        while Date() < deadline {
            Thread.sleep(forTimeInterval: 0.5)
            if let fd = connect() { return fd }
        }
        throw NSError(domain: "TS.MCPBridge", code: 10, userInfo: [NSLocalizedDescriptionKey: "TimeScroll is not running and could not be started. Open TimeScroll and try again."])
    }

    private static func connect() -> Int32? {
        guard var address = try? MCPBridge.socketAddress() else { return nil }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard connected == 0 else {
            close(fd)
            return nil
        }
        return fd
    }

    /// Opens the app hidden and in the background. Prefers the app bundle that contains this
    /// helper (TimeScroll.app/Contents/Helpers/timescroll-mcp.app).
    private static func launchApp() {
        let containingApp = Bundle.main.bundleURL
            .deletingLastPathComponent() // Helpers
            .deletingLastPathComponent() // Contents
            .deletingLastPathComponent() // TimeScroll.app
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        if containingApp.pathExtension == "app" {
            process.arguments = ["-g", "-j", containingApp.path]
        } else {
            process.arguments = ["-g", "-j", "-b", MCPBridge.appBundleIdentifier]
        }
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            MCPFileLogger.log("bridge: launch failed: \(error.localizedDescription)")
        }
    }
}

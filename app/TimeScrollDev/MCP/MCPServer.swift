import Foundation
import CoreSearch

struct InitializeResult: Encodable {
    let protocolVersion: String
    let capabilities: [String: AnyEncodable]
    let serverInfo: [String: String]
}

struct ToolsListResult: Encodable {
        struct Tool: Encodable {
            let name: String
            let title: String?
            let description: String
            let inputSchema: AnyEncodable
        }
    let tools: [Tool]
    let nextCursor: String? = nil
}

struct ToolsCallParams: Decodable {
    let name: String
    let arguments: AnyDecodable?
}

struct ToolCallResult: Encodable {
    let content: [AnyEncodable]?
    let isError: Bool?
}

final class MCPServer {
    private let io = LineIO()
    private let facade = SearchFacade()
    private let encoder = JSONEncoder()

    private func sendJSON<T: Encodable>(_ obj: T) {
        do {
            let data = try encoder.encode(obj)
            if let s = String(data: data, encoding: .utf8) {
                MCPFileLogger.log("out: \(s)")
                print(s)
            }
        } catch {
            fputs("[timescroll-mcp] encode error: \(error)\n", stderr)
        }
    }

    private func sendError(id: RPCID, code: Int, msg: String) {
        let err = RPCErrorResponse(id: id, error: RPCErrorObj(code: code, message: msg))
        sendJSON(err)
    }

    func run() {
        // Try to prime LA + SQLCipher immediately (non-fatal if it fails; we retry on first call).
        facade.primeVaultIfPossible()

        for line in io.lines() {
            MCPFileLogger.log("in: \(line)")
            guard let req = try? JSONDecoder().decode(RPCRequest.self, from: Data(line.utf8)) else {
                fputs("[timescroll-mcp] bad JSON\n", stderr)
                MCPFileLogger.log("bad JSON input: \(line.prefix(256))…")
                continue
            }
            // Handle notifications (no id) so clients don't think we're unresponsive
            if req.id == nil {
                if req.method.hasPrefix("notifications/") {
                    MCPFileLogger.log("note: \(req.method)")
                    continue
                } else {
                    // Unknown request without id; ignore
                    continue
                }
            }
            guard let id = req.id else { continue }

            switch req.method {
            case "initialize":
                MCPFileLogger.log("initialize request id=\(id)")
                let caps: [String: AnyEncodable] = ["tools": AnyEncodable(["listChanged": false])]
                let res = InitializeResult(protocolVersion: "2024-11-05",
                                           capabilities: caps,
                                           serverInfo: ["name":"timescroll-mcp","version":"0.1.0"])
                sendJSON(RPCResponse(id: id, result: res))
                MCPFileLogger.log("initialize response sent")

            case "tools/list":
                MCPFileLogger.log("tools/list id=\(id)")
                sendJSON(RPCResponse(id: id, result: toolsList()))
                MCPFileLogger.log("tools/list responded")

            case "tools/call":
                guard let params = try? decodeArgs(ToolsCallParams.self, req.params) else {
                    sendError(id: id, code: -32602, msg: "Invalid params"); continue
                }
                MCPFileLogger.log("tools/call id=\(id) name=\(params.name)")
                switch params.name {
                case "search_timescroll":
                    Task { await handleSearch(id: id, argsAny: params.arguments) }
                default: sendError(id: id, code: -32601, msg: "Unknown tool")
                }

            default:
                MCPFileLogger.log("method not found id=\(id) method=\(req.method)")
                sendError(id: id, code: -32601, msg: "Method not found")
            }
        }
    }

    private func toolsList() -> ToolsListResult {
        ToolsListResult(tools: [
            .init(
                name: "search_timescroll",
                title: "Search TimeScroll",
                description: """
                    Search through the TimeScroll Mac app's database. The database contains many screenshots from the user's Mac over time,
                    allowing the tool to accurately find past activities based on text content.
                    The tool will search through OCR text extracted from the screenshots.
                    """,
                inputSchema: AnyEncodable(Schemas.searchInput)
            )
        ])
    }

    private func handleSearch(id: RPCID, argsAny: AnyDecodable?) async {
        // Ensure DB is open; if not, attempt LA and retry open.
        if !facade.tryOpenDB() {
            let (unlocked, errMsg) = await facade.unlockAndOpenIfNeeded()
            if !unlocked {
                let msg = errMsg ?? "Unlock required. Please authenticate to access the vault."
                let err = ToolCallResult(
                    content: [ AnyEncodable(["type":"text","text":msg]) ],
                    isError: true
                )
                sendJSON(RPCResponse(id: id, result: err))
                MCPFileLogger.log("tools/call search_timescroll id=\(id) denied: \(msg)")
                return
            }
        }

        do {
            // log DB diagnostics
            let diag = facade.diagnostics()
            MCPFileLogger.log("db=\(diag.path ?? "(nil)") snapshots=\(diag.count)")

            let a = parseSearchArgs(argsAny)
            let t0 = Date()
            MCPFileLogger.log("search start id=\(id) q=\(a.query ?? "") limit=\(a.maxResults) imgs=\(a.includeImages) apps=\(a.apps?.count ?? 0)")
            let rows = try await facade.run(a, ocrLimit: 50_000)
            let dt = String(format: "%.2fs", Date().timeIntervalSince(t0))

            // Build content[] with a per-row text item (stringified JSON) followed
            // optionally by an image item for that row.
            var content: [AnyEncodable] = []
            for r in rows {
                let willHaveImage = a.includeImages && (r.imagePNG != nil)

                let rowObj: [String: Any] = [
                    "time": r.timeISO8601,
                    "app": r.app,
                    "ocr_text": r.ocrText,
                    "has_image": willHaveImage
                ]

                let rowData = try JSONSerialization.data(withJSONObject: rowObj, options: [])
                let rowJSON = String(data: rowData, encoding: .utf8) ?? "{}"

                // Text entry contains the stringified JSON for the row
                content.append(AnyEncodable(["type": "text", "text": rowJSON]))

                if willHaveImage, let png = r.imagePNG {
                    content.append(AnyEncodable([
                        "type": "image",
                        "data": png.base64EncodedString(),
                        "mimeType": "image/png"
                    ]))
                }
            }

            let resp = ToolCallResult(content: content.isEmpty ? nil : content, isError: nil)
            sendJSON(RPCResponse(id: id, result: resp))
            MCPFileLogger.log("search done id=\(id) results=\(rows.count) time=\(dt)")
        } catch {
            let resp = ToolCallResult(content: [AnyEncodable(["type":"text","text":"Search failed: \(error.localizedDescription)"])], isError: true)
            sendJSON(RPCResponse(id: id, result: resp))
            MCPFileLogger.log("search error id=\(id) err=\(error.localizedDescription)")
        }
    }

    private func parseSearchArgs(_ any: AnyDecodable?) -> SearchArgs {
        let d = any?.value as? [String: Any] ?? [:]
        let query = d["query"] as? String
        let maxResults = max(1, min(100, (d["max_results"] as? Int) ?? 20))
        let includeImages = (d["include_images"] as? Bool) ?? true
        let textOnly = (d["text_only"] as? Bool) ?? false
        var startMs: Int64? = nil, endMs: Int64? = nil
        if let dr = d["date_range"] as? [String: Any] {
            let f = ISO8601DateFormatter()
            if let s = dr["from"] as? String, let dt = f.date(from: s) { startMs = Int64(dt.timeIntervalSince1970 * 1000) }
            if let s = dr["to"]   as? String, let dt = f.date(from: s) { endMs   = Int64(dt.timeIntervalSince1970 * 1000) }
        }
        let apps = (d["apps"] as? [String]).flatMap { $0.isEmpty ? nil : $0 }
        // MCP defaults to larger images so clients get higher-res by default
        let imgMax = (d["image_max_pixel"] as? Int) ?? 2048
        return SearchArgs(query: query, maxResults: maxResults, includeImages: includeImages,
                  startMs: startMs, endMs: endMs, textOnly: textOnly, apps: apps,
                  imageMaxPixel: imgMax)
    }

    // No direct vault helpers here; delegated to CoreSearch.SearchFacade
}

private func decodeArgs<T: Decodable>(_ t: T.Type, _ any: AnyDecodable?) throws -> T {
    let d = any?.value as? [String: Any] ?? [:]
    let data = try JSONSerialization.data(withJSONObject: d, options: [])
    return try JSONDecoder().decode(T.self, from: data)
}
// End of file

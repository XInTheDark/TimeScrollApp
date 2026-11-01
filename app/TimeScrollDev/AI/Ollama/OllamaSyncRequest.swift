import Foundation

/// Blocking HTTP calls to the local Ollama server. Callers run on background queues.
enum OllamaSyncRequest {
    static func perform(_ request: URLRequest, timeout: TimeInterval, label: String) -> Data? {
        // A kept-alive connection dies when Ollama restarts or the Mac sleeps; the first request
        // on it fails with "connection lost" although the server is up again.
        var attempt = 0
        while true {
            attempt += 1
            switch performOnce(request, timeout: timeout, label: label) {
            case .success(let data):
                return data
            case .connectionLost where attempt < 2:
                print("[Ollama] \(label) connection lost, retrying")
            case .connectionLost, .failure:
                return nil
            }
        }
    }

    private enum Outcome {
        case success(Data)
        case connectionLost
        case failure
    }

    private static func performOnce(_ request: URLRequest, timeout: TimeInterval, label: String) -> Outcome {
        var data: Data?
        var requestError: Error?
        var statusCode: Int?
        let semaphore = DispatchSemaphore(value: 0)
        let task = URLSession.shared.dataTask(with: request) { responseData, response, error in
            data = responseData
            requestError = error
            statusCode = (response as? HTTPURLResponse)?.statusCode
            semaphore.signal()
        }
        task.resume()

        if semaphore.wait(timeout: .now() + timeout) == .timedOut {
            task.cancel()
            print("[Ollama] \(label) timed out after \(String(format: "%.1f", timeout))s")
            return .failure
        }

        if let requestError {
            print("[Ollama] \(label) error: \(requestError)")
            return (requestError as? URLError)?.code == .networkConnectionLost ? .connectionLost : .failure
        }

        guard let data else {
            print("[Ollama] No data received for \(label)")
            return .failure
        }
        if let statusCode, !(200..<300).contains(statusCode) {
            let body = String(data: data.prefix(300), encoding: .utf8) ?? ""
            print("[Ollama] \(label) HTTP \(statusCode): \(body)")
            return .failure
        }
        return .success(data)
    }

    static func get(_ url: URL, timeout: TimeInterval, label: String) -> Data? {
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        return perform(request, timeout: timeout, label: label)
    }

    static func postJSON(_ url: URL, payload: [String: Any], timeout: TimeInterval, label: String) -> Data? {
        guard let body = try? JSONSerialization.data(withJSONObject: payload) else {
            print("[Ollama] Failed to serialize \(label) request")
            return nil
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = timeout
        request.httpBody = body
        return perform(request, timeout: timeout, label: label)
    }
}

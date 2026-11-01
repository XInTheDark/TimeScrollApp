import Foundation
import Testing
@testable import TimeScroll

/// Scripted responses for `URLSession.shared`, keyed by the `.test` host so other tests are unaffected.
private final class ScriptedOllamaProtocol: URLProtocol {
    nonisolated(unsafe) static var script: [Result<Data, URLError>] = []
    nonisolated(unsafe) static var requestCount = 0
    private static let lock = NSLock()

    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "ollama-scripted.test" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        Self.lock.lock()
        Self.requestCount += 1
        let next = Self.script.isEmpty ? .failure(URLError(.cannotConnectToHost)) : Self.script.removeFirst()
        Self.lock.unlock()
        switch next {
        case .success(let data):
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        case .failure(let error):
            client?.urlProtocol(self, didFailWithError: error)
        }
    }
}

@Suite(.serialized)
struct OllamaSyncRequestTests {
    private let url = URL(string: "http://ollama-scripted.test/api/tags")!

    private func run(_ script: [Result<Data, URLError>]) -> (data: Data?, requests: Int) {
        URLProtocol.registerClass(ScriptedOllamaProtocol.self)
        defer { URLProtocol.unregisterClass(ScriptedOllamaProtocol.self) }
        ScriptedOllamaProtocol.script = script
        ScriptedOllamaProtocol.requestCount = 0
        let data = OllamaSyncRequest.get(url, timeout: 3, label: "unit test")
        return (data, ScriptedOllamaProtocol.requestCount)
    }

    @Test func retries_once_after_a_lost_connection() {
        let payload = Data("{}".utf8)
        let result = run([.failure(URLError(.networkConnectionLost)), .success(payload)])
        #expect(result.data == payload)
        #expect(result.requests == 2)
    }

    @Test func gives_up_after_one_retry() {
        let result = run([.failure(URLError(.networkConnectionLost)), .failure(URLError(.networkConnectionLost))])
        #expect(result.data == nil)
        #expect(result.requests == 2)
    }

    @Test func does_not_retry_when_the_server_is_down() {
        let result = run([.failure(URLError(.cannotConnectToHost))])
        #expect(result.data == nil)
        #expect(result.requests == 1)
    }

    @Test func succeeds_without_retry() {
        let payload = Data("{}".utf8)
        let result = run([.success(payload)])
        #expect(result.data == payload)
        #expect(result.requests == 1)
    }
}

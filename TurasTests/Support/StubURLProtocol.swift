import Foundation

/// A URLProtocol that answers every request with a canned response and
/// records the requests it saw. Use `StubURLProtocol.session()` to get a
/// URLSession routed through it, and `StubURLProtocol.stub` to set the
/// response for the current test.
final class StubURLProtocol: URLProtocol {
    static let stub = StubResponses()

    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        let (statusCode, body) = StubURLProtocol.stub.respond(to: request)
        guard let url = request.url,
              let response = HTTPURLResponse(
                url: url,
                statusCode: statusCode,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
              ) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

/// Thread-safe canned response and request log for StubURLProtocol.
final class StubResponses: @unchecked Sendable {
    private let lock = NSLock()
    private var statusCode = 200
    private var body = Data("[]".utf8)
    private var requests: [URLRequest] = []

    func set(statusCode: Int = 200, body: Data) {
        lock.lock()
        defer { lock.unlock() }
        self.statusCode = statusCode
        self.body = body
        self.requests = []
    }

    func respond(to request: URLRequest) -> (Int, Data) {
        lock.lock()
        defer { lock.unlock() }
        requests.append(request)
        return (statusCode, body)
    }

    var recordedRequests: [URLRequest] {
        lock.lock()
        defer { lock.unlock() }
        return requests
    }
}

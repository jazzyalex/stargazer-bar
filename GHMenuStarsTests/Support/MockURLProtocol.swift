import Foundation

final class MockURLProtocol: URLProtocol {
    struct Response {
        var statusCode: Int = 200
        var headers: [String: String] = [:]
        var data: Data
    }

    /// Takes precedence over `responses` when set. `responses` is keyed by
    /// path, so it cannot answer the same path differently on successive calls —
    /// which the 404-then-retry-with-PAT tests require.
    static var handler: ((URLRequest) -> Response?)?

    static var responses: [String: Response] = [:]
    static var requestedPaths: [String] = []
    static var requestedAccepts: [String] = []
    static var requestedAuthorizations: [String?] = []
    private static let lock = NSLock()

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }

        let key = Self.pathAndQuery(for: url)
        Self.lock.lock()
        Self.requestedPaths.append(key)
        Self.requestedAccepts.append(request.value(forHTTPHeaderField: "Accept") ?? "")
        Self.requestedAuthorizations.append(request.value(forHTTPHeaderField: "Authorization"))
        Self.lock.unlock()

        let resolved = Self.handler?(request) ?? Self.responses[key]
        guard let response = resolved,
              let httpResponse = HTTPURLResponse(
                url: url,
                statusCode: response.statusCode,
                httpVersion: nil,
                headerFields: response.headers
              ) else {
            client?.urlProtocol(self, didFailWithError: URLError(.resourceUnavailable))
            return
        }

        client?.urlProtocol(self, didReceive: httpResponse, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: response.data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    static func reset() {
        lock.lock()
        defer { lock.unlock() }
        handler = nil
        responses = [:]
        requestedPaths = []
        requestedAccepts = []
        requestedAuthorizations = []
    }

    private static func pathAndQuery(for url: URL) -> String {
        if let query = url.query {
            return "\(url.path)?\(query)"
        }
        return url.path
    }
}

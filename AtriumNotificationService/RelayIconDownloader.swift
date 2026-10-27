import Foundation

nonisolated final class RelayIconDownloader: NSObject, URLSessionTaskDelegate {
    static func trustedURL(_ value: String, hostID: String) -> URL? {
        guard hostID.range(of: #"^[A-Za-z0-9_-]{16,64}$"#, options: .regularExpression) != nil,
              let parts = URLComponents(string: value),
              parts.scheme == "https", parts.host == "atrium-relay.lynksphere.com",
              parts.port == nil, parts.user == nil, parts.password == nil,
              parts.query == nil, parts.fragment == nil else { return nil }

        let route = parts.percentEncodedPath.split(separator: "/", omittingEmptySubsequences: false)
        guard route.count == 5, route[0].isEmpty, route[1] == "v1", route[2] == "icon",
              route[3] == hostID, UUID(uuidString: String(route[4])) != nil else { return nil }
        return parts.url
    }

    static func download(from url: URL) async throws -> Data {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 6
        configuration.timeoutIntervalForResource = 8
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        let session = URLSession(configuration: configuration, delegate: RelayIconDownloader(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }

        var request = URLRequest(url: url)
        request.setValue("image/png", forHTTPHeaderField: "Accept")
        let (bytes, response) = try await session.bytes(for: request)
        let limit = 64 * 1024
        guard let response = response as? HTTPURLResponse,
              response.statusCode == 200, response.url == url,
              response.mimeType == "image/png",
              response.expectedContentLength <= Int64(limit) else {
            throw URLError(.badServerResponse)
        }

        var data = Data()
        for try await byte in bytes {
            try Task.checkCancellation()
            guard data.count < limit else { throw URLError(.dataLengthExceedsMaximum) }
            data.append(byte)
        }
        return data
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        // Capability URLs must never redirect, including to another relay path.
        completionHandler(nil)
    }
}

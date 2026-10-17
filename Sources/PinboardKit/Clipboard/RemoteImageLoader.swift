import AppKit

/// Loads the bytes of an image referenced by pasted HTML.
///
/// Completions are always delivered on the main thread. Tests inject their own
/// conformance so no test ever touches the network.
protocol RemoteImageFetching {
    /// Fetches `url`; `completion(nil)` covers every failure — bad status,
    /// transport error, oversized payload.
    func fetch(_ url: URL, completion: @escaping (Data?) -> Void)
}

/// Production loader. A pasted message must not hang on a dead host, so the
/// request times out quickly, and a single oversized asset is discarded rather
/// than kept in memory.
///
/// The session is ephemeral and never sends cookies: a copied URL may point at
/// a host the user is signed in to, and pasting a message must not leak that
/// session to a third-party CDN.
final class RemoteImageLoader: RemoteImageFetching {
    static let shared = RemoteImageLoader()

    let session: URLSession
    private let maximumBytes: Int

    init(maximumBytes: Int = 20 * 1024 * 1024) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.timeoutIntervalForRequest = 8
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        session = URLSession(configuration: configuration)
        self.maximumBytes = maximumBytes
    }

    /// Test seam: any custom session can be injected.
    init(session: URLSession, maximumBytes: Int = 20 * 1024 * 1024) {
        self.session = session
        self.maximumBytes = maximumBytes
    }

    func fetch(_ url: URL, completion: @escaping (Data?) -> Void) {
        guard url.scheme == "http" || url.scheme == "https" else {
            completion(nil)
            return
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 8
        session.dataTask(with: request) { [maximumBytes] data, response, error in
            var result: Data?
            if error == nil,
               let http = response as? HTTPURLResponse, http.statusCode == 200,
               let data, data.count <= maximumBytes {
                result = data
            }
            DispatchQueue.main.async { completion(result) }
        }.resume()
    }
}

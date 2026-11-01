import AppKit
import SafeImageDownload

protocol RemoteImageFetching {
    /// Main-thread completion. nil means the image is unavailable; the display
    /// boundary deliberately keeps alt text while canonical source stays intact.
    func fetch(_ url: URL, completion: @escaping (Data?) -> Void)
}

/// Bounded image downloads. DNS answers are validated at socket creation (also
/// after redirects), never by a racy preflight lookup. No cookies, credentials
/// or environment proxies are used. The byte limit is enforced while receiving.
final class RemoteImageLoader: RemoteImageFetching {
    static let shared = RemoteImageLoader()

    struct DownloadError: Error {
        let code: Int32
    }

    private let maximumBytes: Int
    private let download: (URL, Int) throws -> Data
    private let queue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "Pinboard image downloads"
        queue.maxConcurrentOperationCount = 4
        queue.qualityOfService = .userInitiated
        return queue
    }()
    private var pending: [URL: [(Data?) -> Void]] = [:]
    private let cache: NSCache<NSURL, NSData> = {
        let cache = NSCache<NSURL, NSData>()
        cache.countLimit = 64
        cache.totalCostLimit = 32 * 1024 * 1024
        return cache
    }()

    init(maximumBytes: Int = 20 * 1024 * 1024,
         download: @escaping (URL, Int) throws -> Data = RemoteImageLoader.download) {
        precondition(maximumBytes > 0)
        self.maximumBytes = maximumBytes
        self.download = download
    }

    private static func download(_ url: URL, limit: Int) throws -> Data {
        var bytes: UnsafeMutablePointer<UInt8>?
        var length = 0
        let code = pinboard_download_image(url.absoluteString, limit, &bytes, &length)
        guard code == 0 else { throw DownloadError(code: code) }
        guard let bytes else { return Data() }
        return Data(bytesNoCopy: bytes, count: length, deallocator: .free)
    }

    func fetch(_ url: URL, completion: @escaping (Data?) -> Void) {
        if !Thread.isMainThread {
            DispatchQueue.main.async { self.fetch(url, completion: completion) }
            return
        }
        guard ["http", "https"].contains(url.scheme?.lowercased()),
              url.host != nil, url.user == nil, url.password == nil else {
            completion(nil)
            return
        }
        if let cached = cache.object(forKey: url as NSURL) {
            completion(cached as Data)
            return
        }
        if pending[url] != nil {
            // Re-renders share a request instead of spawning duplicate work.
            guard pending[url]!.count < 64 else {
                NSLog("Pinboard image request has too many waiting displays")
                completion(nil)
                return
            }
            pending[url]!.append(completion)
            return
        }
        guard pending.count < 64 else {
            NSLog("Pinboard image queue is full")
            completion(nil)
            return
        }
        pending[url] = [completion]
        queue.addOperation { [self] in
            let result: Result<Data, Error> = Result {
                let data = try download(url, maximumBytes)
                guard data.count <= maximumBytes else { throw DownloadError(code: 63) }
                return data
            }
            DispatchQueue.main.async { [self] in
                let data: Data?
                switch result {
                case .success(let bytes):
                    cache.setObject(bytes as NSData, forKey: url as NSURL, cost: bytes.count)
                    data = bytes
                case .failure(let error):
                    // Display-only recovery: callers show alt text; history and
                    // the Markdown source keep the URL for a later retry.
                    NSLog("Pinboard image download failed: %@", String(describing: error))
                    data = nil
                }
                let callbacks = pending.removeValue(forKey: url)!
                callbacks.forEach { $0(data) }
            }
        }
    }
}

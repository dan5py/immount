import Foundation

public enum ImmichError: Error, Equatable, LocalizedError {
    case invalidServerURL
    /// 401: the key is wrong, revoked or missing.
    case unauthorized
    /// 403: the key is valid but lacks a permission. Carries the server's message.
    case missingPermission(String?)
    case notFound
    /// The server answered with a redirect to another host or to plain HTTP, which Immount does
    /// not follow because the API key would go along.
    case redirected
    case http(status: Int, message: String?)
    case invalidResponse

    public var errorDescription: String? {
        switch self {
        case .invalidServerURL: "The server URL is not valid."
        case .unauthorized: "The server did not accept the API key."
        case .missingPermission(let message): message.map { "The API key is not allowed to do this (\($0))." } ?? "The API key is missing a permission."
        case .notFound: "The item no longer exists on the server."
        case .redirected: "The server redirected Immount to another address. Use the final address, including https, as the server URL."
        case .http(let status, let message): message.map { "Server error \(status): \($0)" } ?? "Server error \(status)."
        case .invalidResponse: "The server sent a response Immount could not read."
        }
    }
}

extension URLError {
    /// Errors that mean the server cannot be reached right now.
    public var isUnreachable: Bool {
        isConnectionFailure || code == .timedOut
    }

    /// The address could not be connected to at all, so another address may work. A timeout is
    /// not one: a slow server (a NAS spinning up its disks) is still the right server.
    var isConnectionFailure: Bool {
        switch code {
        case .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed, .networkConnectionLost, .notConnectedToInternet:
            true
        default:
            false
        }
    }
}

/// Thin async client for the Immich REST API, authenticated with an API key.
public struct ImmichClient: Sendable {
    private let endpoints: @Sendable () -> [URL]
    private let apiKey: String
    private let session: URLSession
    private let versionCache: Memo<ImmichServerVersion>
    private let downloadStatistics: DownloadStatisticsStore?
    private let metadataCache: MetadataResponseCache
    private let metadataScope: String

    /// Seconds to wait for a fallback-capable address to answer a ping.
    static let probeTimeout: TimeInterval = 3

    /// The server root requests go to first.
    public var serverURL: URL { endpoints()[0] }

    public init(serverURL: URL, apiKey: String, session: URLSession = ImmichSession.shared,
                metadataCache: MetadataResponseCache = MetadataResponseCache()) {
        self.init(apiKey: apiKey, session: session, metadataCache: metadataCache) { [serverURL] }
    }

    /// A client whose addresses are resolved on every request, in order of preference, so it
    /// can follow the local and remote address while the extension keeps running. When an
    /// address cannot be reached, the request is retried on the next one.
    public init(apiKey: String, session: URLSession = ImmichSession.shared,
                metadataCache: MetadataResponseCache = MetadataResponseCache(), endpoints: @escaping @Sendable () -> [URL]) {
        self.init(apiKey: apiKey, session: session, versionCache: Self.makeVersionCache(),
                  metadataCache: metadataCache, endpoints: endpoints)
    }

    /// The version is remembered for an hour: long enough to skip asking before every search,
    /// short enough to notice a server upgrade.
    static func makeVersionCache() -> Memo<ImmichServerVersion> {
        Memo(lifetime: 60 * 60)
    }

    init(apiKey: String, session: URLSession, versionCache: Memo<ImmichServerVersion>,
         downloadStatistics: DownloadStatisticsStore? = nil, metadataCache: MetadataResponseCache = MetadataResponseCache(),
         metadataScope: String = "",
         endpoints: @escaping @Sendable () -> [URL]) {
        self.endpoints = endpoints
        self.apiKey = apiKey
        self.session = session
        self.versionCache = versionCache
        self.downloadStatistics = downloadStatistics
        self.metadataCache = metadataCache
        self.metadataScope = metadataScope
    }

    /// Accepts what users paste: `photos.example.com`, `http://10.0.0.5:2283/`,
    /// or a URL ending in `/api`. Returns the server root without `/api`.
    /// URLs with embedded credentials are rejected so they never end up in settings.
    public static func normalizeServerURL(_ input: String) -> URL? {
        var text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if !text.contains("://") { text = "https://" + text }
        while text.hasSuffix("/") { text.removeLast() }
        if text.hasSuffix("/api") { text.removeLast(4) }
        guard let url = URL(string: text), let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https", url.host() != nil,
              url.user() == nil, url.password() == nil else {
            return nil
        }
        return url
    }

    // MARK: Endpoints

    /// Public reachability check of the first address. Sent without the key.
    public func ping(timeout: TimeInterval? = nil) async throws {
        try await ping(base: serverURL, timeout: timeout)
    }

    private func ping(base: URL, timeout: TimeInterval?) async throws {
        struct Pong: Decodable { var res: String }
        let data = try await data(for: keylessRequest("server/ping", base: base, timeout: timeout))
        guard (try? Self.decoder.decode(Pong.self, from: data)) != nil else { throw ImmichError.invalidResponse }
    }

    /// The server URL with `http` upgraded to `https` when the server redirects there, so the
    /// key is never sent in plain text. Checked without the key.
    public func upgradedServerURL() async -> URL {
        let base = serverURL
        guard base.scheme?.lowercased() == "http",
              let (_, response) = try? await session.data(for: keylessRequest("server/ping", base: base, timeout: 10)),
              let final = response.url, final.scheme?.lowercased() == "https",
              final.host()?.lowercased() == base.host()?.lowercased(),
              var components = URLComponents(url: base, resolvingAgainstBaseURL: false) else { return base }
        components.scheme = "https"
        components.port = final.port
        return components.url ?? base
    }

    private func keylessRequest(_ path: String, base: URL, timeout: TimeInterval?) -> URLRequest {
        var request = request(path, base: base, timeout: timeout)
        request.setValue(nil, forHTTPHeaderField: "x-api-key")
        return request
    }

    /// The key's name and permissions. Needs no permission, so it works for any valid key.
    public func apiKeyInfo() async throws -> ImmichAPIKey {
        try await get("api-keys/me")
    }

    public func currentUser() async throws -> ImmichUser {
        try await get("users/me")
    }

    public func serverVersion() async throws -> ImmichServerVersion {
        let version: ImmichServerVersion = try await get("server/version")
        versionCache.store(version)
        return version
    }

    private func cachedServerVersion() async throws -> ImmichServerVersion {
        try await versionCache.value { try await self.get("server/version") as ImmichServerVersion }
    }

    public func albums() async throws -> [ImmichAlbum] {
        try await getMetadata("albums")
    }

    public func album(id: String) async throws -> ImmichAlbum {
        // `withoutAssets` is ignored since Immich 3.0, which never includes assets; 2.x needs it.
        try await get("albums/\(id)", query: [URLQueryItem(name: "withoutAssets", value: "true")])
    }

    public func person(id: String) async throws -> ImmichPerson {
        try await get("people/\(id)")
    }

    /// All visible people, across every page.
    public func people() async throws -> [ImmichPerson] {
        var result: [ImmichPerson] = []
        var page = 1
        while true {
            let response: ImmichPeoplePage = try await getMetadata("people", query: [
                URLQueryItem(name: "withHidden", value: "false"),
                URLQueryItem(name: "page", value: String(page)),
                URLQueryItem(name: "size", value: "1000"),
            ])
            result += response.people
            guard response.hasNextPage == true, !response.people.isEmpty else { return result }
            page += 1
        }
    }

    /// Every tag, including children. Immich returns a flat array without pagination;
    /// `parentId` and `value` describe the hierarchy.
    public func tags() async throws -> [ImmichTag] {
        try await getMetadata("tags")
    }

    public func tag(id: String) async throws -> ImmichTag {
        try await get("tags/\(id)")
    }

    /// Month buckets of the user's own main timeline (archived and hidden assets excluded).
    /// Immich marks this endpoint internal, so only the `yyyy-MM` prefix is relied on.
    public func timeBuckets() async throws -> [ImmichTimeBucket] {
        try await getMetadata("timeline/buckets", query: [URLQueryItem(name: "visibility", value: "timeline")])
    }

    /// Runs a metadata search and follows pagination until every result is loaded,
    /// in the request shape the server's version understands.
    public func searchAssets(_ query: AssetQuery) async throws -> [ImmichAsset] {
        try await searchAssets(query, retryOnVersionChange: true)
    }

    private func searchAssets(_ query: AssetQuery, retryOnVersionChange: Bool) async throws -> [ImmichAsset] {
        let version = try await cachedServerVersion()
        if version.isAtLeast(major: 3, minor: 2) {
            var result: [ImmichAsset] = []
            var cursor: String?
            repeat {
                let page = try await search(FilterSearchBody(query: query, cursor: cursor))
                guard page.hasCursorField else {
                    // An older server ignored the filter; the remembered version is out of date.
                    versionCache.reset()
                    guard retryOnVersionChange else { throw ImmichError.invalidResponse }
                    return try await searchAssets(query, retryOnVersionChange: false)
                }
                result += page.items
                cursor = page.nextCursor
            } while cursor != nil
            return result
        }
        if version.major < 3, query.visibility == nil {
            // Immich 2 searches only the timeline unless told otherwise, and takes one visibility.
            var timeline = query
            timeline.visibility = "timeline"
            var archive = query
            archive.visibility = "archive"
            return try await legacySearch(timeline) + legacySearch(archive)
        }
        return try await legacySearch(query)
    }

    /// The assets of an album. Immich 2 searches only the user's own assets, so it lists the
    /// album itself, which includes what other members added.
    public func albumAssets(id: String) async throws -> [ImmichAsset] {
        if try await cachedServerVersion().major < 3 {
            struct AlbumWithAssets: Decodable { var assets: [ImmichAsset]? }
            let album: AlbumWithAssets = try await get("albums/\(id)", query: [URLQueryItem(name: "withoutAssets", value: "false")])
            if let assets = album.assets { return assets }
            // Immich 3 no longer includes assets: the server was upgraded since its version was read.
            versionCache.reset()
        }
        return try await searchAssets(AssetQuery(albumIDs: [id]))
    }

    private func legacySearch(_ query: AssetQuery) async throws -> [ImmichAsset] {
        var result: [ImmichAsset] = []
        var page = 1
        while true {
            let response: ImmichSearchResponse.Assets
            do {
                response = try await search(LegacySearchBody(query, page: page))
            } catch ImmichError.http(400, let message) {
                // A server that dropped the old fields after an upgrade; ask for its version again.
                versionCache.reset()
                throw ImmichError.http(status: 400, message: message)
            }
            result += response.items
            guard let next = response.nextPage.flatMap(Int.init) else { return result }
            page = next
        }
    }

    /// The original file, as uploaded. Its bytes match the asset checksum and size.
    public func originalRequest(assetID: String, base: URL, timeout: TimeInterval? = nil) -> URLRequest {
        request("assets/\(assetID)/original", base: base, timeout: timeout)
    }

    /// Downloads the original to `destination`, reporting into `progress` (out of its
    /// `totalUnitCount`). Cancelling the calling task cancels the download.
    public func downloadOriginal(assetID: String, to destination: URL, progress: Progress? = nil) async throws {
        try await withFallback { base in
            let request = originalRequest(assetID: assetID, base: base)
            let measurement = downloadStatistics.flatMap(DownloadMeasurement.init)
            defer { measurement?.finish(success: false) }
            let (location, response) = try await session.download(for: request, delegate: DownloadProgress(progress, measurement: measurement))
            defer { try? FileManager.default.removeItem(at: location) }
            // Error bodies are small JSON; read them so 400/404 map like any other request.
            let isSuccess = (response as? HTTPURLResponse).map { (200..<300).contains($0.statusCode) } ?? false
            try Self.validate(response, data: isSuccess ? nil : try? Data(contentsOf: location))
            let bytes = (try? location.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init)
            try FileManager.default.moveItem(at: location, to: destination)
            measurement?.finish(success: true, bytes: bytes)
        }
    }

    /// `thumbnail` is a ~250px WebP, `preview` a ~1440px JPEG.
    public func thumbnail(assetID: String, large: Bool) async throws -> Data {
        try await withFallback { base in
            try await data(for: request(
                "assets/\(assetID)/thumbnail",
                query: [URLQueryItem(name: "size", value: large ? "preview" : "thumbnail")],
                base: base
            ))
        }
    }

    // MARK: Plumbing

    /// Runs `operation` against each address in turn. An address with another one after it
    /// is pinged first (the answer is remembered for 30 seconds), so a local server that is
    /// down costs a few seconds once instead of a timeout per request. Once a request is sent,
    /// only a failure to connect moves on; a slow answer is waited for.
    public func withFallback<T>(_ operation: (_ base: URL) async throws -> T) async throws -> T {
        let bases = endpoints()
        for (index, base) in bases.enumerated() {
            let isLast = index == bases.count - 1
            if !isLast, await !isReachable(base) { continue }
            do {
                return try await operation(base)
            } catch let error as URLError where !isLast && error.isConnectionFailure {
                Reachability.shared.record(base, reachable: false)
            }
        }
        throw URLError(.cannotFindHost)
    }

    private func isReachable(_ base: URL) async -> Bool {
        if let cached = Reachability.shared.cached(base) { return cached }
        let reachable = (try? await ping(base: base, timeout: Self.probeTimeout)) != nil
        Reachability.shared.record(base, reachable: reachable)
        return reachable
    }

    public func request(
        _ path: String,
        method: String = "GET",
        query: [URLQueryItem] = [],
        body: Data? = nil,
        base: URL? = nil,
        timeout: TimeInterval? = nil
    ) -> URLRequest {
        var url = (base ?? serverURL).appending(path: "api").appending(path: path)
        if !query.isEmpty { url.append(queryItems: query) }
        var request = URLRequest(url: url)
        request.httpMethod = method
        if !apiKey.isEmpty { request.setValue(apiKey, forHTTPHeaderField: "x-api-key") }
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let timeout { request.timeoutInterval = timeout }
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return request
    }

    public func data(for request: URLRequest) async throws -> Data {
        let (data, response) = try await session.data(for: request)
        try Self.validate(response, data: data)
        return data
    }

    private func search(_ body: some Encodable) async throws -> ImmichSearchResponse.Assets {
        let data = try Self.encoder.encode(body)
        let response: ImmichSearchResponse = try await send(path: "search/metadata", method: "POST", body: data)
        return response.assets
    }

    private func get<T: Decodable>(_ path: String, query: [URLQueryItem] = []) async throws -> T {
        try await send(path: path, query: query)
    }

    /// Only the explicitly selected metadata indexes use conditional requests. Cache hits
    /// never bypass authentication or a network failure, and each fallback URL has its own key.
    private func getMetadata<T: Decodable & Sendable>(_ path: String, query: [URLQueryItem] = []) async throws -> T {
        try await withFallback { base in
            var request = request(path, query: query, base: base)
            request.cachePolicy = .reloadIgnoringLocalCacheData
            let lookup = metadataCache.lookup(url: request.url!, apiKey: apiKey, scope: metadataScope, as: T.self)
            if let cached = lookup.cached { request.setValue(cached.etag, forHTTPHeaderField: "If-None-Match") }
            let (data, response) = try await session.data(for: request)
            try Task.checkCancellation()
            guard let http = response as? HTTPURLResponse else { throw ImmichError.invalidResponse }
            if http.statusCode == 304 {
                guard let cached = lookup.cached,
                      MetadataResponseCache.matches(http.value(forHTTPHeaderField: "ETag"), sent: cached.etag) else {
                    throw ImmichError.invalidResponse
                }
                if !MetadataResponseCache.permitsStorage(http) {
                    metadataCache.store(cached.value, etag: nil, encodedBytes: 0, for: lookup)
                }
                return cached.value
            }
            try Self.validate(http, data: data)
            guard let value = try? Self.decoder.decode(T.self, from: data) else { throw ImmichError.invalidResponse }
            let etag = http.statusCode == 200 && MetadataResponseCache.permitsStorage(http)
                ? http.value(forHTTPHeaderField: "ETag") : nil
            metadataCache.store(value, etag: etag, encodedBytes: data.count, for: lookup)
            return value
        }
    }

    private func send<T: Decodable>(path: String, method: String = "GET", query: [URLQueryItem] = [], body: Data? = nil) async throws -> T {
        let data = try await withFallback { base in
            try await data(for: request(path, method: method, query: query, body: body, base: base))
        }
        do {
            return try Self.decoder.decode(T.self, from: data)
        } catch {
            throw ImmichError.invalidResponse
        }
    }

    public static func validate(_ response: URLResponse, data: Data?) throws {
        guard let http = response as? HTTPURLResponse else { throw ImmichError.invalidResponse }
        guard !(200..<300).contains(http.statusCode) else { return }
        let message = data.flatMap(Self.errorMessage)
        switch http.statusCode {
        case 300..<400: throw ImmichError.redirected
        case 401: throw ImmichError.unauthorized
        case 403: throw ImmichError.missingPermission(message)
        // Only Immich's own JSON 404 means the item is gone. A reverse proxy answering 404 while
        // Immich restarts must not make Finder delete whole folders; neither must an unknown route.
        case 404 where message.map { !$0.hasPrefix("Cannot ") } == true: throw ImmichError.notFound
        // Immich answers 400 "Not found or no album.read access" for items that are gone.
        case 400 where message?.hasPrefix("Not found or no ") == true: throw ImmichError.notFound
        default: throw ImmichError.http(status: http.statusCode, message: message)
        }
    }

    /// Immich 3 sends `message` as a string, Immich 2 sometimes as an array of strings.
    static func errorMessage(from data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        switch object["message"] {
        case let message as String: return message
        case let messages as [String]: return messages.joined(separator: ", ")
        default: return nil
        }
    }

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let string = try decoder.singleValueContainer().decode(String.self)
            for style in [Date.ISO8601FormatStyle(includingFractionalSeconds: true), Date.ISO8601FormatStyle()] {
                if let date = try? style.parse(string) { return date }
            }
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Unrecognized date \(string)"))
        }
        return decoder
    }()

    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()
}

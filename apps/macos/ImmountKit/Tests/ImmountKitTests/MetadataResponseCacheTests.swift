import Foundation
import os
import Testing
@testable import ImmountKit

@Suite struct MetadataResponseCacheTests {
    @Test func revalidatesAcrossClientsAndReplacesChangedResponses() async throws {
        let calls = OSAllocatedUnfairLock(initialState: 0)
        let cache = MetadataResponseCache()
        let fixture = MetadataFixture { request in
            let call = calls.withLock { let value = $0; $0 += 1; return value }
            #expect(request.cachePolicy == .reloadIgnoringLocalCacheData)
            switch call {
            case 0:
                #expect(request.value(forHTTPHeaderField: "If-None-Match") == nil)
                return .json(Self.tags("first"), etag: "\"v1\"")
            case 1:
                #expect(request.value(forHTTPHeaderField: "If-None-Match") == "\"v1\"")
                return .json("not JSON", status: 304, etag: "W/\"v1\"")
            case 2:
                #expect(request.value(forHTTPHeaderField: "If-None-Match") == "\"v1\"")
                return .json(Self.tags("changed"), etag: "\"v2\"")
            default:
                #expect(request.value(forHTTPHeaderField: "If-None-Match") == "\"v2\"")
                return .json("", status: 304)
            }
        }
        // A fresh client simulates Catalog/connection recreation, sharing only this cache.
        for expected in ["first", "first", "changed", "changed"] {
            #expect(try await fixture.client(cache: cache).tags().first?.name == expected)
        }
        #expect(calls.withLock { $0 } == 4)
    }

    @Test func keysIncludeCredentialsExactURLAndProfileScope() async throws {
        let seen = OSAllocatedUnfairLock<Set<String>>(initialState: [])
        let fixture = MetadataFixture { request in
            let key = request.value(forHTTPHeaderField: "x-api-key")!
            let identity = key + request.url!.absoluteString
            let first = seen.withLock { $0.insert(identity).inserted }
            #expect(request.value(forHTTPHeaderField: "If-None-Match") == (first ? nil : "\"same-etag\""))
            return first ? .json(Self.tags(identity), etag: "\"same-etag\"") : .json("", status: 304)
        }
        let cache = MetadataResponseCache()
        let bases = [fixture.base, fixture.base.appending(path: "other"),
                     URL(string: "https://other.example.invalid:444")!]
        for _ in 0..<2 {
            for base in bases {
                for key in ["first-key", "second-key"] {
                    let tags = try await fixture.client(cache: cache, base: base, key: key).tags()
                    #expect(tags.first?.name == key + base.appending(path: "api/tags").absoluteString)
                }
            }
        }
        let url = fixture.base.appending(path: "api/tags")
        let first = cache.lookup(url: url, apiKey: "same", scope: "profile-one", as: String.self)
        cache.store("one", etag: "\"one\"", encodedBytes: 3, for: first)
        #expect(cache.lookup(url: url, apiKey: "same", scope: "profile-two", as: String.self).cached == nil)
        #expect(cache.lookup(url: url.appending(queryItems: [.init(name: "page", value: "2")]),
                             apiKey: "same", scope: "profile-one", as: String.self).cached == nil)
    }

    @Test(arguments: [200, 401, 403, 500])
    func failedOrMalformedResponsesNeverBecomeValidators(status: Int) async throws {
        let calls = OSAllocatedUnfairLock(initialState: 0)
        let fixture = MetadataFixture { request in
            #expect(request.value(forHTTPHeaderField: "If-None-Match") == nil)
            let call = calls.withLock { $0 += 1; return $0 }
            return call == 1 ? .json("malformed", status: status, etag: "\"bad\"") : .json("[]")
        }
        let client = fixture.client(cache: MetadataResponseCache())
        await #expect(throws: (any Error).self) { _ = try await client.tags() }
        #expect(try await client.tags().isEmpty)
    }

    @Test(arguments: ["no-etag", "no-store", "vary"])
    func unsupportedCachingAlwaysFetchesNormally(mode: String) async throws {
        let fixture = MetadataFixture { request in
            #expect(request.value(forHTTPHeaderField: "If-None-Match") == nil)
            return .json("[]", etag: mode == "no-etag" ? nil : "\"etag\"",
                         headers: mode == "no-store" ? ["Cache-Control": "private, no-store"]
                            : mode == "vary" ? ["Vary": "Cookie"] : [:])
        }
        let client = fixture.client(cache: MetadataResponseCache())
        for _ in 0..<2 { #expect(try await client.tags().isEmpty) }
    }

    @Test func rejectsUnsolicitedOrMismatchedNotModified() async throws {
        let unsolicited = MetadataFixture { _ in .json("", status: 304) }
        await #expect(throws: ImmichError.invalidResponse) {
            _ = try await unsolicited.client(cache: MetadataResponseCache()).tags()
        }
        let calls = OSAllocatedUnfairLock(initialState: 0)
        let mismatch = MetadataFixture { _ in
            let call = calls.withLock { $0 += 1; return $0 }
            return call == 1 ? .json("[]", etag: "\"first\"") : .json("", status: 304, etag: "\"other\"")
        }
        let client = mismatch.client(cache: MetadataResponseCache())
        _ = try await client.tags()
        await #expect(throws: ImmichError.invalidResponse) { _ = try await client.tags() }
    }

    @Test func paginationAndOnlySelectedIndexesUseConditionalRequests() async throws {
        let calls = OSAllocatedUnfairLock<[String: Int]>(initialState: [:])
        let fixture = MetadataFixture { request in
            let url = request.url!
            let path = url.path
            let isIndex = ["/api/albums", "/api/people", "/api/tags", "/api/timeline/buckets"].contains(path)
            let count = calls.withLock { $0[url.absoluteString, default: 0] += 1; return $0[url.absoluteString]! }
            #expect(request.value(forHTTPHeaderField: "If-None-Match") == (isIndex && count > 1 ? "\"index\"" : nil))
            if isIndex && count > 1 { return .json("", status: 304) }
            let body: String
            switch path {
            case "/api/albums", "/api/tags", "/api/timeline/buckets": body = "[]"
            case "/api/people":
                let page = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "page" }?.value
                body = "{\"people\":[{\"id\":\"\(page!)\",\"name\":\"Person\",\"isHidden\":false}],\"hasNextPage\":\(page == "1")}"
            case "/api/users/me": body = #"{"id":"user"}"#
            case "/api/server/version": body = #"{"major":3,"minor":2,"patch":0}"#
            case "/api/albums/album":
                body = #"{"id":"album","albumName":"Album","assetCount":0,"createdAt":"2024-01-01T00:00:00Z","updatedAt":"2024-01-01T00:00:00Z"}"#
            case "/api/people/person": body = #"{"id":"person","name":"Person","isHidden":false}"#
            case "/api/tags/tag": body = #"{"id":"tag","name":"Tag","value":"Tag"}"#
            case "/api/assets/asset/thumbnail": body = "image-bytes"
            default: throw ImmichError.invalidResponse
            }
            return .json(body, etag: "\"index\"")
        }
        let client = fixture.client(cache: MetadataResponseCache())
        for _ in 0..<2 {
            _ = try await client.albums()
            #expect(try await client.people().map(\.id) == ["1", "2"])
            _ = try await client.tags()
            _ = try await client.timeBuckets()
            _ = try await client.currentUser()
            _ = try await client.serverVersion()
            _ = try await client.album(id: "album")
            _ = try await client.person(id: "person")
            _ = try await client.tag(id: "tag")
            _ = try await client.thumbnail(assetID: "asset", large: false)
        }
    }

    @Test func boundedCacheEvictsLeastRecentlyUsedAndRejectsOversizedValues() {
        let cache = MetadataResponseCache(maxEntries: 2, maxBytes: 1_000)
        func lookup(_ id: String) -> MetadataResponseCache.Lookup<String> {
            cache.lookup(url: URL(string: "https://cache.example.invalid/\(id)")!, apiKey: "key", as: String.self)
        }
        cache.store("a", etag: "a", encodedBytes: 20, for: lookup("a"))
        cache.store("b", etag: "b", encodedBytes: 20, for: lookup("b"))
        _ = lookup("a")
        cache.store("c", etag: "c", encodedBytes: 20, for: lookup("c"))
        #expect(lookup("b").cached == nil)
        #expect(lookup("a").cached?.value == "a")
        cache.store("oversized", etag: "large", encodedBytes: 1_001, for: lookup("a"))
        #expect(lookup("a").cached == nil)
        #expect(lookup("c").cached?.value == "c")

        let byteBound = MetadataResponseCache(maxEntries: 10, maxBytes: 500)
        for id in ["one", "two"] {
            let entry = byteBound.lookup(url: URL(string: "https://cache.example.invalid/\(id)")!, apiKey: "key", as: String.self)
            byteBound.store(id, etag: id, encodedBytes: 300, for: entry)
        }
        #expect(byteBound.lookup(url: URL(string: "https://cache.example.invalid/one")!, apiKey: "key", as: String.self).cached == nil)
        #expect(byteBound.lookup(url: URL(string: "https://cache.example.invalid/two")!, apiKey: "key", as: String.self).cached?.value == "two")
    }

    @Test func clearingAndOutOfOrderResponsesCannotRestoreObsoleteEntries() {
        let cache = MetadataResponseCache()
        let url = URL(string: "https://cache.example.invalid/api/tags")!
        let first = cache.lookup(url: url, apiKey: "key", as: String.self)
        let second = cache.lookup(url: url, apiKey: "key", as: String.self)
        cache.store("new", etag: "new", encodedBytes: 3, for: second)
        cache.store("old", etag: "old", encodedBytes: 3, for: first)
        #expect(cache.lookup(url: url, apiKey: "key", as: String.self).cached?.value == "new")
        let pending = cache.lookup(url: url, apiKey: "key", as: String.self)
        cache.removeAll()
        cache.store("late", etag: "late", encodedBytes: 4, for: pending)
        #expect(cache.lookup(url: url, apiKey: "key", as: String.self).cached == nil)
    }

    @Test func concurrentResponsesRemainWithinTheEntryBudget() async {
        let cache = MetadataResponseCache(maxEntries: 8)
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<100 {
                group.addTask {
                    let entry = cache.lookup(url: URL(string: "https://cache.example.invalid/\(i)")!, apiKey: "key", as: Int.self)
                    cache.store(i, etag: "\"\(i)\"", encodedBytes: 8, for: entry)
                }
            }
        }
        let retained = (0..<100).filter {
            cache.lookup(url: URL(string: "https://cache.example.invalid/\($0)")!, apiKey: "key", as: Int.self).cached != nil
        }
        #expect(retained.count == 8)
    }

    private static func tags(_ name: String) -> String {
        let value = [["id": "tag", "name": name, "value": name]]
        return String(data: try! JSONSerialization.data(withJSONObject: value), encoding: .utf8)!
    }
}

private final class MetadataFixture: Sendable {
    let id = UUID().uuidString
    let base = URL(string: "https://\(UUID().uuidString).example.invalid")!
    let session: URLSession

    init(handler: @escaping MetadataURLProtocol.Handler) {
        let id = id
        MetadataURLProtocol.handlers.withLock { $0[id] = handler }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.protocolClasses = [MetadataURLProtocol.self]
        configuration.httpAdditionalHeaders = [MetadataURLProtocol.sessionHeader: id]
        session = URLSession(configuration: configuration)
    }

    func client(cache: MetadataResponseCache, base: URL? = nil, key: String = "test-key") -> ImmichClient {
        ImmichClient(serverURL: base ?? self.base, apiKey: key, session: session, metadataCache: cache)
    }

    deinit {
        session.invalidateAndCancel()
        MetadataURLProtocol.handlers.withLock { $0[id] = nil }
    }
}

private final class MetadataURLProtocol: URLProtocol, @unchecked Sendable {
    struct Reply: Sendable {
        let status: Int
        let body: Data
        let headers: [String: String]

        static func json(_ body: String, status: Int = 200, etag: String? = nil, headers: [String: String] = [:]) -> Self {
            var headers = headers
            headers["ETag"] = etag
            headers["Content-Type"] = "application/json"
            return Self(status: status, body: Data(body.utf8), headers: headers)
        }
    }

    typealias Handler = @Sendable (URLRequest) throws -> Reply
    static let sessionHeader = "X-Immount-Metadata-Test"
    static let handlers = OSAllocatedUnfairLock<[String: Handler]>(initialState: [:])

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            guard let id = request.value(forHTTPHeaderField: Self.sessionHeader),
                  let handler = Self.handlers.withLock({ $0[id] }), let url = request.url else {
                throw URLError(.resourceUnavailable)
            }
            let reply = try handler(request)
            let response = HTTPURLResponse(url: url, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: reply.headers)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: reply.body)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}

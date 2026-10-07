import Foundation
import os
import Testing
@testable import ImmountKit

@Suite struct TagsAPITests {
    private static let firstTag = "00000000-0000-4000-8000-000000000001"
    private static let secondTag = "00000000-0000-4000-8000-000000000002"

    @Test func readsTagsAndDetailsWithHierarchyAndOptionalMetadata() async throws {
        let requests = OSAllocatedUnfairLock<[String]>(initialState: [])
        let root = ##"{"id":"root","name":"Places","value":"Places","createdAt":"2024-01-01T00:00:00Z","updatedAt":"2024-01-02T00:00:00.000Z","color":"#ffffff"}"##
        let child = #"{"id":"child","name":"Rome","value":"Places/Rome","parentId":"root","createdAt":"2024-01-03T00:00:00Z","updatedAt":"2024-01-04T00:00:00Z","futureField":true}"#
        let fixture = TagsAPIFixture { request in
            #expect(request.httpMethod == "GET")
            #expect(request.value(forHTTPHeaderField: "x-api-key") == "test-key")
            #expect(request.url?.query() == nil)
            let path = request.url!.path
            requests.withLock { $0.append(path) }
            switch path {
            case "/api/tags": return .json("[\(root),\(child)]")
            case "/api/tags/child": return .json(child)
            default: throw ImmichError.invalidResponse
            }
        }
        let tags = try await fixture.client.tags()
        #expect(tags.map(\.id) == ["root", "child"])
        #expect(tags[0].parentId == nil)
        #expect(tags[0].createdAt != nil)
        #expect(tags[0].updatedAt != nil)
        #expect(tags[1].name == "Rome")
        #expect(tags[1].value == "Places/Rome")
        #expect(tags[1].parentId == "root")
        #expect(try await fixture.client.tag(id: "child") == tags[1])
        #expect(requests.withLock { $0 } == ["/api/tags", "/api/tags/child"])

        let minimal = try ImmichClient.decoder.decode(ImmichTag.self,
            from: Data(#"{"id":"root","name":"Places","value":"Places","parentId":null}"#.utf8))
        #expect(minimal.parentId == nil && minimal.createdAt == nil && minimal.updatedAt == nil)
    }

    @Test func anEmptyTagListIsValidButMalformedTagsAreNot() async throws {
        let empty = TagsAPIFixture { _ in .json("[]") }
        #expect(try await empty.client.tags().isEmpty)
        let malformed = TagsAPIFixture { _ in .json(#"[{"id":"tag","name":"Missing full path"}]"#) }
        await #expect(throws: ImmichError.invalidResponse) { _ = try await malformed.client.tags() }
    }

    @Test func tagPermissionsAndNotFoundRemainDistinctErrors() async {
        #expect(ImmichAPIKey.requiredPermissions.contains("tag.read"))
        #expect(ImmichAPIKey(name: "all", permissions: ["all"]).missingPermissions.isEmpty)
        let missingTag = ImmichAPIKey(name: "old-key", permissions: ImmichAPIKey.requiredPermissions.filter { $0 != "tag.read" })
        #expect(missingTag.missingPermissions == ["tag.read"])
        let denied = TagsAPIFixture { _ in .json(#"{"message":"Missing required permission: tag.read"}"#, status: 403) }
        await #expect(throws: ImmichError.missingPermission("Missing required permission: tag.read")) {
            _ = try await denied.client.tags()
        }
        let missing = TagsAPIFixture { _ in .json(#"{"message":"Not Found"}"#, status: 404) }
        await #expect(throws: ImmichError.notFound) { _ = try await missing.client.tag(id: "missing") }
        let unsupported = TagsAPIFixture { _ in .json(#"{"message":"Cannot GET /api/tags"}"#, status: 404) }
        await #expect(throws: ImmichError.http(status: 404, message: "Cannot GET /api/tags")) {
            _ = try await unsupported.client.tags()
        }
    }

    @Test func tagRequestsUseTheExistingConnectionFallback() async throws {
        let local = URL(string: "https://local-\(UUID().uuidString).example.invalid")!
        let attempts = OSAllocatedUnfairLock<[URL]>(initialState: [])
        let fixture = TagsAPIFixture { request in
            #expect(request.url?.path == "/api/tags")
            attempts.withLock { $0.append(request.url!) }
            if request.url?.host() == local.host() { throw URLError(.cannotConnectToHost) }
            return .json("[]")
        }
        Reachability.shared.record(local, reachable: true)
        let remote = fixture.base
        let client = ImmichClient(apiKey: "test-key", session: fixture.session) { [local, remote] }
        #expect(try await client.tags().isEmpty)
        #expect(attempts.withLock { $0.map { $0.host() } } == [local.host(), remote.host()])
    }

    @Test func structuredTagSearchUsesAllAndKeepsTheFilterAcrossCursorPages() async throws {
        let cursors = OSAllocatedUnfairLock<[String?]>(initialState: [])
        let fixture = TagsAPIFixture { request in
            if request.url?.path == "/api/server/version" { return .json(#"{"major":3,"minor":2,"patch":0}"#) }
            #expect(request.url?.path == "/api/search/metadata")
            #expect(request.httpMethod == "POST")
            let body = try Self.requestBody(request)
            let filter = try #require(body["filter"] as? [String: Any])
            let tagIDs = try #require(filter["tagIds"] as? [String: Any])
            #expect(tagIDs["all"] as? [String] == [Self.firstTag, Self.secondTag])
            #expect(tagIDs["any"] == nil)
            #expect((filter["visibility"] as? [String: Any])?["in"] as? [String] == ["timeline", "archive"])
            #expect((filter["trashedAt"] as? [String: Any])?["eq"] is NSNull)
            #expect((filter["isOffline"] as? [String: Any])?["eq"] as? Bool == false)
            #expect(body["tagIds"] == nil && body["page"] == nil)
            #expect(body["size"] as? Int == 1_000)
            #expect(body["withExif"] as? Bool == true)
            let cursor = body["cursor"] as? String
            cursors.withLock { $0.append(cursor) }
            if cursor == nil {
                return .json("{\"assets\":{\"items\":[\(Self.asset("first"))],\"nextCursor\":\"next\"}}")
            }
            #expect(cursor == "next")
            return .json("{\"assets\":{\"items\":[\(Self.asset("second"))],\"nextCursor\":null}}")
        }
        let assets = try await fixture.client.searchAssets(AssetQuery(tagIDs: [Self.firstTag, Self.secondTag]))
        #expect(assets.map(\.id) == ["first", "second"])
        #expect(cursors.withLock { $0 } == [nil, "next"])
    }

    @Test(arguments: [2, 3])
    func legacyTagSearchPreservesIDsAcrossPagesAndVisibilityRequests(major: Int) async throws {
        let pages = OSAllocatedUnfairLock<[String]>(initialState: [])
        let fixture = TagsAPIFixture { request in
            if request.url?.path == "/api/server/version" {
                return .json("{\"major\":\(major),\"minor\":1,\"patch\":0}")
            }
            #expect(request.url?.path == "/api/search/metadata")
            let body = try Self.requestBody(request)
            #expect(body["tagIds"] as? [String] == [Self.firstTag, Self.secondTag])
            #expect(body["filter"] == nil && body["cursor"] == nil)
            #expect(body["withExif"] as? Bool == true)
            let visibility = body["visibility"] as? String ?? "all"
            if major == 2 { #expect(["timeline", "archive"].contains(visibility)) }
            else { #expect(visibility == "all") }
            let page = try #require(body["page"] as? Int)
            #expect(page == 1 || page == 2)
            let id = "\(visibility)-\(page)"
            pages.withLock { $0.append(id) }
            let next = page == 1 ? "\"2\"" : "null"
            return .json("{\"assets\":{\"items\":[\(Self.asset(id))],\"nextPage\":\(next)}}")
        }
        let assets = try await fixture.client.searchAssets(AssetQuery(tagIDs: [Self.firstTag, Self.secondTag]))
        let expected = major == 2 ? ["timeline-1", "timeline-2", "archive-1", "archive-2"] : ["all-1", "all-2"]
        #expect(assets.map(\.id) == expected)
        #expect(pages.withLock { $0 } == expected)
    }

    @Test func staleVersionCannotTurnATagFolderIntoTheWholeLibrary() async throws {
        let versionReads = OSAllocatedUnfairLock(initialState: 0)
        let fixture = TagsAPIFixture { request in
            if request.url?.path == "/api/server/version" {
                let call = versionReads.withLock { $0 += 1; return $0 }
                return .json("{\"major\":3,\"minor\":\(call == 1 ? 2 : 1),\"patch\":0}")
            }
            let body = try Self.requestBody(request)
            if body["filter"] != nil {
                // A pre-3.2 server ignored the filter and returned an unfiltered legacy page.
                return .json("{\"assets\":{\"items\":[\(Self.asset("unfiltered-library-item"))],\"nextPage\":null}}")
            }
            #expect(body["tagIds"] as? [String] == [Self.firstTag])
            return .json("{\"assets\":{\"items\":[\(Self.asset("tagged-item"))],\"nextPage\":null}}")
        }
        let assets = try await fixture.client.searchAssets(AssetQuery(tagIDs: [Self.firstTag]))
        #expect(assets.map(\.id) == ["tagged-item"])
        #expect(versionReads.withLock { $0 } == 2)
    }

    private static func asset(_ id: String) -> String {
        """
        {"id":"\(id)","ownerId":"owner","type":"IMAGE","originalFileName":"photo.jpg",
         "fileCreatedAt":"2024-01-01T00:00:00Z","fileModifiedAt":"2024-01-01T00:00:00Z",
         "localDateTime":"2024-01-01T00:00:00Z","updatedAt":"2024-01-01T00:00:00Z","checksum":"checksum"}
        """
    }

    private static func requestBody(_ request: URLRequest) throws -> [String: Any] {
        var data = request.httpBody ?? Data()
        if request.httpBody == nil, let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 4_096)
            while true {
                let count = stream.read(&buffer, maxLength: buffer.count)
                guard count >= 0 else { throw stream.streamError ?? ImmichError.invalidResponse }
                if count == 0 { break }
                data.append(contentsOf: buffer.prefix(count))
            }
        }
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}

/// Fixture handlers are scoped to one ephemeral session; these tests never contact a server.
private final class TagsAPIFixture: Sendable {
    let id = UUID().uuidString
    let base = URL(string: "https://\(UUID().uuidString).example.invalid")!
    let session: URLSession

    var client: ImmichClient { ImmichClient(serverURL: base, apiKey: "test-key", session: session) }

    init(handler: @escaping TagsAPIURLProtocol.Handler) {
        let id = id
        TagsAPIURLProtocol.handlers.withLock { $0[id] = handler }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [TagsAPIURLProtocol.self]
        configuration.httpAdditionalHeaders = [TagsAPIURLProtocol.sessionHeader: id]
        session = URLSession(configuration: configuration)
    }

    deinit {
        session.invalidateAndCancel()
        TagsAPIURLProtocol.handlers.withLock { $0[id] = nil }
    }
}

private final class TagsAPIURLProtocol: URLProtocol, @unchecked Sendable {
    struct Reply: Sendable {
        let status: Int
        let body: Data

        static func json(_ body: String, status: Int = 200) -> Self {
            Self(status: status, body: Data(body.utf8))
        }
    }

    typealias Handler = @Sendable (URLRequest) throws -> Reply
    static let sessionHeader = "X-Immount-Tags-Test"
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
            let response = HTTPURLResponse(url: url, statusCode: reply.status, httpVersion: "HTTP/1.1",
                                           headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: reply.body)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

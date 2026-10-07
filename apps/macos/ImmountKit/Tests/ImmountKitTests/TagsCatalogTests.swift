import Foundation
import os
import Testing
@testable import ImmountKit

@Suite struct TagsCatalogTests {
    private let parent = ItemID.tag(parent: .tags, id: "parent-0001")

    @Test func identifiersPreserveUUIDAncestryAndAssetIdentity() throws {
        let child = ItemID.tag(parent: parent, id: "child-0002")
        let asset = ItemID.asset(parent: child, id: "asset-0003")
        for id in [ItemID.tags, parent, child, asset] {
            #expect(ItemID(rawValue: id.rawValue) == id)
            #expect(try JSONDecoder().decode(ItemID.self, from: JSONEncoder().encode(id)) == id)
        }
        #expect(parent.rawValue == "tag:tags/parent-0001")
        #expect(child.rawValue == "tag:tag:tags/parent-0001/child-0002")
        #expect(child.parent == parent)
        #expect(child.tagID == "child-0002")
        #expect(child.assetID == nil)
        #expect(child.isFolder)
        #expect(asset.parent == child)
        #expect(asset.assetID == "asset-0003")
        #expect(asset.depth == 4)
    }

    @Test(arguments: ["tag:", "tag:tags/", "tag:root/a", "tag:albums/a", "tag:album:a/b", "tag:asset:favorites/a/b", "tag:tag:tags/a/"])
    func rejectsInvalidTagParentsAndEmptyIDs(raw: String) {
        #expect(ItemID(rawValue: raw) == nil)
    }

    @Test func rootIncludesTagsWithoutNeedingAnAPIRequest() async throws {
        let fixture = CatalogFixture { _ in throw ImmichError.invalidResponse }
        let catalog = Catalog(client: fixture.client, ownerID: "owner")
        #expect(try await catalog.children(of: .root).map(\.filename) == ["Albums", "Favorites", "People", "Tags", "Timeline"])
        #expect(try await catalog.entry(for: .tags).parent == .root)
    }

    @Test func listsImmediateTagChildrenAndMemoizesTheHierarchy() async throws {
        let requests = OSAllocatedUnfairLock<[String]>(initialState: [])
        let fixture = CatalogFixture { request in
            requests.withLock { $0.append(request.url!.path) }
            switch request.url?.path {
            case "/api/tags":
                return .json(#"[{"id":"grandchild-0003","name":"Rome","value":"Travel/Italy/Rome","parentId":"child-0002"},{"id":"child-0002","name":"Italy","value":"Travel/Italy","parentId":"parent-0001"},{"id":"parent-0001","name":"Travel","value":"Travel","createdAt":"2024-01-01T00:00:00Z","updatedAt":"2024-02-01T00:00:00Z"}]"#)
            case "/api/server/version": return .version
            case "/api/search/metadata": return .assets([])
            default: throw ImmichError.invalidResponse
            }
        }
        let catalog = Catalog(client: fixture.client, ownerID: "owner")
        let top = try await catalog.children(of: .tags)
        #expect(top.map(\.filename) == ["Travel"])
        #expect(top.first?.id == parent)
        #expect(top.first?.created != nil)
        #expect(top.first?.modified != nil)
        let child = ItemID.tag(parent: parent, id: "child-0002")
        #expect(try await catalog.children(of: parent).map(\.id) == [child])
        #expect(try await catalog.children(of: child).map(\.filename) == ["Rome"])
        #expect(try await catalog.entry(for: child).filename == "Italy")
        #expect(requests.withLock { $0.filter { $0 == "/api/tags" }.count } == 1)
    }

    @Test func folderAndFileNamesShareOneNamespaceAndAssetsStayBrowsable() async throws {
        let searches = OSAllocatedUnfairLock<Int>(initialState: 0)
        let fixture = CatalogFixture { request in
            switch request.url?.path {
            case "/api/tags":
                return .json(#"[{"id":"parent-0001","name":"Photos","value":"Photos"},{"id":"22222222-b","name":"photo.jpg","value":"Photos/photo.jpg","parentId":"parent-0001"},{"id":"11111111-a","name":"Photo.JPG","value":"Photos/Photo.JPG","parentId":"parent-0001"}]"#)
            case "/api/server/version": return .version
            case "/api/search/metadata":
                searches.withLock { $0 += 1 }
                let body = try #require(try JSONSerialization.jsonObject(with: requestBody(request)) as? [String: Any])
                let filter = try #require(body["filter"] as? [String: Any])
                #expect((filter["tagIds"] as? [String: [String]])?["all"] == ["parent-0001"])
                return .assets([
                    assetJSON(id: "33333333-file", name: "PHOTO.JPG", visibility: "archive"),
                    assetJSON(id: "33333333-file", name: "PHOTO.JPG", visibility: "archive"),
                    assetJSON(id: "hidden", visibility: "hidden"),
                    assetJSON(id: "locked", visibility: "locked"),
                    assetJSON(id: "offline", offline: true),
                ])
            default: throw ImmichError.invalidResponse
            }
        }
        let catalog = Catalog(client: fixture.client, ownerID: "owner")
        let entries = try await catalog.children(of: parent)
        #expect(entries.map(\.filename) == ["Photo.JPG", "photo.jpg (22222222)", "PHOTO (33333333).JPG"])
        #expect(entries.allSatisfy { !$0.filename.contains("/") })
        #expect(entries.last?.id == .asset(parent: parent, id: "33333333-file"))
        let duplicate = ItemID.tag(parent: parent, id: "22222222-b")
        #expect(try await catalog.entry(for: duplicate).filename == "photo.jpg (22222222)")
        #expect(searches.withLock { $0 } == 2)
    }

    @Test func renamingATagKeepsItsIDAndChangesItsMetadata() async throws {
        func fixture(name: String) -> CatalogFixture {
            CatalogFixture { request in
                #expect(request.url?.path == "/api/tags")
                return .json("[{\"id\":\"parent-0001\",\"name\":\"\(name)\",\"value\":\"\(name)\"}]")
            }
        }
        let original = fixture(name: "Travel")
        let renamed = fixture(name: "Holidays")
        let before = try await Catalog(client: original.client, ownerID: "owner").entry(for: parent)
        let after = try await Catalog(client: renamed.client, ownerID: "owner").entry(for: parent)
        #expect(before.id == after.id)
        #expect(before.metadataVersion != after.metadataVersion)
        #expect(after.filename == "Holidays")
    }

    @Test func missingTagsAndIncorrectAncestryAreNotFoundWithoutSearchingAssets() async throws {
        let fixture = CatalogFixture { request in
            #expect(request.url?.path == "/api/tags")
            return .json(#"[{"id":"parent-0001","name":"Travel","value":"Travel"},{"id":"child-0002","name":"Italy","value":"Travel/Italy","parentId":"parent-0001"}]"#)
        }
        let catalog = Catalog(client: fixture.client, ownerID: "owner")
        for id in [ItemID.tag(parent: .tags, id: "missing"), .tag(parent: .tags, id: "child-0002")] {
            await #expect(throws: ImmichError.notFound) { _ = try await catalog.entry(for: id) }
            await #expect(throws: ImmichError.notFound) { _ = try await catalog.children(of: id) }
        }
    }

    @Test(arguments: [
        #"[{"id":"a","name":"A","value":"A","parentId":"missing"}]"#,
        #"[{"id":"a","name":"A","value":"A","parentId":"a"}]"#,
        #"[{"id":"a","name":"A","value":"A","parentId":"b"},{"id":"b","name":"B","value":"B","parentId":"a"}]"#,
        #"[{"id":"a","name":"A","value":"A"},{"id":"a","name":"Other","value":"Other"}]"#,
    ])
    func incompleteOrCyclicHierarchiesFailInsteadOfBecomingEmpty(json: String) async {
        let fixture = CatalogFixture { _ in .json(json) }
        await #expect(throws: ImmichError.invalidResponse) {
            _ = try await Catalog(client: fixture.client, ownerID: "owner").children(of: .tags)
        }
    }

    @Test func repeatedIdenticalTagsAreDeduplicatedAndNamesAreSanitized() async throws {
        let fixture = CatalogFixture { _ in
            .json(#"[{"id":"a","name":"  .A/B:C  ","value":"  .A/B:C  "},{"id":"a","name":"  .A/B:C  ","value":"  .A/B:C  "}]"#)
        }
        #expect(try await Catalog(client: fixture.client, ownerID: "owner").children(of: .tags).map(\.filename) == ["_A-B-C"])
    }

    @Test func missingTagPermissionRemainsAnError() async {
        let fixture = CatalogFixture { _ in .json(#"{"message":"Missing required permission: tag.read"}"#, status: 403) }
        await #expect(throws: ImmichError.missingPermission("Missing required permission: tag.read")) {
            _ = try await Catalog(client: fixture.client, ownerID: "owner").children(of: .tags)
        }
    }
}

@Suite struct TimelineCatalogTests {
    @Test func monthLookupMatchesTheEnumeratedMonth() async throws {
        let fixture = CatalogFixture { request in
            #expect(request.url?.path == "/api/timeline/buckets")
            return .json(#"[{"timeBucket":"2024-10-01","count":3},{"timeBucket":"2024-11-01","count":5}]"#)
        }
        let catalog = Catalog(client: fixture.client, ownerID: "owner")
        let months = try await catalog.children(of: .year(2024))
        let october = ItemID.month(YearMonth(year: 2024, month: 10))
        let enumerated = try #require(months.first { $0.id == october })
        #expect(enumerated.childCount == 3)
        #expect(try await catalog.entry(for: october) == enumerated)
        #expect(try await Catalog(client: fixture.client, ownerID: "owner").entry(for: october).metadataVersion == enumerated.metadataVersion)
        await #expect(throws: ImmichError.notFound) {
            _ = try await catalog.entry(for: .month(YearMonth(year: 2024, month: 12)))
        }
    }
}

private func assetJSON(id: String, name: String = "photo.jpg", visibility: String = "timeline", offline: Bool = false) -> String {
    """
    {"id":"\(id)","ownerId":"owner","type":"IMAGE","originalFileName":"\(name)","fileCreatedAt":"2024-01-01T00:00:00Z","fileModifiedAt":"2024-01-01T00:00:00Z","localDateTime":"2024-01-01T00:00:00Z","updatedAt":"2024-01-01T00:00:00Z","checksum":"test-checksum","visibility":"\(visibility)","isOffline":\(offline)}
    """
}

private func requestBody(_ request: URLRequest) throws -> Data {
    if let data = request.httpBody { return data }
    guard let stream = request.httpBodyStream else { throw ImmichError.invalidResponse }
    stream.open()
    defer { stream.close() }
    var data = Data()
    var buffer = [UInt8](repeating: 0, count: 1024)
    while stream.hasBytesAvailable {
        let count = stream.read(&buffer, maxLength: buffer.count)
        guard count >= 0 else { throw stream.streamError ?? ImmichError.invalidResponse }
        if count == 0 { break }
        data.append(buffer, count: count)
    }
    return data
}

/// All requests are intercepted per session; tests never contact a server or read a key.
private final class CatalogFixture: Sendable {
    let id = UUID().uuidString
    let session: URLSession
    let base = URL(string: "https://catalog.example.invalid")!
    var client: ImmichClient { ImmichClient(serverURL: base, apiKey: "test-key", session: session) }

    init(handler: @escaping CatalogURLProtocol.Handler) {
        let sessionID = id
        CatalogURLProtocol.handlers.withLock { $0[sessionID] = handler }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CatalogURLProtocol.self]
        configuration.httpAdditionalHeaders = [CatalogURLProtocol.sessionHeader: id]
        session = URLSession(configuration: configuration)
    }

    deinit {
        session.invalidateAndCancel()
        CatalogURLProtocol.handlers.withLock { $0[id] = nil }
    }
}

private final class CatalogURLProtocol: URLProtocol, @unchecked Sendable {
    struct Reply: Sendable {
        let status: Int
        let body: Data
        static func json(_ value: String, status: Int = 200) -> Self { Self(status: status, body: Data(value.utf8)) }
        static var version: Self { .json(#"{"major":3,"minor":2,"patch":4}"#) }
        static func assets(_ values: [String]) -> Self {
            .json("{\"assets\":{\"items\":[\(values.joined(separator: ","))],\"nextCursor\":null}}")
        }
    }
    typealias Handler = @Sendable (URLRequest) throws -> Reply
    static let sessionHeader = "X-Immount-Catalog-Test"
    static let handlers = OSAllocatedUnfairLock<[String: Handler]>(initialState: [:])

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            guard let id = request.value(forHTTPHeaderField: Self.sessionHeader),
                  let handler = Self.handlers.withLock({ $0[id] }), let url = request.url else { throw ImmichError.invalidResponse }
            let reply = try handler(request)
            let response = HTTPURLResponse(url: url, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: reply.body)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}

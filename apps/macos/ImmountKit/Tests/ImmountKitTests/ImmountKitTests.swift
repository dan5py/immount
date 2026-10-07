import Foundation
import os
import Testing
@testable import ImmountKit

@Suite struct ItemIDTests {
    @Test(arguments: [
        ItemID.root, .albums, .timeline, .favorites, .people,
        .album("f0b9c2d8-e4cc-4bdb-9c36-cda764479bd0"),
        .year(2024),
        .month(YearMonth(year: 2024, month: 5)),
        .person("a109aeb4"),
        .asset(parent: .album("abc"), id: "efa7c20c"),
        .asset(parent: .month(YearMonth(year: 1999, month: 12)), id: "x"),
        .asset(parent: .favorites, id: "y"),
    ])
    func roundTrips(id: ItemID) {
        #expect(ItemID(rawValue: id.rawValue) == id)
    }

    @Test(arguments: ["", "album:", "year:abc", "month:2024-13", "month:2024-5", "asset:album:x", "asset:album:x/", "nope:1"])
    func rejectsMalformed(raw: String) {
        #expect(ItemID(rawValue: raw) == nil)
    }

    @Test func parents() {
        #expect(ItemID.month(YearMonth(year: 2024, month: 5)).parent == .year(2024))
        #expect(ItemID.asset(parent: .person("p"), id: "a").parent == .person("p"))
        #expect(ItemID.asset(parent: .month(YearMonth(year: 2024, month: 5)), id: "a").depth == 4)
    }
}

@Suite struct FilenameTests {
    @Test func sanitizes() {
        #expect(sanitizeFilename("Trip 2024/25") == "Trip 2024-25")
        #expect(sanitizeFilename("  ") == "Untitled")
        #expect(sanitizeFilename(".hidden") == "_hidden")
        #expect(sanitizeFilename("a:b") == "a-b")
    }

    @Test func uniquifiesCaseInsensitively() {
        let entries = [
            Entry(id: .asset(parent: .favorites, id: "11111111-aaaa"), filename: "IMG_0001.JPG"),
            Entry(id: .asset(parent: .favorites, id: "22222222-bbbb"), filename: "img_0001.jpg"),
            Entry(id: .asset(parent: .favorites, id: "33333333-cccc"), filename: "IMG_0002.JPG"),
            Entry(id: .album("44444444-dddd"), filename: "Holiday"),
            Entry(id: .album("55555555-eeee"), filename: "Holiday"),
        ]
        #expect(uniquifyFilenames(entries).map(\.filename) == [
            "IMG_0001.JPG", "img_0001 (22222222).jpg", "IMG_0002.JPG", "Holiday", "Holiday (55555555)",
        ])
    }

    @Test func uniquifiesNestedTagsAndFilesWithCollidingIDSuffixes() {
        let parent = ItemID.tag(parent: .tags, id: "parent")
        let entries = [
            Entry.folder(.tag(parent: parent, id: "folder-a"), name: "Photo.jpg"),
            Entry.folder(.tag(parent: parent, id: "folder-b"), name: "photo.jpg"),
            Entry(id: .asset(parent: parent, id: "12345678-one"), filename: "Photo.jpg"),
            Entry(id: .asset(parent: parent, id: "12345678-two"), filename: "Photo.jpg"),
        ]
        let filenames = uniquifyFilenames(entries).map(\.filename)
        #expect(filenames == ["Photo.jpg", "photo.jpg (folder-b)", "Photo (12345678).jpg", "Photo (12345678-2).jpg"])
        #expect(filenames.allSatisfy { !$0.contains("/") })
        #expect(Set(filenames.map { $0.lowercased() }).count == entries.count)
    }
}

@Suite struct DecodingTests {
    @Test func decodesSearchResponse() throws {
        let json = """
        {"albums":{"total":0,"count":0,"items":[]},"assets":{"total":1,"count":1,"nextPage":"2","items":[{
          "id":"efa7c20c-5967-4ce0-913b-4d4f4260d853","ownerId":"u1","type":"IMAGE",
          "originalFileName":"IMG_1.JPG","originalMimeType":"image/jpeg",
          "fileCreatedAt":"2024-10-28T15:02:50.000Z","fileModifiedAt":"2024-10-28T19:02:50Z",
          "localDateTime":"2024-10-28T11:02:50.000Z","updatedAt":"2026-10-06T22:01:21.675Z",
          "checksum":"6kdADPuQ2in2a7p9pe7x4W28ncM=","visibility":"timeline",
          "exifInfo":{"fileSizeInByte":14291790,"make":"Canon"},"people":[]}]}}
        """
        let response = try ImmichClient.decoder.decode(ImmichSearchResponse.self, from: Data(json.utf8))
        let asset = try #require(response.assets.items.first)
        #expect(response.assets.nextPage == "2")
        #expect(asset.exifInfo?.fileSizeInByte == 14_291_790)
        #expect(asset.fileCreatedAt == Date(timeIntervalSince1970: 1_730_127_770))
        #expect(YearMonth(prefixOf: asset.localDateTime) == YearMonth(year: 2024, month: 10))

        let entry = Entry.asset(asset, in: .favorites)
        #expect(entry.id == .asset(parent: .favorites, id: asset.id))
        #expect(entry.size == 14_291_790)
    }

    @Test func normalizesServerURLs() {
        #expect(ImmichClient.normalizeServerURL("photos.example.com")?.absoluteString == "https://photos.example.com")
        #expect(ImmichClient.normalizeServerURL("http://10.0.0.5:2283/api/")?.absoluteString == "http://10.0.0.5:2283")
        #expect(ImmichClient.normalizeServerURL("ftp://x") == nil)
        #expect(ImmichClient.normalizeServerURL("") == nil)
    }

    @Test func buildsRequests() {
        let client = ImmichClient(serverURL: URL(string: "https://photos.example.com")!, apiKey: "k")
        let request = client.originalRequest(assetID: "a", base: client.serverURL, timeout: 5)
        #expect(request.url?.absoluteString == "https://photos.example.com/api/assets/a/original")
        #expect(request.value(forHTTPHeaderField: "x-api-key") == "k")
        #expect(request.timeoutInterval == 5)
    }

    @Test func monthWindowCoversTimezones() {
        let search = Catalog.monthSearch(YearMonth(year: 2024, month: 12))
        #expect(search.takenAfter == ISO8601DateFormatter().date(from: "2024-11-30T00:00:00Z"))
        #expect(search.takenBefore == ISO8601DateFormatter().date(from: "2025-01-02T00:00:00Z"))
    }
}

@Suite struct ProfileTests {
    let remote = URL(string: "https://photos.example.com")!
    let local = URL(string: "http://192.168.1.10:2283")!

    @Test func picksLocalURLOnlyOnListedNetworks() {
        let profile = ServerProfile(serverURL: remote, localServerURL: local, localNetworks: ["Home"], userID: "u1")
        #expect(profile.isLocal(ssid: "Home"))
        #expect(!profile.isLocal(ssid: "Cafe"))
        #expect(!profile.isLocal(ssid: nil))
        #expect(profile.serverURL(onLocalNetwork: true) == local)
        #expect(profile.serverURL(onLocalNetwork: false) == remote)

        let noLocalURL = ServerProfile(serverURL: remote, localNetworks: ["Home"], userID: "u1")
        #expect(!noLocalURL.isLocal(ssid: "Home"))
        #expect(noLocalURL.serverURL(onLocalNetwork: true) == remote)
    }

    @Test func fallsBackFromLocalToRemoteButNeverTheOtherWay() {
        let profile = ServerProfile(serverURL: remote, localServerURL: local, localNetworks: ["Home"], userID: "u1")
        #expect(profile.endpoints(onLocalNetwork: true) == [local, remote])
        #expect(profile.endpoints(onLocalNetwork: false) == [remote])
        #expect(ServerProfile(serverURL: remote, userID: "u1").endpoints(onLocalNetwork: true) == [remote])
    }

    @Test func decodesProfilesWithMissingOrExtraFields() throws {
        let json = #"{"id":"immich-1","serverURL":"https://photos.example.com","userID":"u1","futureField":42}"#
        let profile = try JSONDecoder().decode(ServerProfile.self, from: Data(json.utf8))
        #expect(profile.localServerURL == nil)
        #expect(profile.localNetworks.isEmpty)
        #expect(profile.userID == "u1")
    }

    @Test func roundTripsThroughJSON() throws {
        let profile = ServerProfile(id: "immich-1", serverURL: remote, localServerURL: local, localNetworks: ["Home"], userID: "u1")
        let decoded = try JSONDecoder().decode(ServerProfile.self, from: JSONEncoder().encode(profile))
        #expect(decoded == profile)
    }
}

@Suite struct SettingsStoreTests {
    func makeStore() -> SettingsStore {
        SettingsStore(defaults: UserDefaults(suiteName: "immount-tests-\(UUID().uuidString)")!)
    }

    @Test func aProfileWithoutUserIsUnreadableAndKeptAsIs() {
        let store = makeStore()
        let stored = Data(#"{"id":"immich-abc","serverURL":"https://photos.example.com"}"#.utf8)
        store.defaults.set(stored, forKey: "profile")
        store.isConnectionEnabled = true
        #expect(store.loadProfile() == nil)
        #expect(store.profileData == stored)
        #expect(store.isConnectionEnabled)
    }

    @Test func disconnectingKeepsTheProfileAndForgettingRemovesIt() {
        let store = makeStore()
        store.saveProfile(ServerProfile(serverURL: URL(string: "https://photos.example.com")!, userID: "u1"))
        store.isConnectionEnabled = true
        store.isConnectionEnabled = false
        #expect(store.loadProfile() != nil)
        store.removeProfile()
        #expect(store.loadProfile() == nil)
        #expect(!store.isConnectionEnabled)
    }

    @Test func countsCredentialChanges() {
        let store = makeStore()
        #expect(store.credentialsGeneration == 0)
        store.bumpCredentialsGeneration()
        store.bumpCredentialsGeneration()
        #expect(store.credentialsGeneration == 2)
    }
}

@Suite struct ClientTests {
    let remote = URL(string: "https://photos.example.com")!
    let local = URL(string: "http://192.168.1.10:2283")!

    func response(_ status: Int) -> HTTPURLResponse {
        HTTPURLResponse(url: remote, statusCode: status, httpVersion: nil, headerFields: nil)!
    }

    func validationError(_ status: Int, _ body: String) -> ImmichError? {
        do {
            try ImmichClient.validate(response(status), data: Data(body.utf8))
            return nil
        } catch {
            return error as? ImmichError
        }
    }

    @Test func mapsServerErrors() {
        #expect(validationError(401, #"{"message":"Invalid API key"}"#) == .unauthorized)
        #expect(validationError(403, #"{"message":"Missing required permission: asset.download"}"#) == .missingPermission("Missing required permission: asset.download"))
        #expect(validationError(400, #"{"message":"Not found or no album.read access"}"#) == .notFound)
        #expect(validationError(404, #"{"message":"Not Found"}"#) == .notFound)
        #expect(validationError(400, #"{"message":["size must not be greater than 1000"]}"#) == .http(status: 400, message: "size must not be greater than 1000"))
        #expect(validationError(200, "") == nil)
    }

    @Test func resolvesEndpointsPerRequest() {
        let useLocal = OSAllocatedUnfairLock(initialState: false)
        let client = ImmichClient(apiKey: "k") { useLocal.withLock { $0 } ? [local, remote] : [remote] }
        #expect(client.request("users/me").url?.host() == "photos.example.com")
        useLocal.withLock { $0 = true }
        #expect(client.request("users/me").url?.absoluteString == "http://192.168.1.10:2283/api/users/me")
    }

    @Test func fallsBackOnlyWhenTheAddressCannotBeReached() async throws {
        let local = URL(string: "http://192.0.2.\(Int.random(in: 1...254)):2283")!
        let client = ImmichClient(apiKey: "k") { [local, remote] }
        Reachability.shared.record(local, reachable: true)

        nonisolated(unsafe) var attempts: [URL] = []
        let result = try await client.withFallback { base in
            attempts.append(base)
            if base == local { throw URLError(.cannotConnectToHost) }
            return "ok"
        }
        #expect(result == "ok")
        #expect(attempts == [local, remote])
        // The failure is remembered, so the next request goes straight to the server URL.
        #expect(Reachability.shared.cached(local) == false)

        // A slow answer is not a reason to switch servers.
        Reachability.shared.record(local, reachable: true)
        await #expect(throws: URLError(.timedOut)) {
            try await client.withFallback { base -> String in
                if base == local { throw URLError(.timedOut) }
                return "remote"
            }
        }
        await #expect(throws: ImmichError.unauthorized) {
            try await client.withFallback { _ -> String in throw ImmichError.unauthorized }
        }
    }

    @Test func rejectsURLsWithCredentials() {
        #expect(ImmichClient.normalizeServerURL("https://user:pass@photos.example.com") == nil)
    }

    @Test func reportsMissingPermissions() {
        #expect(ImmichAPIKey(name: "k", permissions: ["all"]).missingPermissions.isEmpty)
        #expect(ImmichAPIKey(name: "k", permissions: ["asset.read", "album.read"]).missingPermissions
            == ["asset.view", "asset.download", "person.read", "tag.read", "user.read"])
    }

    @Test func formatsServerVersions() {
        #expect(ImmichServerVersion(major: 3, minor: 3, patch: 0, prerelease: 2).description == "3.3.0-rc.2")
        #expect(ImmichServerVersion(major: 3, minor: 2, patch: 4).isAtLeast(major: 3, minor: 2))
        #expect(!ImmichServerVersion(major: 2, minor: 9, patch: 0).isAtLeast(major: 3, minor: 2))
    }

    func json(_ body: some Encodable) throws -> [String: Any] {
        try JSONSerialization.jsonObject(with: ImmichClient.encoder.encode(body)) as! [String: Any]
    }

    @Test func encodesFilterSearches() throws {
        let query = AssetQuery(albumIDs: ["a"], takenAfter: Date(timeIntervalSince1970: 0), visibility: "timeline")
        let body = try json(FilterSearchBody(query: query, cursor: "next"))
        #expect(body["cursor"] as? String == "next")
        #expect(body["size"] as? Int == 1000)
        #expect(body["page"] == nil)
        let filter = try #require(body["filter"] as? [String: Any])
        #expect((filter["albumIds"] as? [String: Any])?["any"] as? [String] == ["a"])
        #expect((filter["takenAt"] as? [String: Any])?["gte"] as? String == "1970-01-01T00:00:00Z")
        #expect((filter["visibility"] as? [String: Any])?["eq"] as? String == "timeline")
        #expect((filter["trashedAt"] as? [String: Any])?["eq"] is NSNull)
        #expect((filter["isOffline"] as? [String: Any])?["eq"] as? Bool == false)
        #expect(filter["personIds"] == nil)

        let browsable = try json(FilterSearchBody(query: AssetQuery(isFavorite: true)))
        let browsableFilter = try #require(browsable["filter"] as? [String: Any])
        #expect((browsableFilter["visibility"] as? [String: Any])?["in"] as? [String] == ["timeline", "archive"])
        #expect((browsableFilter["isFavorite"] as? [String: Any])?["eq"] as? Bool == true)
    }

    @Test func encodesLegacySearches() throws {
        let body = try json(LegacySearchBody(AssetQuery(personIDs: ["p"]), page: 3))
        #expect(body["personIds"] as? [String] == ["p"])
        #expect(body["page"] as? Int == 3)
        #expect(body["withExif"] as? Bool == true)
        #expect(body["filter"] == nil)
    }
}

@Suite struct ListingStoreTests {
    func makeStore() -> ListingStore {
        ListingStore(directory: FileManager.default.temporaryDirectory.appending(path: "immount-tests-\(UUID().uuidString)"))
    }

    func photo(_ id: String, in parent: ItemID, name: String? = nil) -> Entry {
        Entry(id: .asset(parent: parent, id: id), filename: name ?? "\(id).jpg")
    }

    /// A store that has handed out root, Favorites and one album.
    func seededStore() async -> ListingStore {
        let store = makeStore()
        await store.save(Catalog.rootFolders, for: .root)
        await store.save([Entry(id: .album("x"), filename: "Trip")], for: .albums)
        await store.save([photo("a", in: .favorites), photo("b", in: .favorites)], for: .favorites)
        await store.save([photo("p", in: .album("x"))], for: .album("x"))
        return store
    }

    @Test func reportsChangesOnlyAfterCommit() async {
        let store = await seededStore()
        let before = await store.anchor
        let (refresh, error) = await store.prepareRefresh { container in
            switch container {
            case .root: Catalog.rootFolders
            case .albums: [Entry(id: .album("x"), filename: "Trip")]
            case .favorites: [photo("a", in: .favorites, name: "renamed.jpg"), photo("c", in: .favorites)]
            default: [photo("p", in: .album("x"))]
            }
        }
        #expect(error == nil)
        // Deletions come first, so a freed-up name is gone before a sibling takes it.
        #expect(refresh.changes.map(\.description) == ["delete:asset:favorites/b", "update:asset:favorites/a", "update:asset:favorites/c"])
        // Nothing is saved until the system has the changes.
        #expect(await store.listing(for: .favorites)?.count == 2)
        #expect(await isStart(store.resumePoint(before)))

        let after = await store.commit(refresh)
        #expect(after != before)
        #expect(await store.listing(for: .favorites)?.map(\.filename) == ["renamed.jpg", "c.jpg"])
        // An anchor from before the refresh can no longer resume: start over instead of losing changes.
        #expect(await store.resumePoint(before) == nil)
        #expect(await store.isValid(before))
    }

    @Test func commitsWithoutNewGenerationWhenNothingChanged() async {
        let store = await seededStore()
        let before = await store.anchor
        let (refresh, _) = await store.prepareRefresh { container in
            await store.listing(for: container) ?? []
        }
        #expect(refresh.changes.isEmpty)
        #expect(await store.commit(refresh) == before)
    }

    @Test func dropsRemovedFoldersAndTheirListings() async {
        let store = await seededStore()
        let (refresh, _) = await store.prepareRefresh { container in
            if container == .albums { return [] }
            return await store.listing(for: container) ?? []
        }
        #expect(refresh.changes == [.delete(.album("x"))])
        _ = await store.commit(refresh)
        #expect(await store.listing(for: .album("x")) == nil)
        #expect(Set(await store.containers()) == [.root, .albums, .favorites])
    }

    @Test func dropsADeletedAlbumButNeverAPermanentFolder() async {
        let store = await seededStore()
        let (refresh, error) = await store.prepareRefresh { container in
            switch container {
            case .album: throw ImmichError.notFound
            case .favorites: throw ImmichError.notFound
            default: return await store.listing(for: container) ?? []
            }
        }
        #expect(error as? ImmichError == .notFound)
        #expect(refresh.changes == [.delete(.asset(parent: .album("x"), id: "p"))])
        _ = await store.commit(refresh)
        #expect(await store.listing(for: .favorites)?.count == 2)
    }

    @Test func ignoresARefreshWhereEverythingIsNotFound() async {
        let store = await seededStore()
        let (refresh, error) = await store.prepareRefresh { container in
            if container == .root { return Catalog.rootFolders }
            throw ImmichError.notFound
        }
        #expect(refresh.changes.isEmpty)
        #expect(error as? ImmichError == .notFound)
    }

    @Test func resumesOnlyTheRefreshABatchBelongsTo() async {
        let store = await seededStore()
        let (refresh, _) = await store.prepareRefresh { _ in [] }
        #expect(refresh.changes.count == Catalog.rootFolders.count) // Their children go with them.
        let middle = await store.anchor(for: refresh, offset: 2)
        guard case .batch(let pending, let offset)? = await store.resumePoint(middle) else {
            Issue.record("expected a batch")
            return
        }
        #expect(pending.id == refresh.id)
        #expect(offset == 2)

        // Concurrent signals reuse the frozen refresh until its final batch commits.
        let (joined, _) = await store.prepareRefresh { _ in [] }
        #expect(joined.id == refresh.id)
        guard case .batch(let resumed, _)? = await store.resumePoint(middle) else {
            Issue.record("expected the frozen batch to remain resumable")
            return
        }
        #expect(resumed.id == refresh.id)
        _ = await store.commit(refresh)
        #expect(await store.resumePoint(middle) == nil)
        #expect(await store.resumePoint(Data("garbage".utf8)) == nil)
        #expect(await store.resumePoint(Data("\(UUID().uuidString):0".utf8)) == nil)
    }

    @Test func epochsSurviveReopeningButNotRecreating() async {
        let directory = FileManager.default.temporaryDirectory.appending(path: "immount-tests-\(UUID().uuidString)")
        let first = await ListingStore(directory: directory).anchor
        #expect(await ListingStore(directory: directory).isValid(first))
        #expect(await !makeStore().isValid(first))
    }
}

@Suite struct SafetyTests {
    let saved = URL(string: "https://photos.example.com")!

    @Test func reusesTheSavedKeyOnlyForTheSameServer() {
        #expect(ServerProfile.canReuseKey(from: saved, to: URL(string: "https://PHOTOS.example.com")!))
        #expect(ServerProfile.canReuseKey(from: URL(string: "http://nas.local:2283")!, to: URL(string: "https://nas.local")!))
        #expect(!ServerProfile.canReuseKey(from: saved, to: URL(string: "https://photos.exmaple.com")!))
        #expect(!ServerProfile.canReuseKey(from: saved, to: URL(string: "http://photos.example.com")!))
        #expect(!ServerProfile.canReuseKey(from: saved, to: URL(string: "https://photos.example.com:8443")!))
    }

    @Test func followsOnlySafeRedirects() {
        let from = URL(string: "http://nas.local:2283/api/users/me")!
        #expect(ImmichSession.isSafeRedirect(from: from, to: URL(string: "http://nas.local:2283/api/users/me/")!))
        #expect(ImmichSession.isSafeRedirect(from: from, to: URL(string: "https://nas.local/api/users/me")!))
        #expect(!ImmichSession.isSafeRedirect(from: from, to: URL(string: "https://evil.example/api")!))
        #expect(!ImmichSession.isSafeRedirect(from: URL(string: "https://nas.local/a")!, to: URL(string: "http://nas.local/a")!))
    }

    @Test func treatsOnlyImmichNotFoundAsDeletion() {
        func error(_ status: Int, _ body: String) -> ImmichError? {
            let response = HTTPURLResponse(url: saved, statusCode: status, httpVersion: nil, headerFields: nil)!
            do { try ImmichClient.validate(response, data: Data(body.utf8)); return nil } catch { return error as? ImmichError }
        }
        #expect(error(404, #"{"message":"Asset media not found"}"#) == .notFound)
        #expect(error(404, "404 page not found") == .http(status: 404, message: nil))
        #expect(error(404, #"{"message":"Cannot GET /api/albums"}"#) == .http(status: 404, message: "Cannot GET /api/albums"))
        #expect(error(302, "") == .redirected)
    }

    @Test func localNetworkLeaseExpires() {
        let store = SettingsStore(defaults: UserDefaults(suiteName: "immount-tests-\(UUID().uuidString)")!)
        #expect(!store.isOnLocalNetwork)
        store.confirmLocalNetwork()
        #expect(store.isOnLocalNetwork)
        store.defaults.set(Date.now.addingTimeInterval(-1), forKey: "localNetworkUntil")
        #expect(!store.isOnLocalNetwork)
        store.confirmLocalNetwork()
        store.defaults.set("another-boot", forKey: "localNetworkBootSession")
        #expect(!store.isOnLocalNetwork)
        store.clearLocalNetwork()
        #expect(store.defaults.object(forKey: "localNetworkUntil") == nil)
    }
}

func isStart(_ point: ListingStore.ResumePoint?) -> Bool {
    if case .start? = point { return true }
    return false
}

extension Change: CustomStringConvertible {
    public var description: String {
        switch self {
        case .update(let entry): "update:\(entry.id.rawValue)"
        case .delete(let id): "delete:\(id.rawValue)"
        }
    }
}

/// Hits a real server. Run with:
/// `IMMICH_URL=https://demo.immich.app IMMICH_API_KEY=... swift test`
@Suite(.enabled(if: ProcessInfo.processInfo.environment["IMMICH_API_KEY"] != nil))
struct LiveServerTests {
    let client = ImmichClient(
        serverURL: ImmichClient.normalizeServerURL(ProcessInfo.processInfo.environment["IMMICH_URL"] ?? "")!,
        apiKey: ProcessInfo.processInfo.environment["IMMICH_API_KEY"] ?? ""
    )

    @Test func validatesTheKey() async throws {
        let key = try await client.apiKeyInfo()
        #expect(key.missingPermissions.isEmpty)
        try await client.ping()
        #expect(try await client.serverVersion().major >= 2)
    }

    @Test func walksTheTree() async throws {
        let catalog = Catalog(client: client, ownerID: try await client.currentUser().id)
        let roots = try await catalog.children(of: .root)
        #expect(Set(roots.map(\.id)) == [.albums, .favorites, .people, .tags, .timeline])

        let albums = try await catalog.children(of: .albums)
        if let album = albums.first {
            let photos = try await catalog.children(of: album.id)
            #expect(photos.count == album.childCount)
            #expect(Set(photos.map { $0.filename.lowercased() }).count == photos.count)
            #expect(try await catalog.entry(for: album.id).filename == album.filename)
        }

        let years = try await catalog.children(of: .timeline)
        let year = try #require(years.first)
        let months = try await catalog.children(of: year.id)
        let month = try #require(months.first)
        for month in months.prefix(3) {
            let photos = try await catalog.children(of: month.id)
            #expect(photos.count == month.childCount, "\(month.filename)")
            if let photo = photos.first {
                #expect(try await catalog.entry(for: photo.id) == photo)
            }
        }

        _ = try await catalog.children(of: .favorites)

        let tags = try await catalog.children(of: .tags)
        if let tag = tags.first {
            let tagged = try await catalog.children(of: tag.id)
            #expect(tagged.allSatisfy { $0.parent == tag.id })
            #expect(Set(tagged.map { $0.filename.lowercased() }).count == tagged.count)
            #expect(try await catalog.entry(for: tag.id) == tag)
        }

        // Originals download completely with progress; a missing one maps to notFound.
        let photo = try #require(try await catalog.children(of: month.id).first)
        let destination = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let progress = Progress(totalUnitCount: 100)
        try await client.downloadOriginal(assetID: try #require(photo.id.assetID), to: destination, progress: progress)
        #expect(Int64(try destination.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) == photo.size)
        #expect(progress.completedUnitCount == 100)
        await #expect(throws: ImmichError.notFound) {
            try await client.downloadOriginal(assetID: "00000000-0000-4000-8000-000000000000", to: destination.appendingPathExtension("x"))
        }
        #expect(try await client.thumbnail(assetID: try #require(photo.id.assetID), large: false).count > 0)
        await #expect(throws: ImmichError.notFound) {
            try await catalog.entry(for: .album("00000000-0000-4000-8000-000000000000"))
        }
    }
}

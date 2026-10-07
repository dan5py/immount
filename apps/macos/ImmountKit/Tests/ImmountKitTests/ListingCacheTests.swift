import Foundation
import Testing
@testable import ImmountKit

@Suite struct ListingCacheTests {
    private let limit = ListingStore.CacheLimit(listings: 2, entries: 5)

    @Test func keepsOnlyRecentlyUsedListingsAndRereadsTheRestFromDisk() async {
        let directory = directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ListingStore(directory: directory, cacheLimit: limit)
        let albums = (0..<4).map { ItemID.album(String($0)) }
        for album in albums { await store.save(photos(2, in: album), for: album) }
        #expect(await store.cachedContainers == Set(albums.suffix(2)))

        #expect(await store.listing(for: albums[0]) == photos(2, in: albums[0]))
        #expect(await store.cachedContainers == [albums[0], albums[3]])
        // Evicted listings are still found, and an identical save is not a change.
        await store.save(photos(2, in: albums[1]), for: albums[1])
        #expect(await store.cachedContainers == [albums[0], albums[1]])
        #expect(await store.entry(for: .asset(parent: albums[2], id: "1"))?.filename == "1.jpg")
    }

    @Test func listingLargerThanTheLimitStaysUntilTheNextOne() async {
        let directory = directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ListingStore(directory: directory, cacheLimit: limit)
        let large = ItemID.album("large")
        await store.save(photos(2, in: .favorites), for: .favorites)
        await store.save(photos(8, in: large), for: large)
        #expect(await store.cachedContainers == [large])
        await store.save(photos(1, in: .favorites), for: .favorites)
        #expect(await store.cachedContainers == [.favorites])
    }

    @Test func workingSetEnumerationDoesNotFillTheCache() async {
        let directory = directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let albums = (0..<4).map { ItemID.album(String($0)) }
        let writer = ListingStore(directory: directory)
        await writer.save(albums.map { .folder($0, name: $0.rawValue) }, for: .albums)
        for album in albums { await writer.save(photos(2, in: album), for: album) }

        let store = ListingStore(directory: directory, cacheLimit: limit)
        let all = await store.allEntries()
        #expect(all.count == 4 + 4 * 2)
        #expect(Set(all.map(\.id)) == Set(albums + albums.flatMap { album in photos(2, in: album).map(\.id) }))
        #expect(await store.cachedContainers.isEmpty)
    }

    @Test func refreshAfterEvictionComparesWithTheStoredListings() async {
        let directory = directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ListingStore(directory: directory, cacheLimit: limit)
        let albums = (0..<4).map { ItemID.album(String($0)) }
        var listings: [ItemID: [Entry]] = [.root: Catalog.rootFolders, .albums: albums.map { .folder($0, name: $0.rawValue) }]
        for album in albums { listings[album] = photos(2, in: album) }
        for (id, entries) in listings { await store.save(entries, for: id) }

        let before = listings
        let (unchanged, _) = await store.prepareRefresh(mode: .full) { before[$0] ?? [] }
        #expect(unchanged.changes.isEmpty)
        #expect(await store.commitWithResult(unchanged).committed)

        let added = Entry(id: .asset(parent: albums[0], id: "new"), filename: "new.jpg")
        listings[albums[0]]?.append(added)
        let after = listings
        let (changed, _) = await store.prepareRefresh(mode: .full) { after[$0] ?? [] }
        #expect(changed.changes == [.update(added)])
        #expect(await store.commitWithResult(changed).committed)
        #expect(await store.cachedContainers.count <= limit.listings)
        #expect(await ListingStore(directory: directory).listing(for: albums[0]) == listings[albums[0]])
    }

    @Test func unsavedListingIsNeverEvicted() async throws {
        let directory = directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ListingStore(directory: directory, cacheLimit: limit)
        let unsaved = ItemID.album("unsaved")
        let destination = directory.appending(path: "listings")
            .appending(path: Data(unsaved.rawValue.utf8).base64URLEncodedString() + ".json")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
        await store.save(photos(2, in: unsaved), for: unsaved)
        for album in (0..<4).map({ ItemID.album(String($0)) }) { await store.save(photos(2, in: album), for: album) }

        #expect(await store.cachedContainers.contains(unsaved))
        #expect(await store.listing(for: unsaved) == photos(2, in: unsaved))
        #expect(await store.containers().contains(unsaved))
        #expect(await store.allEntries().contains(photos(2, in: unsaved)[0]))

        try FileManager.default.removeItem(at: destination)
        await store.save(photos(2, in: unsaved), for: unsaved)
        await store.save(photos(2, in: .favorites), for: .favorites)
        await store.save(photos(2, in: .album("later")), for: .album("later"))
        #expect(await !store.cachedContainers.contains(unsaved))
        #expect(await store.listing(for: unsaved) == photos(2, in: unsaved))
    }

    private func photos(_ count: Int, in parent: ItemID) -> [Entry] {
        (0..<count).map { Entry(id: .asset(parent: parent, id: String($0)), filename: "\($0).jpg", contentVersion: String($0)) }
    }

    private func directory() -> URL {
        FileManager.default.temporaryDirectory.appending(path: "immount-listing-cache-\(UUID().uuidString)")
    }
}

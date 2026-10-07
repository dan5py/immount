import Foundation
import Testing
@testable import ImmountKit

@Suite struct TagsRefreshTests {
    @Test(arguments: [ImmichError.missingPermission("tag.read"), .notFound])
    func existingDomainGainsTagsWhenRemoteListingsFail(_ failure: ImmichError) async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ListingStore(directory: directory)
        let legacyRoot = Catalog.rootFolders.filter { $0.id != .tags }
        let original = photo("original", in: .favorites)
        await store.save(legacyRoot, for: .root)
        await store.save([original], for: .favorites)
        let originalAnchor = await store.anchor
        #expect(await store.needsRootRefresh(Catalog.rootFolders))

        let (refresh, error) = await store.prepareRefresh { container in
            if container == .root { return Catalog.rootFolders }
            throw failure
        }
        let tags = try #require(Catalog.rootFolders.first { $0.id == .tags })
        #expect(error as? ImmichError == failure)
        #expect(refresh.changes == [.update(tags)])
        #expect(await store.listing(for: .root) == legacyRoot)
        #expect(await store.anchor == originalAnchor)
        let batch = await store.anchor(for: refresh, offset: 0)
        guard case .batch(let pending, let offset)? = await store.resumePoint(batch) else {
            Issue.record("Expected the root addition to use normal resumable refresh anchors")
            return
        }
        #expect(pending.id == refresh.id)
        #expect(offset == 0)

        let committed = await store.commit(refresh)
        let reopened = ListingStore(directory: directory)
        #expect(await reopened.anchor == committed)
        #expect(await !reopened.needsRootRefresh(Catalog.rootFolders))
        #expect(await reopened.listing(for: .root) == Catalog.rootFolders)
        #expect(await reopened.listing(for: .favorites) == [original])
        #expect(await reopened.isValid(originalAnchor))
    }

    @Test func rootAdditionSharesAnOutstandingMetadataReplay() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ListingStore(directory: directory)
        let legacyRoot = Catalog.rootFolders.filter { $0.id != .tags }
        let original = photo("original", in: .favorites)
        await store.save(legacyRoot, for: .root)
        await store.save([original], for: .favorites)

        let refresh = try #require(await store.prepareMetadataRefresh(
            revision: 1, root: Catalog.rootEntry, addingRootFolders: Catalog.rootFolders
        ))
        let updates = refresh.changes.compactMap { change -> Entry? in
            if case .update(let entry) = change { return entry }
            return nil
        }
        #expect(updates.count == Set(updates.map(\.id)).count)
        #expect(updates.contains { $0.id == .tags })
        #expect(updates.contains(original))
        #expect(await store.listing(for: .root) == legacyRoot)

        _ = await store.commit(refresh)
        let reopened = ListingStore(directory: directory)
        #expect(await !reopened.needsMetadataRefresh(revision: 1))
        #expect(await !reopened.needsRootRefresh(Catalog.rootFolders))
        #expect(await reopened.listing(for: .favorites) == [original])
    }

    @Test func renamingNestedTagRetainsItsIdentityAndDownloadedEntries() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ListingStore(directory: directory)
        let parent = ItemID.tag(parent: .tags, id: "parent")
        let child = ItemID.tag(parent: parent, id: "child")
        let original = photo("original", in: child)
        await store.save(Catalog.rootFolders, for: .root)
        await store.save([.folder(parent, name: "Places")], for: .tags)
        await store.save([.folder(child, name: "Old name")], for: parent)
        await store.save([original], for: child)
        let renamed = Entry.folder(child, name: "New name")

        let (refresh, error) = await store.prepareRefresh { container in
            if container == parent { return [renamed] }
            return await store.listing(for: container) ?? []
        }
        #expect(error == nil)
        #expect(refresh.changes == [.update(renamed)])
        _ = await store.commit(refresh)

        let reopened = ListingStore(directory: directory)
        #expect(await reopened.entry(for: child) == renamed)
        #expect(await reopened.listing(for: child) == [original])
    }

    @Test func deletingParentTagDropsItsNestedListingsWithoutResurrection() async {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ListingStore(directory: directory)
        let parent = ItemID.tag(parent: .tags, id: "parent")
        let child = ItemID.tag(parent: parent, id: "child")
        await store.save(Catalog.rootFolders, for: .root)
        await store.save([.folder(parent, name: "Places")], for: .tags)
        await store.save([.folder(child, name: "Mountains")], for: parent)
        await store.save([photo("original", in: child)], for: child)
        let (refresh, error) = await store.prepareRefresh { container in
            if container == .tags { return [] }
            // Descendant fetches can race with the deletion and return stale data.
            return await store.listing(for: container) ?? []
        }
        #expect(error == nil)
        #expect(refresh.changes == [.delete(parent)])
        _ = await store.commit(refresh)
        let reopened = ListingStore(directory: directory)
        #expect(await reopened.listing(for: .tags) == [])
        #expect(await reopened.listing(for: parent) == nil)
        #expect(await reopened.listing(for: child) == nil)
        #expect(Set(await reopened.containers()) == [.root, .tags])
    }

    @Test(arguments: [ImmichError.missingPermission("tag.read"), .notFound])
    func failedTagListingPreservesKnownFolders(_ failure: ImmichError) async {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ListingStore(directory: directory)
        let tag = ItemID.tag(parent: .tags, id: "tag")
        let entries = [Entry.folder(tag, name: "Places")]
        let originals = [photo("original", in: tag)]
        await store.save(Catalog.rootFolders, for: .root)
        await store.save(entries, for: .tags)
        await store.save(originals, for: tag)

        let (refresh, error) = await store.prepareRefresh { container in
            if container == .tags || (container == tag && failure != .notFound) { throw failure }
            return await store.listing(for: container) ?? []
        }
        #expect(error as? ImmichError == failure)
        #expect(refresh.changes.isEmpty)
        _ = await store.commit(refresh)
        let reopened = ListingStore(directory: directory)
        #expect(await reopened.listing(for: .tags) == entries)
        #expect(await reopened.listing(for: tag) == originals)
    }

    @Test func deepTagListingsUseBoundedFilenamesAndSurviveRefresh() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ListingStore(directory: directory)
        await store.save(Catalog.rootFolders, for: .root)
        var parent = ItemID.tags
        var tags: [ItemID] = []
        for level in 0..<12 {
            let child = ItemID.tag(parent: parent, id: UUID().uuidString)
            tags.append(child)
            await store.save([.folder(child, name: "Level \(level)")], for: parent)
            parent = child
        }
        let deepest = try #require(tags.last)
        await store.save([], for: deepest)
        let assetParent = tags[tags.count - 2]
        let childEntry = try #require(await store.listing(for: assetParent)?.first)
        let original = photo("original", in: assetParent)
        await store.save([childEntry, original], for: assetParent)
        #expect(Data(deepest.rawValue.utf8).base64URLEncodedString().utf8.count > 255)

        let files = try FileManager.default.contentsOfDirectory(
            at: directory.appending(path: "listings"), includingPropertiesForKeys: nil
        )
        #expect(files.allSatisfy { $0.lastPathComponent.utf8.count <= 255 })
        #expect(files.filter { $0.lastPathComponent.hasPrefix("tag-") }.count == tags.count)
        let reopened = ListingStore(directory: directory)
        #expect(Set(await reopened.containers()) == Set([.root, .tags] + tags))
        #expect(await reopened.listing(for: deepest) == [])
        #expect(await reopened.listing(for: assetParent) == [childEntry, original])
        #expect(await reopened.allEntries().contains(original))

        let renamed = Entry(id: original.id, filename: "renamed.jpg", contentVersion: original.contentVersion)
        let (refresh, error) = await reopened.prepareRefresh { container in
            if container == assetParent { return [childEntry, renamed] }
            return await reopened.listing(for: container) ?? []
        }
        #expect(error == nil)
        #expect(refresh.changes == [.update(renamed)])
        _ = await reopened.commit(refresh)
        let finalStore = ListingStore(directory: directory)
        #expect(await finalStore.listing(for: deepest) == [])
        #expect(await finalStore.listing(for: assetParent) == [childEntry, renamed])
    }

    private func photo(_ id: String, in parent: ItemID) -> Entry {
        Entry(id: .asset(parent: parent, id: id), filename: "\(id).jpg", contentVersion: "original-checksum")
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appending(path: "immount-tag-refresh-\(UUID().uuidString)")
    }
}

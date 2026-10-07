import Foundation
import Testing
@testable import ImmountKit

@Suite struct ListingMetadataRefreshTests {
    @Test func legacyStoreReplaysUnchangedItemsAndPersistsOnlyAtCommit() async throws {
        let directory = temporaryDirectory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        // The old format has no revision field. Upgrading must preserve this anchor.
        try Data(#"{"epoch":"legacy-epoch","generation":7}"#.utf8)
            .write(to: directory.appending(path: "meta.json"))
        let store = ListingStore(directory: directory)
        await store.save(Catalog.rootFolders, for: .root)
        let original = Entry(id: .asset(parent: .favorites, id: "photo"), filename: "photo.jpg",
                             contentVersion: "original-checksum", metadataVersion: "original-metadata")
        await store.save([original], for: .favorites)
        let storedBefore = await store.allEntries()
        let anchorBefore = await store.anchor
        #expect(anchorBefore == Data("legacy-epoch:7".utf8))

        let refresh = try #require(await store.prepareMetadataRefresh(revision: 1, root: Catalog.rootEntry))
        let updates = refresh.changes.compactMap { change -> Entry? in
            if case .update(let entry) = change { return entry }
            return nil
        }
        #expect(updates.first == Catalog.rootEntry)
        #expect(Set(updates) == Set([Catalog.rootEntry] + storedBefore))
        #expect(updates.count == refresh.changes.count)
        #expect(updates.first { $0.id == original.id } == original)
        #expect(await store.needsMetadataRefresh(revision: 1))
        #expect(await store.anchor == anchorBefore)
        #expect(await store.prepareMetadataRefresh(revision: 1, root: Catalog.rootEntry)?.id == refresh.id)
        #expect(await ListingStore(directory: directory).needsMetadataRefresh(revision: 1))

        let anchorAfter = await store.commit(refresh)
        #expect(anchorAfter != anchorBefore)
        #expect(await !store.needsMetadataRefresh(revision: 1))
        #expect(Set(await store.allEntries()) == Set(storedBefore))
        #expect(await store.prepareMetadataRefresh(revision: 1, root: Catalog.rootEntry) == nil)
        let reopened = ListingStore(directory: directory)
        #expect(await reopened.anchor == anchorAfter)
        #expect(await !reopened.needsMetadataRefresh(revision: 1))
        #expect(await reopened.listing(for: .favorites) == [original])
    }

    @Test func interruptedBatchesReplayAndStaleCommitsCannotAdvanceRevision() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ListingStore(directory: directory)
        await store.save(Catalog.rootFolders, for: .root)
        let refresh = try #require(await store.prepareMetadataRefresh(revision: 1, root: Catalog.rootEntry))
        let middle = await store.anchor(for: refresh, offset: 2)
        guard case .batch(let pending, let offset)? = await store.resumePoint(middle) else {
            Issue.record("Expected the metadata batch to resume")
            return
        }
        #expect(pending.id == refresh.id)
        #expect(offset == 2)

        // Losing the in-memory batch must not claim the metadata revision was delivered.
        let reopened = ListingStore(directory: directory)
        #expect(await reopened.resumePoint(middle) == nil)
        #expect(await reopened.needsMetadataRefresh(revision: 1))
        let replay = try #require(await reopened.prepareMetadataRefresh(revision: 1, root: Catalog.rootEntry))
        #expect(replay.id != refresh.id)
        #expect(replay.changes == refresh.changes)
        let staleLaterRevision = try #require(await reopened.prepareMetadataRefresh(revision: 2, root: Catalog.rootEntry))
        _ = await reopened.commit(replay)
        let committed = await reopened.anchor
        #expect(await reopened.commit(staleLaterRevision) == committed)
        #expect(await reopened.needsMetadataRefresh(revision: 2))
    }

    @Test func rootPolicyIsReplayedEvenBeforeAnyFolderWasListed() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ListingStore(directory: directory)
        let refresh = try #require(await store.prepareMetadataRefresh(revision: 1, root: Catalog.rootEntry))
        #expect(refresh.changes == [.update(Catalog.rootEntry)])
        _ = await store.commit(refresh)
        #expect(await !store.needsMetadataRefresh(revision: 1))
        #expect(await store.containers().isEmpty)
    }

    @Test func failedCommitDoesNotMarkTheMetadataRevisionDelivered() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ListingStore(directory: directory)
        let refresh = try #require(await store.prepareMetadataRefresh(revision: 1, root: Catalog.rootEntry))
        let metadata = directory.appending(path: "meta.json")
        try FileManager.default.removeItem(at: metadata)
        try FileManager.default.createDirectory(at: metadata, withIntermediateDirectories: false)
        _ = await store.commit(refresh)
        #expect(await store.needsMetadataRefresh(revision: 1))
        #expect(await store.prepareMetadataRefresh(revision: 1, root: Catalog.rootEntry) != nil)
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appending(path: "immount-metadata-tests-\(UUID().uuidString)")
    }
}

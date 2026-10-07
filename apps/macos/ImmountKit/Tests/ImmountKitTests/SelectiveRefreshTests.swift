import Foundation
import Testing
@testable import ImmountKit

@Suite struct SelectiveRefreshTests {
    private let start = Date(timeIntervalSince1970: 1_700_000_000)

    @Test func automaticBaselineIsCompleteAndIdleTicksDoNotRewriteListings() async throws {
        let fixture = await fixture(count: 4)
        defer { fixture.cleanup() }
        let baseline = await refresh(fixture, at: start)
        #expect(baseline.mode == .automatic)
        #expect(Set(await fixture.source.drainCalls()) == Set([.root, .albums] + fixture.albums))
        #expect(await fixture.store.commitWithResult(baseline).committed)
        let filesBefore = try fileIdentities(in: fixture.directory)

        let idle = await refresh(fixture, at: start.addingTimeInterval(1))
        #expect(Set(await fixture.source.drainCalls()) == [.root, .albums])
        #expect(idle.changes.isEmpty)
        #expect(await fixture.store.commitWithResult(idle).committed)
        #expect(try fileIdentities(in: fixture.directory) == filesBefore)

        let reopened = ListingStore(directory: fixture.directory)
        let (afterRestart, _) = await reopened.prepareRefresh(mode: .automatic, now: start.addingTimeInterval(2)) {
            try await fixture.source.fetch($0)
        }
        #expect(Set(await fixture.source.drainCalls()) == Set([.root, .albums] + fixture.albums))
        #expect(await reopened.commitWithResult(afterRestart).committed)
    }

    @Test func recentlyBrowsedFoldersWaitThirtySecondsAndExpireAfterTwoMinutes() async {
        let fixture = await fixture(count: 2)
        defer { fixture.cleanup() }
        _ = await fixture.store.commit(await refresh(fixture, at: start))
        _ = await fixture.source.drainCalls()
        let active = fixture.albums[0]
        await fixture.store.recordBrowse(active, at: start.addingTimeInterval(10))

        _ = await fixture.store.commit(await refresh(fixture, at: start.addingTimeInterval(29)))
        #expect(Set(await fixture.source.drainCalls()) == [.root, .albums])
        _ = await fixture.store.commit(await refresh(fixture, at: start.addingTimeInterval(30)))
        #expect(Set(await fixture.source.drainCalls()) == [.root, .albums, active])
        _ = await fixture.store.commit(await refresh(fixture, at: start.addingTimeInterval(59)))
        #expect(Set(await fixture.source.drainCalls()) == [.root, .albums])
        _ = await fixture.store.commit(await refresh(fixture, at: start.addingTimeInterval(131)))
        #expect(Set(await fixture.source.drainCalls()) == [.root, .albums])
    }

    @Test func reopenedFoldersAreCheckedOnceTheirListingIsFifteenSecondsOld() async {
        let fixture = await fixture(count: 2)
        defer { fixture.cleanup() }
        _ = await fixture.store.commit(await refresh(fixture, at: start))
        _ = await fixture.source.drainCalls()
        let album = fixture.albums[0]

        // Fetched moments ago: no extra check.
        #expect(await !fixture.store.recordOpen(album, at: start.addingTimeInterval(14)))
        #expect(await !fixture.store.hasPendingOpens)

        #expect(await fixture.store.recordOpen(album, at: start.addingTimeInterval(15)))
        #expect(await fixture.store.hasPendingOpens)
        _ = await fixture.store.commit(await refresh(fixture, at: start.addingTimeInterval(16)))
        #expect(Set(await fixture.source.drainCalls()) == [.root, .albums, album])
        #expect(await !fixture.store.hasPendingOpens)

        // Reopening right after that check waits for the listing to age again.
        #expect(await !fixture.store.recordOpen(album, at: start.addingTimeInterval(20)))
        _ = await fixture.store.commit(await refresh(fixture, at: start.addingTimeInterval(21)))
        #expect(Set(await fixture.source.drainCalls()) == [.root, .albums])
    }

    @Test func unknownFoldersAreLeftToTheirFirstEnumeration() async {
        let fixture = await fixture(count: 1)
        defer { fixture.cleanup() }
        _ = await fixture.store.commit(await refresh(fixture, at: start))
        #expect(await !fixture.store.recordOpen(.album("never-listed"), at: start.addingTimeInterval(60)))
        #expect(await !fixture.store.hasPendingOpens)
    }

    @Test func coldBudgetRotatesAndTenMinuteSafetyIncludesEveryOverdueFolder() async {
        let fixture = await fixture(count: 6)
        defer { fixture.cleanup() }
        _ = await fixture.store.commit(await refresh(fixture, at: start))
        _ = await fixture.source.drainCalls()
        _ = await fixture.store.commit(await refresh(fixture, at: start.addingTimeInterval(299)))
        #expect(Set(await fixture.source.drainCalls()) == [.root, .albums])

        _ = await fixture.store.commit(await refresh(fixture, at: start.addingTimeInterval(300)))
        let first = Set(await fixture.source.drainCalls()).subtracting([.root, .albums])
        #expect(first.count == 2)
        _ = await fixture.store.commit(await refresh(fixture, at: start.addingTimeInterval(301)))
        let second = Set(await fixture.source.drainCalls()).subtracting([.root, .albums])
        #expect(second.count == 2)
        #expect(first.isDisjoint(with: second))
        _ = await fixture.store.commit(await refresh(fixture, at: start.addingTimeInterval(902)))
        #expect(Set(await fixture.source.drainCalls()) == Set([.root, .albums] + fixture.albums))
    }

    @Test func changedParentMetadataRefreshesOnlyItsCachedAssetFolder() async {
        let fixture = await fixture(count: 3)
        defer { fixture.cleanup() }
        _ = await fixture.store.commit(await refresh(fixture, at: start))
        _ = await fixture.source.drainCalls()
        var folders = await fixture.source.listing(.albums)
        let changedID = fixture.albums[1]
        folders[1] = .folder(changedID, name: "Album 1", childCount: 2)
        let added = Entry(id: .asset(parent: changedID, id: "new"), filename: "new.jpg")
        await fixture.source.set(folders, for: .albums)
        await fixture.source.set(await fixture.source.listing(changedID) + [added], for: changedID)

        let changed = await refresh(fixture, at: start.addingTimeInterval(1))
        #expect(Set(await fixture.source.drainCalls()) == [.root, .albums, changedID])
        #expect(changed.changes.contains(.update(added)))
        #expect(await fixture.store.commitWithResult(changed).committed)
    }

    @Test func timelineIndexesDiscoverNewYearAndChangedMonthWithoutScanningOtherMonths() async {
        let directory = directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ListingStore(directory: directory)
        let january = YearMonth(year: 2025, month: 1)
        let february = YearMonth(year: 2025, month: 2)
        let oldMonths = [Catalog.monthEntry(january, count: 1), Catalog.monthEntry(february, count: 1)]
        let listings: [ItemID: [Entry]] = [
            .root: Catalog.rootFolders,
            .timeline: [Catalog.yearEntry(2025)],
            .year(2025): oldMonths,
            .month(january): [photo(in: .month(january))],
            .month(february): [photo(in: .month(february))],
        ]
        for (id, entries) in listings { await store.save(entries, for: id) }
        let source = Source(listings)
        let (baseline, _) = await store.prepareRefresh(mode: .automatic, now: start) { try await source.fetch($0) }
        _ = await store.commit(baseline)
        _ = await source.drainCalls()
        await source.set([Catalog.yearEntry(2025), Catalog.yearEntry(2026)], for: .timeline)
        await source.set([Catalog.monthEntry(january, count: 2), oldMonths[1]], for: .year(2025))
        let added = Entry(id: .asset(parent: .month(january), id: "new"), filename: "new.jpg")
        await source.set([photo(in: .month(january)), added], for: .month(january))

        let (refresh, error) = await store.prepareRefresh(mode: .automatic, now: start.addingTimeInterval(1)) {
            try await source.fetch($0)
        }
        #expect(error == nil)
        #expect(Set(await source.drainCalls()) == [.root, .timeline, .year(2025), .month(january)])
        #expect(refresh.changes.contains(.update(Catalog.yearEntry(2026))))
        #expect(refresh.changes.contains(.update(added)))
        #expect(await store.commitWithResult(refresh).committed)
    }

    @Test func failedScopesDoNotAdvanceTheirSuccessfulCheckpoint() async {
        let fixture = await fixture(count: 2)
        defer { fixture.cleanup() }
        let failedID = fixture.albums[0]
        await fixture.source.fail(failedID, with: .missingPermission("album.read"))
        let partial = await refresh(fixture, at: start)
        #expect(!partial.succeeded)
        #expect(await fixture.store.commitWithResult(partial).committed)
        _ = await fixture.source.drainCalls()
        await fixture.source.fail(failedID, with: nil)

        let retry = await refresh(fixture, at: start.addingTimeInterval(30))
        #expect(Set(await fixture.source.drainCalls()) == [.root, .albums, failedID])
        #expect(retry.succeeded)
        #expect(await fixture.store.commitWithResult(retry).committed)
        #expect(await fixture.store.listing(for: failedID) == [photo(in: failedID)])
    }

    @Test func failingFolderIsRetriedLessOftenUntilItIsListedAgain() async {
        let fixture = await fixture(count: 2)
        defer { fixture.cleanup() }
        let failedID = fixture.albums[0]
        await fixture.source.fail(failedID, with: .http(status: 500, message: nil))
        _ = await fixture.store.commit(await refresh(fixture, at: start))
        _ = await fixture.source.drainCalls()

        // Retries wait 30 s, then 60 s, then 120 s.
        for (skipped, retried) in [(29.0, 30.0), (89, 90), (209, 210)] {
            _ = await fixture.store.commit(await refresh(fixture, at: start.addingTimeInterval(skipped)))
            #expect(Set(await fixture.source.drainCalls()) == [.root, .albums])
            _ = await fixture.store.commit(await refresh(fixture, at: start.addingTimeInterval(retried)))
            #expect(Set(await fixture.source.drainCalls()) == [.root, .albums, failedID])
        }

        // A full refresh does not wait.
        let (full, _) = await fixture.store.prepareRefresh(mode: .full, now: start.addingTimeInterval(211), requestToken: "manual") {
            try await fixture.source.fetch($0)
        }
        #expect(Set(await fixture.source.drainCalls()) == Set([.root, .albums] + fixture.albums))
        _ = await fixture.store.commit(full)

        // Once listed, a new failure starts again from the shortest wait.
        await fixture.source.fail(failedID, with: nil)
        let recovered = await refresh(fixture, at: start.addingTimeInterval(1_000))
        #expect(Set(await fixture.source.drainCalls()) == Set([.root, .albums] + fixture.albums))
        #expect(recovered.succeeded)
        _ = await fixture.store.commit(recovered)
        await fixture.source.fail(failedID, with: .http(status: 500, message: nil))
        await fixture.store.recordBrowse(failedID, at: start.addingTimeInterval(1_010))
        _ = await fixture.store.commit(await refresh(fixture, at: start.addingTimeInterval(1_040)))
        #expect(Set(await fixture.source.drainCalls()) == [.root, .albums, failedID])
        _ = await fixture.store.commit(await refresh(fixture, at: start.addingTimeInterval(1_069)))
        #expect(Set(await fixture.source.drainCalls()) == [.root, .albums])
        _ = await fixture.store.commit(await refresh(fixture, at: start.addingTimeInterval(1_070)))
        #expect(Set(await fixture.source.drainCalls()) == [.root, .albums, failedID])
    }

    @Test func folderListedByFinderIsNoLongerBackingOff() async {
        let fixture = await fixture(count: 2)
        defer { fixture.cleanup() }
        let failedID = fixture.albums[0]
        await fixture.source.fail(failedID, with: .http(status: 500, message: nil))
        for time in [0.0, 30, 90, 210] {
            _ = await fixture.store.commit(await refresh(fixture, at: start.addingTimeInterval(time)))
        }
        _ = await fixture.source.drainCalls()
        await fixture.source.fail(failedID, with: nil)

        // Finder lists the folder itself while its next retry is still minutes away.
        await fixture.store.save(await fixture.source.listing(failedID), for: failedID)
        await fixture.store.recordBrowse(failedID, at: start.addingTimeInterval(220))
        _ = await fixture.store.commit(await refresh(fixture, at: start.addingTimeInterval(250)))
        #expect(Set(await fixture.source.drainCalls()) == [.root, .albums, failedID])
    }

    @Test func reopeningAFailingFolderWaitsFifteenSecondsBetweenChecks() async {
        let fixture = await fixture(count: 2)
        defer { fixture.cleanup() }
        _ = await fixture.store.commit(await refresh(fixture, at: start))
        let album = fixture.albums[0]
        await fixture.source.fail(album, with: .http(status: 500, message: nil))
        #expect(await fixture.store.recordOpen(album, at: start.addingTimeInterval(20)))
        _ = await fixture.store.commit(await refresh(fixture, at: start.addingTimeInterval(21)))
        _ = await fixture.source.drainCalls()

        #expect(await !fixture.store.recordOpen(album, at: start.addingTimeInterval(35)))
        _ = await fixture.store.commit(await refresh(fixture, at: start.addingTimeInterval(35)))
        #expect(Set(await fixture.source.drainCalls()) == [.root, .albums])

        // A reopen does not wait for the longer automatic backoff.
        #expect(await fixture.store.recordOpen(album, at: start.addingTimeInterval(36)))
        _ = await fixture.store.commit(await refresh(fixture, at: start.addingTimeInterval(37)))
        #expect(Set(await fixture.source.drainCalls()) == [.root, .albums, album])
    }

    @Test func fullRequestsKeepTheirCreatorContextAndFrozenBatchUntilCommit() async {
        let fixture = await fixture(count: 2)
        defer { fixture.cleanup() }
        let (first, _) = await fixture.store.prepareRefresh(mode: .full, now: start, requestToken: "first") {
            try await fixture.source.fetch($0)
        }
        _ = await fixture.source.drainCalls()
        let (joined, _) = await fixture.store.prepareRefresh(mode: .automatic, now: start.addingTimeInterval(1), requestToken: "later") {
            try await fixture.source.fetch($0)
        }
        #expect(joined.id == first.id)
        #expect(joined.mode == .full)
        #expect(joined.requestToken == "first")
        #expect(joined.startedAt == start)
        #expect(await fixture.source.drainCalls().isEmpty)
        #expect(await fixture.store.commitWithResult(first).committed)
        #expect(await !fixture.store.commitWithResult(joined).committed)

        let (next, _) = await fixture.store.prepareRefresh(mode: .full, now: start.addingTimeInterval(2), requestToken: "later") {
            try await fixture.source.fetch($0)
        }
        #expect(next.id != first.id)
        #expect(next.requestToken == "later")
        #expect(Set(await fixture.source.drainCalls()) == Set([.root, .albums] + fixture.albums))
        #expect(await fixture.store.commitWithResult(next).committed)
    }

    @Test func concurrentPreparationsShareOneFetchAndCannotReplaceTheCreator() async {
        let fixture = await fixture(count: 3)
        defer { fixture.cleanup() }
        let gate = Gate()
        await fixture.source.block(.root, on: gate)
        let first = Task {
            await fixture.store.prepareRefresh(mode: .automatic, now: start) { try await fixture.source.fetch($0) }
        }
        await gate.waitForEntry()
        let joined = Task {
            await fixture.store.prepareRefresh(mode: .full, now: start.addingTimeInterval(1), requestToken: "new-request") {
                try await fixture.source.fetch($0)
            }
        }
        await gate.open()
        let a = await first.value
        let b = await joined.value
        #expect(a.refresh.id == b.refresh.id)
        #expect(b.refresh.mode == .automatic)
        #expect(b.refresh.requestToken == nil)
        let calls = await fixture.source.drainCalls()
        #expect(calls.count == Set(calls).count)
        #expect(Set(calls) == Set([.root, .albums] + fixture.albums))
        #expect(await fixture.store.commitWithResult(a.refresh).committed)
    }

    @Test func cancelledPreparationDoesNotQueueAssetsOrCheckpointAnyFolder() async {
        let fixture = await fixture(count: 3)
        defer { fixture.cleanup() }
        let gate = Gate()
        await fixture.source.block(.root, on: gate)
        let task = Task {
            await fixture.store.prepareRefresh(mode: .automatic, now: start) { try await fixture.source.fetch($0) }
        }
        await gate.waitForEntry()
        task.cancel()
        await gate.open()
        let cancelled = await task.value
        #expect(cancelled.error is CancellationError)
        #expect(await !fixture.store.commitWithResult(cancelled.refresh).committed)
        #expect(Set(await fixture.source.drainCalls()).isDisjoint(with: fixture.albums))

        let retry = await refresh(fixture, at: start.addingTimeInterval(1))
        #expect(Set(await fixture.source.drainCalls()) == Set([.root, .albums] + fixture.albums))
        #expect(await fixture.store.commitWithResult(retry).committed)
    }

    @Test func callerArrivingAfterTheLastWaiterLeftStartsAFreshPreparation() async {
        let fixture = await fixture(count: 2)
        defer { fixture.cleanup() }
        let gate = Gate()
        await fixture.source.block(.root, on: gate)
        let abandoned = Task {
            await fixture.store.prepareRefresh(mode: .automatic, now: start) { try await fixture.source.fetch($0) }
        }
        // The blocked fetch ignores cancellation, so the abandoned preparation stays in
        // flight while the next caller arrives.
        await gate.waitForEntry()
        abandoned.cancel()
        let open = Gate()
        await open.open()
        await fixture.source.block(.root, on: open)

        // A caller that joined the abandoned preparation would wait for this gate forever.
        // Opening it after a while hands such a caller the cancellation, so the test fails.
        let release = Task {
            try? await Task.sleep(for: .seconds(5))
            await gate.open()
        }
        let (fresh, error) = await fixture.store.prepareRefresh(mode: .automatic, now: start.addingTimeInterval(1)) {
            try await fixture.source.fetch($0)
        }
        #expect(error == nil)
        #expect(fresh.succeeded)
        #expect(fresh.startedAt == start.addingTimeInterval(1))
        release.cancel()
        await release.value
        let cancelled = await abandoned.value
        #expect(cancelled.error is CancellationError)
        #expect(await !fixture.store.commitWithResult(cancelled.refresh).committed)
        #expect(await fixture.store.commitWithResult(fresh).committed)
    }

    @Test func cancelledPreparationKeepsOpenedFoldersForTheNextRefresh() async {
        let fixture = await fixture(count: 2)
        defer { fixture.cleanup() }
        _ = await fixture.store.commit(await refresh(fixture, at: start))
        _ = await fixture.source.drainCalls()
        let album = fixture.albums[0]
        #expect(await fixture.store.recordOpen(album, at: start.addingTimeInterval(20)))

        let gate = Gate()
        await fixture.source.block(.root, on: gate)
        let task = Task {
            await fixture.store.prepareRefresh(mode: .automatic, now: start.addingTimeInterval(21)) {
                try await fixture.source.fetch($0)
            }
        }
        await gate.waitForEntry()
        task.cancel()
        await gate.open()
        #expect(await task.value.error is CancellationError)
        #expect(await fixture.store.hasPendingOpens)
        _ = await fixture.source.drainCalls()

        _ = await fixture.store.commit(await refresh(fixture, at: start.addingTimeInterval(22)))
        #expect(Set(await fixture.source.drainCalls()) == [.root, .albums, album])
        #expect(await !fixture.store.hasPendingOpens)
    }

    @Test func partialSuccessNeedsAnotherFolderListedByTheServer() async {
        let fixture = await fixture(count: 2)
        defer { fixture.cleanup() }
        await fixture.source.fail(fixture.albums[0], with: .http(status: 500, message: nil))
        let (partial, partialError) = await fixture.store.prepareRefresh(mode: .full, now: start, requestToken: "manual") {
            try await fixture.source.fetch($0)
        }
        #expect(partialError != nil)
        #expect(!partial.succeeded)
        #expect(partial.partiallySucceeded)
        #expect(await fixture.store.commitWithResult(partial).committed)

        for id in [ItemID.albums] + fixture.albums { await fixture.source.fail(id, with: .http(status: 500, message: nil)) }
        let (failed, failedError) = await fixture.store.prepareRefresh(mode: .full, now: start.addingTimeInterval(1), requestToken: "manual") {
            try await fixture.source.fetch($0)
        }
        #expect(failedError != nil)
        #expect(!failed.succeeded)
        #expect(!failed.partiallySucceeded)
        #expect(await fixture.store.commitWithResult(failed).committed)

        for id in [ItemID.albums] + fixture.albums { await fixture.source.fail(id, with: nil) }
        let healthy = await refresh(fixture, at: start.addingTimeInterval(2))
        #expect(healthy.succeeded)
        #expect(!healthy.partiallySucceeded)
    }

    @Test func failingMetadataFolderIsNotPartialSuccess() async {
        let fixture = await fixture(count: 3)
        defer { fixture.cleanup() }
        _ = await fixture.store.commit(await refresh(fixture, at: start))
        await fixture.source.fail(.albums, with: .http(status: 500, message: nil))
        let (refresh, error) = await fixture.store.prepareRefresh(mode: .full, now: start.addingTimeInterval(1), requestToken: "manual") {
            try await fixture.source.fetch($0)
        }
        #expect(error != nil)
        #expect(!refresh.succeeded)
        #expect(!refresh.partiallySucceeded)
    }

    @Test func failingAsManyFoldersAsWereListedIsNotPartialSuccess() async {
        let fixture = await fixture(count: 3)
        defer { fixture.cleanup() }
        for id in fixture.albums.prefix(2) { await fixture.source.fail(id, with: .http(status: 500, message: nil)) }
        let (refresh, error) = await fixture.store.prepareRefresh(mode: .full, now: start, requestToken: "manual") {
            try await fixture.source.fetch($0)
        }
        #expect(error != nil)
        #expect(!refresh.partiallySucceeded)
    }

    @Test func newerEnumerationDuringFetchWinsOverItsStaleResponse() async {
        let fixture = await fixture(count: 2)
        defer { fixture.cleanup() }
        let changedID = fixture.albums[0]
        let gate = Gate()
        await fixture.source.block(changedID, on: gate)
        let task = Task {
            await fixture.store.prepareRefresh(mode: .full, now: start) { try await fixture.source.fetch($0) }
        }
        await gate.waitForEntry()
        let fresh = Entry(id: .asset(parent: changedID, id: "new"), filename: "new.jpg")
        await fixture.store.save([fresh], for: changedID)
        await gate.open()
        let prepared = await task.value
        #expect(!prepared.refresh.changes.contains(.delete(fresh.id)))
        #expect(await fixture.store.commitWithResult(prepared.refresh).committed)
        #expect(await fixture.store.listing(for: changedID) == [fresh])
    }

    @Test func newerEnumerationAfterPreparationRejectsTheBatchAtCommit() async {
        let fixture = await fixture(count: 2)
        defer { fixture.cleanup() }
        let prepared = await refresh(fixture, at: start)
        let changedID = fixture.albums[0]
        let fresh = Entry(id: .asset(parent: changedID, id: "new"), filename: "new.jpg")
        await fixture.store.save([fresh], for: changedID)
        #expect(await !fixture.store.commitWithResult(prepared).committed)
        #expect(await fixture.store.listing(for: changedID) == [fresh])
        await fixture.source.set([fresh], for: changedID)
        _ = await fixture.source.drainCalls()
        let retry = await refresh(fixture, at: start.addingTimeInterval(1))
        #expect(Set(await fixture.source.drainCalls()) == Set([.root, .albums] + fixture.albums))
        #expect(await fixture.store.commitWithResult(retry).committed)
    }

    @Test func generationChangeDuringFetchCannotCommitOldWork() async {
        let fixture = await fixture(count: 2)
        defer { fixture.cleanup() }
        let gate = Gate()
        await fixture.source.block(.root, on: gate)
        let task = Task {
            await fixture.store.prepareRefresh(mode: .full, now: start) { try await fixture.source.fetch($0) }
        }
        await gate.waitForEntry()
        #expect(await fixture.store.bumpGeneration())
        await gate.open()
        let stale = await task.value
        #expect(stale.error is CancellationError)
        #expect(await !fixture.store.commitWithResult(stale.refresh).committed)
        _ = await fixture.source.drainCalls()
        let retry = await refresh(fixture, at: start.addingTimeInterval(1))
        #expect(Set(await fixture.source.drainCalls()) == Set([.root, .albums] + fixture.albums))
        #expect(await fixture.store.commitWithResult(retry).committed)
    }

    @Test(arguments: [false, true])
    func failedDirectSaveStaysTrackedAndIdenticalDataCanBePersisted(viaRefresh: Bool) async throws {
        let fixture = await fixture(count: 1)
        defer { fixture.cleanup() }
        _ = await fixture.store.containers() // Populate the container index before the failed save.
        let added = ItemID.album("new-album")
        await fixture.store.save(
            await fixture.store.listing(for: .albums)! + [.folder(added, name: "New album")], for: .albums
        )
        let destination = fixture.directory.appending(path: "listings")
            .appending(path: Data(added.rawValue.utf8).base64URLEncodedString() + ".json")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
        let entries = [photo(in: added)]
        await fixture.store.save(entries, for: added)
        #expect(await fixture.store.containers().contains(added))
        #expect(await fixture.store.allEntries().contains(entries[0]))

        try FileManager.default.removeItem(at: destination)
        if viaRefresh {
            let (retry, _) = await fixture.store.prepareRefresh(mode: .automatic, now: start) { container in
                await fixture.store.listing(for: container) ?? []
            }
            #expect(retry.changes.isEmpty)
            #expect(await fixture.store.commitWithResult(retry).committed)
        } else {
            await fixture.store.save(entries, for: added)
        }
        let reopened = ListingStore(directory: fixture.directory)
        #expect(await reopened.listing(for: added) == entries)
        #expect(await reopened.containers().contains(added))
    }

    private struct Fixture: Sendable {
        let directory: URL
        let store: ListingStore
        let source: Source
        let albums: [ItemID]
        func cleanup() { try? FileManager.default.removeItem(at: directory) }
    }

    private func fixture(count: Int) async -> Fixture {
        let directory = directory()
        let store = ListingStore(directory: directory)
        let albums = (0..<count).map { ItemID.album(String($0)) }
        var listings: [ItemID: [Entry]] = [
            .root: Catalog.rootFolders,
            .albums: albums.enumerated().map { .folder($0.element, name: "Album \($0.offset)", childCount: 1) },
        ]
        for album in albums { listings[album] = [photo(in: album)] }
        for (id, entries) in listings { await store.save(entries, for: id) }
        return Fixture(directory: directory, store: store, source: Source(listings), albums: albums)
    }

    private func refresh(_ fixture: Fixture, at time: Date) async -> PendingRefresh {
        await fixture.store.prepareRefresh(mode: .automatic, now: time) { try await fixture.source.fetch($0) }.refresh
    }

    private func photo(in parent: ItemID) -> Entry {
        Entry(id: .asset(parent: parent, id: "original"), filename: "original.jpg", contentVersion: "original")
    }

    private func directory() -> URL {
        FileManager.default.temporaryDirectory.appending(path: "immount-selective-\(UUID().uuidString)")
    }

    private func fileIdentities(in directory: URL) throws -> [String: UInt64] {
        let listingDirectory = directory.appending(path: "listings")
        let files = try FileManager.default.contentsOfDirectory(at: listingDirectory, includingPropertiesForKeys: nil)
            + [directory.appending(path: "meta.json")]
        return try Dictionary(uniqueKeysWithValues: files.map {
            let attributes = try FileManager.default.attributesOfItem(atPath: $0.path)
            return ($0.lastPathComponent, (attributes[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0)
        })
    }

    private actor Source {
        private var listings: [ItemID: [Entry]]
        private var failures: [ItemID: ImmichError] = [:]
        private var calls: [ItemID] = []
        private var gates: [ItemID: Gate] = [:]

        init(_ listings: [ItemID: [Entry]]) { self.listings = listings }
        func listing(_ id: ItemID) -> [Entry] { listings[id] ?? [] }
        func set(_ entries: [Entry], for id: ItemID) { listings[id] = entries }
        func fail(_ id: ItemID, with error: ImmichError?) { failures[id] = error }
        func block(_ id: ItemID, on gate: Gate) { gates[id] = gate }
        func drainCalls() -> [ItemID] { defer { calls = [] }; return calls }
        func fetch(_ id: ItemID) async throws -> [Entry] {
            calls.append(id)
            let response = listings[id] ?? []
            if let gate = gates[id] { await gate.enter() }
            try Task.checkCancellation()
            if let error = failures[id] { throw error }
            return response
        }
    }

    private actor Gate {
        private var opened = false
        private var entered = false
        private var waiters: [CheckedContinuation<Void, Never>] = []
        private var observers: [CheckedContinuation<Void, Never>] = []
        func enter() async {
            entered = true
            observers.forEach { $0.resume() }
            observers = []
            guard !opened else { return }
            await withCheckedContinuation { waiters.append($0) }
        }
        func waitForEntry() async {
            guard !entered else { return }
            await withCheckedContinuation { observers.append($0) }
        }
        func open() {
            opened = true
            waiters.forEach { $0.resume() }
            waiters = []
        }
    }
}

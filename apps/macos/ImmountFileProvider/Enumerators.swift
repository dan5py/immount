import FileProvider
import ImmountKit
import os

/// Resolves the connection at the start of each operation, so a new API key or address
/// applies without restarting the extension.
typealias CatalogFactory = () throws -> Catalog

/// The Tasks an enumerator started, so `invalidate()` can cancel them. Enumerator methods
/// and `invalidate()` can be called from different threads.
final class TaskBag: Sendable {
    private let state = OSAllocatedUnfairLock<(tasks: [UUID: Task<Void, Never>], invalidated: Bool)>(initialState: ([:], false))

    func run(_ operation: @escaping @Sendable () async -> Void) {
        let id = UUID()
        state.withLock { state in
            guard !state.invalidated else { return }
            state.tasks[id] = Task { [weak self] in
                await operation()
                self?.state.withLock { _ = $0.tasks.removeValue(forKey: id) }
            }
        }
    }

    func cancelAll() {
        let tasks = state.withLock { state in
            state.invalidated = true
            defer { state.tasks = [:] }
            return Array(state.tasks.values)
        }
        tasks.forEach { $0.cancel() }
    }
}

/// A value shared between an enumerator and the Tasks it starts.
final class Locked<Value: Sendable>: Sendable {
    private let mutex: OSAllocatedUnfairLock<Value>

    init(_ value: Value) {
        mutex = OSAllocatedUnfairLock(initialState: value)
    }

    var value: Value { mutex.withLock { $0 } }

    func set(_ value: Value) {
        mutex.withLock { $0 = value }
    }
}

/// Runs `action` once, shortly after the first of a burst of requests, so clicking through
/// several folders asks for one check instead of one per folder.
actor Debouncer {
    private let delay: Duration
    private let action: @Sendable () async -> Void
    private var isScheduled = false

    init(delay: Duration, action: @escaping @Sendable () async -> Void) {
        self.delay = delay
        self.action = action
    }

    func request() {
        guard !isScheduled else { return }
        isScheduled = true
        Task {
            try? await Task.sleep(for: delay)
            await fire()
        }
    }

    private func fire() async {
        isScheduled = false
        await action()
    }
}

/// Lists one folder. The first page fetches the whole folder from Immich (names must be
/// deduplicated across the full listing) and stores it; later pages come from that snapshot.
final class ContainerEnumerator: NSObject, NSFileProviderEnumerator {
    private let container: ItemID
    private let catalog: CatalogFactory
    private let store: ListingStore
    private let isFileViewerRequest: Bool
    private let tasks = TaskBag()
    private let snapshot = Locked<[Entry]?>(nil)

    init(container: ItemID, catalog: @escaping CatalogFactory, store: ListingStore, isFileViewerRequest: Bool) {
        self.container = container
        self.catalog = catalog
        self.store = store
        self.isFileViewerRequest = isFileViewerRequest
    }

    func invalidate() {
        tasks.cancelAll()
    }

    func enumerateItems(for observer: NSFileProviderEnumerationObserver, startingAt page: NSFileProviderPage) {
        let offset = Page.offset(of: page)
        let pageSize = max(observer.suggestedPageSize ?? 500, 1)
        tasks.run { [container, catalog, store, snapshot, isFileViewerRequest] in
            do {
                if offset == 0, isFileViewerRequest { await store.recordBrowse(container) }
                var entries = offset == 0 ? nil : snapshot.value
                if entries == nil, offset > 0 {
                    // A new enumerator instance resuming a listing: the store has page 1's copy.
                    entries = await store.listing(for: container)
                }
                if entries == nil {
                    let fresh = try await catalog().children(of: container)
                    await store.save(fresh, for: container)
                    entries = fresh
                }
                let all = entries ?? []
                snapshot.set(all)
                let end = min(offset + pageSize, all.count)
                observer.didEnumerate(all[min(offset, end)..<end].map(FileProviderItem.init))
                observer.finishEnumerating(upTo: end < all.count ? Page.make(offset: end) : nil)
            } catch {
                Log.enumeration.error("Listing \(container.rawValue, privacy: .public) failed: \(error, privacy: .public)")
                observer.finishEnumeratingWithError(fileProviderError(error))
            }
        }
    }

    /// Changes reach the system through the working set; a folder has none of its own to report.
    func enumerateChanges(for observer: NSFileProviderChangeObserver, from anchor: NSFileProviderSyncAnchor) {
        tasks.run { [store] in
            guard await store.isValid(anchor.rawValue) else {
                observer.finishEnumeratingWithError(NSFileProviderError(.syncAnchorExpired))
                return
            }
            observer.finishEnumeratingChanges(upTo: NSFileProviderSyncAnchor(await store.anchor), moreComing: false)
        }
    }

    func currentSyncAnchor(completionHandler: @escaping (NSFileProviderSyncAnchor?) -> Void) {
        tasks.run { [store] in completionHandler(NSFileProviderSyncAnchor(await store.anchor)) }
    }
}

/// The system keeps an enumerator open on a document an app has open, to follow changes to
/// it. Its changes arrive through the working set too.
final class ItemEnumerator: NSObject, NSFileProviderEnumerator {
    private let id: ItemID
    private let catalog: CatalogFactory
    private let store: ListingStore
    private let tasks = TaskBag()

    init(id: ItemID, catalog: @escaping CatalogFactory, store: ListingStore) {
        self.id = id
        self.catalog = catalog
        self.store = store
    }

    func invalidate() {
        tasks.cancelAll()
    }

    func enumerateItems(for observer: NSFileProviderEnumerationObserver, startingAt page: NSFileProviderPage) {
        tasks.run { [id, catalog, store] in
            do {
                let entry: Entry
                if let stored = await store.entry(for: id) {
                    entry = stored
                } else {
                    entry = try await catalog().entry(for: id)
                }
                observer.didEnumerate([FileProviderItem(entry)])
                observer.finishEnumerating(upTo: nil)
            } catch {
                // noSuchItem only when the server confirms the item is gone; the system then deletes it.
                observer.finishEnumeratingWithError(fileProviderError(error))
            }
        }
    }

    func enumerateChanges(for observer: NSFileProviderChangeObserver, from anchor: NSFileProviderSyncAnchor) {
        tasks.run { [store] in
            guard await store.isValid(anchor.rawValue) else {
                observer.finishEnumeratingWithError(NSFileProviderError(.syncAnchorExpired))
                return
            }
            observer.finishEnumeratingChanges(upTo: NSFileProviderSyncAnchor(await store.anchor), moreComing: false)
        }
    }

    func currentSyncAnchor(completionHandler: @escaping (NSFileProviderSyncAnchor?) -> Void) {
        tasks.run { [store] in completionHandler(NSFileProviderSyncAnchor(await store.anchor)) }
    }
}

/// The working set is every folder the system has listed so far. Enumerating its
/// changes checks metadata and selected folders, then reports what moved on the server.
/// The app signals it periodically and when the user asks for a refresh.
final class WorkingSetEnumerator: NSObject, NSFileProviderEnumerator {
    private let catalog: CatalogFactory
    private let store: ListingStore
    private let domain: NSFileProviderDomain
    private let settings: SettingsStore
    private let tasks = TaskBag()
    private let snapshot = Locked<[Entry]?>(nil)

    init(catalog: @escaping CatalogFactory, store: ListingStore, domain: NSFileProviderDomain, settings: SettingsStore = .shared) {
        self.catalog = catalog
        self.store = store
        self.domain = domain
        self.settings = settings
    }

    func invalidate() {
        tasks.cancelAll()
        snapshot.set(nil)
    }

    func enumerateItems(for observer: NSFileProviderEnumerationObserver, startingAt page: NSFileProviderPage) {
        let offset = Page.offset(of: page)
        let pageSize = max(observer.suggestedPageSize ?? 500, 1)
        tasks.run { [store, snapshot] in
            var entries = offset == 0 ? nil : snapshot.value
            if entries == nil {
                // A restarted, partially delivered refresh falls back to a full working-set
                // listing. Include root policy and permanent-folder additions even when
                // the interrupted batch had not yet persisted them in the listing store.
                let stored = await store.allEntries()
                var seen: Set<ItemID> = []
                let all = ([Catalog.rootEntry] + Catalog.rootFolders + stored).filter { seen.insert($0.id).inserted }
                snapshot.set(all)
                entries = all
            }
            let all = entries ?? []
            let end = min(offset + pageSize, all.count)
            // The system can keep the enumerator after the last page, and the snapshot holds
            // every stored item.
            if end == all.count { snapshot.set(nil) }
            observer.didEnumerate(all[min(offset, end)..<end].map(FileProviderItem.init))
            observer.finishEnumerating(upTo: end < all.count ? Page.make(offset: end) : nil)
        }
    }

    func enumerateChanges(for observer: NSFileProviderChangeObserver, from anchor: NSFileProviderSyncAnchor) {
        let batchSize = max(observer.suggestedBatchSize ?? 200, 1)
        tasks.run { [catalog, store, domain, settings] in
            // Continue the refresh being delivered in batches, or start a new one. A batch whose
            // refresh is gone makes the system enumerate from scratch (see `resumePoint`).
            let refresh: PendingRefresh
            let start: Int
            switch await store.resumePoint(anchor.rawValue) {
            case nil:
                observer.finishEnumeratingWithError(NSFileProviderError(.syncAnchorExpired))
                return
            case .batch(let pending, let offset)?:
                refresh = pending
                start = offset
            case .start?:
                if let prepared = await store.prepareMetadataRefresh(
                    revision: FileProviderItem.metadataRevision,
                    root: Catalog.rootEntry,
                    addingRootFolders: Catalog.rootFolders
                ) {
                    refresh = prepared
                    start = 0
                    break
                }
                let resolved = Result { try catalog() }
                let requestToken = settings.pendingFullRefresh(profileID: domain.identifier.rawValue)
                let mode: RefreshMode = requestToken == nil ? .automatic : .full
                let (prepared, error) = await store.prepareRefresh(mode: mode, requestToken: requestToken, maxConcurrent: mode == .automatic ? 2 : 4) { container in
                    // Root folders are local, including additions from an app update.
                    // Publish them even if the connection or API key is unavailable.
                    if container == .root { return Catalog.rootFolders }
                    return try await resolved.get().children(of: container)
                }
                Log.enumeration.info("Working set refresh: \(prepared.changes.count) changes")
                guard !Task.isCancelled else {
                    observer.finishEnumeratingWithError(CocoaError(.userCancelled))
                    return
                }
                if prepared.changes.isEmpty, let error {
                    // Checkpoint successful scopes and release this frozen batch even if
                    // another scope failed. A full scan that did not list more folders than
                    // failed keeps its manual request (see `recordRefreshOutcome`).
                    let result = await Self.commit(prepared, store: store, domain: domain, settings: settings)
                    guard result.committed else {
                        observer.finishEnumeratingWithError(NSFileProviderError(.syncAnchorExpired))
                        return
                    }
                    observer.finishEnumeratingWithError(fileProviderError(error))
                    return
                }
                refresh = prepared
                start = 0
            }
            guard !Task.isCancelled else {
                observer.finishEnumeratingWithError(CocoaError(.userCancelled))
                return
            }

            let end = min(start + batchSize, refresh.changes.count)
            report(refresh.changes[start..<end], to: observer)
            if end < refresh.changes.count {
                observer.finishEnumeratingChanges(upTo: NSFileProviderSyncAnchor(await store.anchor(for: refresh, offset: end)), moreComing: true)
            } else {
                let result = await Self.commit(refresh, store: store, domain: domain, settings: settings)
                guard result.committed else {
                    observer.finishEnumeratingWithError(NSFileProviderError(.syncAnchorExpired))
                    return
                }
                observer.finishEnumeratingChanges(upTo: NSFileProviderSyncAnchor(result.anchor), moreComing: false)
            }
        }
    }

    private static func commit(_ refresh: PendingRefresh, store: ListingStore, domain: NSFileProviderDomain, settings: SettingsStore) async -> (anchor: Data, committed: Bool) {
        let result = await store.commitWithResult(refresh)
        guard result.committed else { return result }
        let profileID = domain.identifier.rawValue
        if refresh.mode != nil {
            let completedAt = Date.now
            let duration = max(0, completedAt.timeIntervalSince(refresh.startedAt ?? completedAt))
            Log.enumeration.info("Completed \(refresh.mode == .full ? "full" : "automatic", privacy: .public) refresh: \(refresh.changes.count) changes in \(duration) seconds; success: \(refresh.succeeded), partial: \(refresh.partiallySucceeded)")
            settings.recordRefreshOutcome(RefreshOutcome(
                completedAt: completedAt,
                succeeded: refresh.succeeded,
                partiallySucceeded: refresh.partiallySucceeded,
                changedItemCount: refresh.changes.count,
                duration: duration,
                requestToken: refresh.mode == .full ? refresh.requestToken : nil
            ), profileID: profileID)
            CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                                 CFNotificationName(SharedContainer.refreshOutcomeNotification as CFString),
                                                 nil, nil, true)
        }
        // A click during an automatic scan queues a full check immediately after its last
        // batch, as does a folder Finder showed meanwhile. Retry failed scans through the
        // app's backoff, rather than a tight loop.
        let fullPending = settings.pendingFullRefresh(profileID: profileID)
            .map { refresh.mode != .full || $0 != refresh.requestToken } ?? false
        let opensPending = await store.hasPendingOpens
        if fullPending || opensPending,
           settings.isConnectionEnabled,
           !Task.isCancelled,
           let manager = NSFileProviderManager(for: domain) {
            try? await manager.signalEnumerator(for: .workingSet)
        }
        return result
    }

    func currentSyncAnchor(completionHandler: @escaping (NSFileProviderSyncAnchor?) -> Void) {
        tasks.run { [store] in completionHandler(NSFileProviderSyncAnchor(await store.anchor)) }
    }
}

/// Used for the trash, which a read-only library never has.
final class EmptyEnumerator: NSObject, NSFileProviderEnumerator {
    private let anchor = NSFileProviderSyncAnchor(Data("empty".utf8))

    func invalidate() {}

    func enumerateItems(for observer: NSFileProviderEnumerationObserver, startingAt page: NSFileProviderPage) {
        observer.finishEnumerating(upTo: nil)
    }

    func enumerateChanges(for observer: NSFileProviderChangeObserver, from anchor: NSFileProviderSyncAnchor) {
        observer.finishEnumeratingChanges(upTo: self.anchor, moreComing: false)
    }

    func currentSyncAnchor(completionHandler: @escaping (NSFileProviderSyncAnchor?) -> Void) {
        completionHandler(anchor)
    }
}

private func report(_ changes: ArraySlice<Change>, to observer: NSFileProviderChangeObserver) {
    var updated: [NSFileProviderItem] = []
    var deleted: [NSFileProviderItemIdentifier] = []
    for change in changes {
        switch change {
        case .update(let entry): updated.append(FileProviderItem(entry))
        case .delete(let id): deleted.append(NSFileProviderItemIdentifier(id))
        }
    }
    // Deletions first, matching `ChangeSet.changes`.
    if !deleted.isEmpty { observer.didDeleteItems(withIdentifiers: deleted) }
    if !updated.isEmpty { observer.didUpdate(updated) }
}

/// Pages are encoded as `offset:<n>`. The system's initial pages decode to offset 0.
private enum Page {
    static func make(offset: Int) -> NSFileProviderPage {
        NSFileProviderPage(Data("offset:\(offset)".utf8))
    }

    static func offset(of page: NSFileProviderPage) -> Int {
        let text = String(decoding: page.rawValue, as: UTF8.self)
        guard text.hasPrefix("offset:") else { return 0 }
        return Int(text.dropFirst("offset:".count)) ?? 0
    }
}

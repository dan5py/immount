import CryptoKit
import Foundation
import os

/// One change to report to the system: an item added or changed, or an item removed.
public enum Change: Sendable, Equatable {
    case update(Entry)
    case delete(ItemID)
}

public struct ChangeSet: Sendable, Equatable {
    public var updated: [Entry] = []
    public var deleted: [ItemID] = []

    public var isEmpty: Bool { updated.isEmpty && deleted.isEmpty }

    public init(updated: [Entry] = [], deleted: [ItemID] = []) {
        self.updated = updated
        self.deleted = deleted
    }

    /// Deletions first: when a duplicate name frees up, the item leaving must be gone before
    /// its sibling is renamed to that name, or the system renames one of them on disk.
    public var changes: [Change] {
        deleted.map(Change.delete) + updated.map(Change.update)
    }

    mutating func merge(_ other: ChangeSet) {
        updated += other.updated
        deleted += other.deleted
    }
}

public enum RefreshMode: Sendable, Equatable {
    case full
    case automatic
}

/// The result of comparing selected stored folders with the server, not yet saved.
public struct PendingRefresh: Sendable {
    /// Names this refresh in batch anchors, so a batch is only resumed with the same changes.
    public let id: String
    public let generation: Int
    public let changes: [Change]
    /// Nil identifies a provider metadata replay, rather than a server refresh.
    public internal(set) var mode: RefreshMode? = nil
    public internal(set) var requestToken: String? = nil
    public internal(set) var startedAt: Date? = nil
    public internal(set) var succeeded = true
    /// Only asset folders failed, and the server listed more folders than failed. The failed
    /// folders keep their old checkpoint, so later automatic refreshes retry them.
    public internal(set) var partiallySucceeded = false
    /// New listings to store; nil removes a folder's listing.
    let listings: [ItemID: [Entry]?]
    /// A provider metadata change delivered by this refresh, committed with its final batch.
    var providerMetadataRevision: Int? = nil
    var successfulFetches: [ItemID: Date] = [:]
    var failedFetches: [ItemID: Date] = [:]
    var coldCursor: String? = nil
    var listingRevisions: [ItemID: UInt64] = [:]
}

/// Remembers the last listing of every folder handed to the system, so a later
/// refresh can report exactly what was added, changed or removed on the server.
///
/// Anchors are `<epoch>:<generation>`, or `<epoch>:<generation>:<refresh>:<offset>` while a
/// refresh is delivered in batches. The epoch changes when the store is created from scratch;
/// the generation changes every time a refresh is saved.
public actor ListingStore {
    /// Nested tag identifiers can exceed the filesystem's filename limit. Their bounded
    /// hashed filenames keep the identifier in the file so the working set can recover it.
    private struct TagListing: Codable {
        let container: ItemID
        let entries: [Entry]
    }

    private struct TagListingHeader: Decodable {
        let container: ItemID
    }

    private typealias RefreshResult = (refresh: PendingRefresh, error: Error?)

    /// Once the last waiter leaves, the preparation is cancelled and closed to newcomers:
    /// joining it would only hand them that cancellation.
    private final class RefreshWaiters: Sendable {
        private let state: OSAllocatedUnfairLock<(ids: Set<UUID>, closed: Bool)>
        init(_ first: UUID) { state = OSAllocatedUnfairLock(initialState: ([first], false)) }
        /// False when the preparation is already closed.
        func insert(_ id: UUID) -> Bool {
            state.withLock { state in
                guard !state.closed else { return false }
                state.ids.insert(id)
                return true
            }
        }
        func removeLast(_ id: UUID) -> Bool {
            state.withLock { state in
                state.ids.remove(id)
                if state.ids.isEmpty { state.closed = true }
                return state.closed
            }
        }
    }

    private struct Preparation {
        let id: UUID
        let task: Task<RefreshResult, Never>
        let waiters: RefreshWaiters
    }

    private struct Meta: Codable {
        var epoch: String
        var generation: Int
        /// Missing in older stores. Keep the existing epoch and listings when upgrading.
        var providerMetadataRevision: Int? = nil
    }

    private struct CachedListing {
        var entries: [Entry]
        var lastUse: UInt64
    }

    struct CacheLimit: Sendable {
        var listings: Int
        var entries: Int
        /// A few megabytes: the folders being browsed and a refresh's working copies.
        static let standard = CacheLimit(listings: 128, entries: 10_000)
    }

    struct Anchor: Equatable {
        var epoch: String
        var generation: Int
        var batch: (refresh: String, offset: Int)?

        init(epoch: String, generation: Int, batch: (refresh: String, offset: Int)? = nil) {
            self.epoch = epoch
            self.generation = generation
            self.batch = batch
        }

        init?(_ data: Data) {
            let parts = String(decoding: data, as: UTF8.self).split(separator: ":", omittingEmptySubsequences: false).map(String.init)
            guard let generation = parts.count > 1 ? Int(parts[1]) : nil else { return nil }
            epoch = parts[0]
            self.generation = generation
            switch parts.count {
            case 2: batch = nil
            case 4:
                guard let offset = Int(parts[3]), !parts[2].isEmpty else { return nil }
                batch = (parts[2], offset)
            default: return nil
            }
        }

        var data: Data {
            var parts = [epoch, String(generation)]
            if let batch { parts += [batch.refresh, String(batch.offset)] }
            return Data(parts.joined(separator: ":").utf8)
        }

        static func == (lhs: Anchor, rhs: Anchor) -> Bool {
            lhs.epoch == rhs.epoch && lhs.generation == rhs.generation
                && lhs.batch?.refresh == rhs.batch?.refresh && lhs.batch?.offset == rhs.batch?.offset
        }
    }

    /// Where the working set should continue delivering changes.
    public enum ResumePoint: Sendable {
        /// Start a new refresh.
        case start
        /// Continue this refresh at this change.
        case batch(PendingRefresh, offset: Int)
    }

    /// Folders that always exist. A failure listing them is never taken as a deletion.
    static let permanentContainers: Set<ItemID> = [.root, .albums, .favorites, .people, .tags, .timeline]

    private let directory: URL
    private var meta: Meta
    /// Recently used listings. The extension is terminated if it uses too much memory, so
    /// the rest are read from disk again when needed.
    private var cache: [ItemID: CachedListing] = [:]
    private var cachedEntryCount = 0
    private var cacheClock: UInt64 = 0
    private let cacheLimit: CacheLimit
    /// Listings whose last write failed. Only the cache holds them, so they are never evicted.
    private var dirtyListings: Set<ItemID> = []
    private var knownContainers: Set<ItemID>?
    private var listingRevisions: [ItemID: UInt64] = [:]
    private var lastSuccessfulFetch: [ItemID: Date] = [:]
    /// Consecutive failed fetches of an asset folder since it was last listed, and the latest one.
    private var fetchFailures: [ItemID: (count: Int, last: Date)] = [:]
    private var lastBrowse: [ItemID: Date] = [:]
    /// Folders Finder showed again whose listing was old enough to check (see `recordOpen`).
    private var pendingOpens: Set<ItemID> = []
    private var coldCursor: String?
    private var pending: PendingRefresh?
    private var pendingError: Error?
    private var preparation: Preparation?

    public init(directory: URL) {
        self.init(directory: directory, cacheLimit: .standard)
    }

    init(directory: URL, cacheLimit: CacheLimit) {
        self.directory = directory
        self.cacheLimit = cacheLimit
        let listings = directory.appending(path: "listings", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: listings, withIntermediateDirectories: true)

        let metaURL = directory.appending(path: "meta.json")
        if let data = try? Data(contentsOf: metaURL), let meta = try? JSONDecoder().decode(Meta.self, from: data) {
            self.meta = meta
        } else {
            meta = Meta(epoch: UUID().uuidString, generation: 0)
            try? JSONEncoder().encode(meta).write(to: metaURL, options: .atomic)
        }
    }

    // MARK: Anchors

    public var anchor: Data {
        Anchor(epoch: meta.epoch, generation: meta.generation).data
    }

    /// An anchor in the middle of delivering `refresh` in batches.
    public func anchor(for refresh: PendingRefresh, offset: Int) -> Data {
        Anchor(epoch: meta.epoch, generation: meta.generation, batch: (refresh.id, offset)).data
    }

    /// False for anchors issued before the store was reset. Enough for folder enumerators,
    /// which report no changes of their own.
    public func isValid(_ anchor: Data) -> Bool {
        Anchor(anchor)?.epoch == meta.epoch
    }

    /// For the working set: where to continue, or nil when the system must enumerate from
    /// scratch. That is the case for an anchor from another generation (the system missed or
    /// did not save a refresh) and for a batch whose refresh is gone (e.g. the extension
    /// restarted): a new refresh would be compared with what was saved, not with what the
    /// system already received, and could leave items behind.
    public func resumePoint(_ anchor: Data) -> ResumePoint? {
        guard let anchor = Anchor(anchor), anchor.epoch == meta.epoch, anchor.generation == meta.generation else { return nil }
        guard let batch = anchor.batch else { return .start }
        guard let pending, pending.generation == meta.generation, pending.id == batch.refresh,
              batch.offset <= pending.changes.count else { return nil }
        return .batch(pending, offset: batch.offset)
    }

    // MARK: Listings

    public func listing(for container: ItemID) -> [Entry]? {
        if let cached = cache[container] {
            cacheClock &+= 1
            cache[container]?.lastUse = cacheClock
            return cached.entries
        }
        guard let entries = storedListing(for: container) else { return nil }
        cacheListing(entries, for: container)
        return entries
    }

    private func storedListing(for container: ItemID) -> [Entry]? {
        guard let data = try? Data(contentsOf: fileURL(for: container)) else { return nil }
        if case .tag = container {
            guard let listing = try? JSONDecoder().decode(TagListing.self, from: data),
                  listing.container == container else { return nil }
            return listing.entries
        }
        return try? JSONDecoder().decode([Entry].self, from: data)
    }

    private func cacheListing(_ entries: [Entry], for container: ItemID) {
        uncacheListing(container)
        cacheClock &+= 1
        cache[container] = CachedListing(entries: entries, lastUse: cacheClock)
        cachedEntryCount += entries.count
        // The listing just stored stays even if it alone exceeds the limit: its caller
        // usually reads it again right away.
        while cache.count > cacheLimit.listings || cachedEntryCount > cacheLimit.entries,
              let oldest = cache.lazy.filter({ $0.key != container && !self.dirtyListings.contains($0.key) })
                  .min(by: { $0.value.lastUse < $1.value.lastUse })?.key {
            uncacheListing(oldest)
        }
    }

    private func uncacheListing(_ container: ItemID) {
        guard let cached = cache.removeValue(forKey: container) else { return }
        cachedEntryCount -= cached.entries.count
    }

    /// The containers whose listings are currently decoded in memory.
    var cachedContainers: Set<ItemID> { Set(cache.keys) }

    public func save(_ entries: [Entry], for container: ItemID) {
        // A direct enumeration supersedes any in-flight refresh of this container, even
        // when its new listing happens to compare equal to the previous one.
        listingRevisions[container, default: 0] &+= 1
        fetchFailures[container] = nil
        guard listing(for: container) != entries || dirtyListings.contains(container) else { return }
        knownContainers?.insert(container)
        if write(entries, for: container) { dirtyListings.remove(container) }
        else { dirtyListings.insert(container) }
        cacheListing(entries, for: container)
    }

    private func write(_ entries: [Entry], for container: ItemID) -> Bool {
        let data: Data?
        if case .tag = container {
            data = try? JSONEncoder().encode(TagListing(container: container, entries: entries))
        } else {
            data = try? JSONEncoder().encode(entries)
        }
        guard let data else { return false }
        do {
            try data.write(to: fileURL(for: container), options: .atomic)
            return true
        } catch { return false }
    }

    private func remove(_ container: ItemID) -> Bool {
        do {
            try FileManager.default.removeItem(at: fileURL(for: container))
        } catch let error as CocoaError where error.code == .fileNoSuchFile {
            // An already absent listing has the requested state.
        } catch { return false }
        uncacheListing(container)
        dirtyListings.remove(container)
        knownContainers?.remove(container)
        listingRevisions[container, default: 0] &+= 1
        lastSuccessfulFetch[container] = nil
        fetchFailures[container] = nil
        lastBrowse[container] = nil
        pendingOpens.remove(container)
        return true
    }

    /// Finds an item in its parent's stored listing.
    public func entry(for id: ItemID) -> Entry? {
        listing(for: id.parent)?.first { $0.id == id }
    }

    /// Every folder whose listing has been handed to the system.
    public func containers() -> [ItemID] {
        if let knownContainers { return Array(knownContainers) }
        let files = (try? FileManager.default.contentsOfDirectory(at: directory.appending(path: "listings"), includingPropertiesForKeys: nil)) ?? []
        let recovered: [ItemID] = files.compactMap { url in
            if url.lastPathComponent.hasPrefix("tag-") {
                guard let data = try? Data(contentsOf: url),
                      let listing = try? JSONDecoder().decode(TagListingHeader.self, from: data),
                      case .tag = listing.container,
                      fileURL(for: listing.container).lastPathComponent == url.lastPathComponent else { return nil }
                return listing.container
            }
            return Data(base64URLEncoded: url.deletingPathExtension().lastPathComponent)
                .flatMap { ItemID(rawValue: String(decoding: $0, as: UTF8.self)) }
        }
        let known = Set(recovered).union(dirtyListings)
        knownContainers = known
        return Array(known)
    }

    /// Every stored item, for enumerating the working set from scratch. Listings are read
    /// once, so they are not added to the cache.
    public func allEntries() -> [Entry] {
        containers().sorted { $0.depth < $1.depth }.flatMap { cache[$0]?.entries ?? storedListing(for: $0) ?? [] }
    }

    private func fileURL(for container: ItemID) -> URL {
        let name: String
        if case .tag = container {
            let digest = SHA256.hash(data: Data(container.rawValue.utf8))
            name = "tag-" + digest.map { String(format: "%02x", $0) }.joined()
        } else {
            name = Data(container.rawValue.utf8).base64URLEncodedString()
        }
        return directory.appending(path: "listings").appending(path: name + ".json")
    }

    // MARK: Refreshing

    public func recordBrowse(_ container: ItemID, at date: Date = .now) {
        guard container.isFolder else { return }
        lastBrowse[container] = date
    }

    /// The shortest time between two checks of a folder Finder keeps showing.
    public static let reopenRefreshAge: TimeInterval = 15

    /// Finder started showing a folder it listed before: a new window, Back, the path bar.
    /// Finder will not ask for its contents again, so returns true when the stored listing
    /// is old enough to check now; the next refresh then fetches it even if nothing else
    /// says it changed. Unknown folders are left to their first enumeration.
    public func recordOpen(_ container: ItemID, at now: Date = .now) -> Bool {
        guard container.isFolder, listing(for: container) != nil else { return false }
        lastBrowse[container] = now
        guard lastCheckAge(container, at: now) >= Self.reopenRefreshAge else { return false }
        pendingOpens.insert(container)
        return true
    }

    /// Folders shown while a refresh was already running wait for one more refresh.
    public var hasPendingOpens: Bool { !pendingOpens.isEmpty }

    public func needsMetadataRefresh(revision: Int) -> Bool {
        (meta.providerMetadataRevision ?? 0) < revision
    }

    /// Provider-owned root folders can change between app versions. Existing domains
    /// publish them through an ordinary refresh; a new domain gets them when first listed.
    public func needsRootRefresh(_ rootFolders: [Entry]) -> Bool {
        guard let stored = listing(for: .root) else { return false }
        return !Self.diff(old: stored, new: rootFolders).isEmpty
    }

    /// Re-advertises provider-owned metadata without fetching the server. In particular,
    /// policy updates must reach unchanged downloaded items. New root folders can be
    /// included in the same batch so an upgrade does not wait for another refresh.
    /// The ordinary batch anchors keep this replay resumable until its final commit.
    public func prepareMetadataRefresh(revision: Int, root: Entry, addingRootFolders rootFolders: [Entry] = []) -> PendingRefresh? {
        guard needsMetadataRefresh(revision: revision) else { return nil }
        if let pending { return pending }
        guard preparation == nil else { return nil }

        let storedRoot = listing(for: .root)
        let additions = storedRoot.map { stored in rootFolders.filter { folder in !stored.contains { $0.id == folder.id } } } ?? []
        var seen: Set<ItemID> = []
        let entries = ([root] + additions + allEntries()).filter { seen.insert($0.id).inserted }
        var refresh = PendingRefresh(
            id: UUID().uuidString,
            generation: meta.generation,
            changes: entries.map(Change.update),
            listings: additions.isEmpty ? [:] : [.root: .some((storedRoot ?? []) + additions)]
        )
        refresh.providerMetadataRevision = revision
        refresh.listingRevisions = Dictionary(uniqueKeysWithValues: containers().map { ($0, listingRevisions[$0, default: 0]) })
        pending = refresh
        pendingError = nil
        return refresh
    }

    /// Coalesces concurrent callers and freezes their result until its last batch commits.
    /// Automatic refreshes fetch cheap indexes first, then only due or changed asset folders.
    public func prepareRefresh(
        mode: RefreshMode = .full,
        now: Date = .now,
        requestToken: String? = nil,
        maxConcurrent: Int = 4,
        fetch: @escaping @Sendable (ItemID) async throws -> [Entry]
    ) async -> (refresh: PendingRefresh, error: Error?) {
        guard !Task.isCancelled else { return cancelledRefresh(generation: meta.generation) }
        if let pending { return (pending, pendingError) }

        let waiter = UUID()
        let flight: Preparation
        if let existing = preparation, existing.waiters.insert(waiter) {
            flight = existing
        } else {
            // A cancelled preparation may still be winding down. Replacing it here means
            // its late `finishPreparation` finds a different id and stores nothing.
            let id = UUID()
            let generation = meta.generation
            let task = Task {
                let result = await self.buildRefresh(
                    mode: mode, now: now, requestToken: requestToken,
                    generation: generation, maxConcurrent: maxConcurrent, fetch: fetch
                )
                self.finishPreparation(id: id, result: result)
                return result
            }
            flight = Preparation(id: id, task: task, waiters: RefreshWaiters(waiter))
            preparation = flight
        }

        let result = await withTaskCancellationHandler {
            await flight.task.value
        } onCancel: {
            // Cancellation handlers cannot await the actor. Removing the last waiter and
            // cancelling shared I/O must happen before another network phase can start.
            if flight.waiters.removeLast(waiter) { flight.task.cancel() }
        }
        guard !Task.isCancelled else { return cancelledRefresh(generation: result.refresh.generation) }
        return result
    }

    private func finishPreparation(id: UUID, result: RefreshResult) {
        guard preparation?.id == id else { return }
        preparation = nil
        guard !Task.isCancelled, result.refresh.generation == meta.generation else { return }
        pending = result.refresh
        pendingError = result.error
    }

    private func cancelledRefresh(generation: Int) -> RefreshResult {
        var refresh = PendingRefresh(id: UUID().uuidString, generation: generation, changes: [], listings: [:])
        refresh.succeeded = false
        return (refresh, CancellationError())
    }

    private static func isMetadataContainer(_ container: ItemID) -> Bool {
        switch container {
        case .root, .albums, .people, .tags, .timeline, .year: true
        default: false
        }
    }

    private static func age(_ date: Date?, at now: Date) -> TimeInterval {
        guard let date, date <= now else { return .infinity }
        return now.timeIntervalSince(date)
    }

    /// Time since a folder was last fetched, whether the fetch worked or not.
    private func lastCheckAge(_ container: ItemID, at now: Date) -> TimeInterval {
        min(Self.age(lastSuccessfulFetch[container], at: now), Self.age(fetchFailures[container]?.last, at: now))
    }

    /// Automatic refreshes wait longer after each failed fetch of a folder, up to the longest
    /// automatic interval. Its checkpoint does not advance while it fails, so otherwise every
    /// check would fetch it again.
    private func isBackingOff(_ container: ItemID, at now: Date) -> Bool {
        guard let failure = fetchFailures[container] else { return false }
        let delay = min(RefreshPolicy.maximumInterval, 30 * Double(1 << min(failure.count - 1, 5)))
        return Self.age(failure.last, at: now) < delay
    }

    private static func fetchContainers(
        _ containers: [ItemID], maxConcurrent: Int,
        fetch: @escaping @Sendable (ItemID) async throws -> [Entry]
    ) async -> [ItemID: Result<[Entry], Error>] {
        await withTaskGroup(of: (ItemID, Result<[Entry], Error>).self) { group in
            var queue = containers[...]
            var results: [ItemID: Result<[Entry], Error>] = [:]
            func addNext() {
                guard !Task.isCancelled, let container = queue.popFirst() else { return }
                group.addTask {
                    // One return after the do/catch: optimized builds (Swift 6.4) corrupt the
                    // task's captures and result when it returns from both do and catch.
                    let result: Result<[Entry], Error>
                    do { result = .success(try await fetch(container)) }
                    catch { result = .failure(error) }
                    return (container, result)
                }
            }
            for _ in 0..<max(1, min(maxConcurrent, containers.count)) { addNext() }
            while let (container, result) = await group.next() {
                results[container] = result
                if Task.isCancelled { group.cancelAll() }
                else { addNext() }
            }
            return results
        }
    }

    private func buildRefresh(
        mode: RefreshMode, now: Date, requestToken: String?, generation: Int,
        maxConcurrent: Int, fetch: @escaping @Sendable (ItemID) async throws -> [Entry]
    ) async -> RefreshResult {
        let containers = containers()
        let metadata = containers.filter(Self.isMetadataContainer)
        // Metadata folders are fetched on every refresh; opened asset folders join this one.
        let opened = pendingOpens
        pendingOpens.removeAll()
        // Opened folders this refresh never checked wait for the next one.
        func cancelled() -> RefreshResult {
            pendingOpens.formUnion(opened)
            return cancelledRefresh(generation: generation)
        }
        var revisions: [ItemID: UInt64] = [:]
        var previous: [ItemID: [Entry]] = [:]
        for container in metadata {
            revisions[container] = listingRevisions[container, default: 0]
            previous[container] = listing(for: container) ?? []
        }
        var results = await Self.fetchContainers(metadata, maxConcurrent: maxConcurrent, fetch: fetch)
        guard !Task.isCancelled, generation == meta.generation else { return cancelled() }

        var changedFolders = Set<ItemID>()
        for container in metadata where revisions[container] == listingRevisions[container, default: 0] {
            if case .success(let entries)? = results[container] {
                changedFolders.formUnion(Self.diff(old: previous[container] ?? [], new: entries).updated.filter(\.isFolder).map(\.id))
            }
        }
        let assetFolders = containers.filter { !Self.isMetadataContainer($0) }
        var selected = Set<ItemID>()
        for container in assetFolders {
            let age = Self.age(lastSuccessfulFetch[container], at: now)
            let recent = Self.age(lastBrowse[container], at: now) <= 2 * 60
            let reopened = opened.contains(container) && lastCheckAge(container, at: now) >= Self.reopenRefreshAge
            let due = !isBackingOff(container, at: now) && (age >= 10 * 60 || (recent && age >= 30))
            if mode == .full || changedFolders.contains(container) || due || reopened {
                selected.insert(container)
            }
        }
        var nextColdCursor: String?
        if mode == .automatic {
            let due = assetFolders.filter {
                !selected.contains($0) && !isBackingOff($0, at: now) && Self.age(lastSuccessfulFetch[$0], at: now) >= 5 * 60
            }.sorted { $0.rawValue < $1.rawValue }
            // Rotate independently of success so a failing folder cannot starve its peers.
            let split = coldCursor.flatMap { cursor in due.firstIndex { $0.rawValue > cursor } } ?? 0
            let rotated = Array(due[split...]) + Array(due[..<split])
            let cold = rotated.prefix(2)
            selected.formUnion(cold)
            nextColdCursor = cold.last?.rawValue
        }
        for container in selected {
            revisions[container] = listingRevisions[container, default: 0]
        }
        let assets = await Self.fetchContainers(Array(selected), maxConcurrent: maxConcurrent, fetch: fetch)
        results.merge(assets) { _, latest in latest }
        guard !Task.isCancelled, generation == meta.generation else { return cancelled() }
        // A direct Finder enumeration that finished while the network was in flight has
        // already supplied fresher data. Do not overwrite or checkpoint that container.
        results = results.filter { revisions[$0.key] == listingRevisions[$0.key, default: 0] }

        // If everything failed as "not found", the server (or a proxy in front of it) is
        // broken; deleting the whole library from Finder would be the wrong answer.
        let remote = results.filter { $0.key != .root }.values
        let failures = remote.compactMap { result -> Error? in
            if case .failure(let error) = result { return error }
            return nil
        }
        let allRemoteMissing = !remote.isEmpty && failures.count == remote.count
            && failures.allSatisfy { ($0 as? ImmichError) == .notFound }

        var listings: [ItemID: [Entry]?] = [:]
        var expectedRevisions: [ItemID: UInt64] = [:]
        func current(_ container: ItemID) -> [Entry]? {
            expectedRevisions[container] = listingRevisions[container, default: 0]
            if let overlay = listings[container] { return overlay }
            return listing(for: container)
        }
        /// Forgets a folder and everything stored below it, reporting nothing: its deletion is
        /// reported through its parent.
        func dropSilently(_ container: ItemID) {
            for child in current(container) ?? [] where child.isFolder {
                dropSilently(child.id)
            }
            listings[container] = .some(nil)
        }

        var changes = ChangeSet()
        var successfulFetches: [ItemID: Date] = [:]
        var failedFetches: [ItemID: Date] = [:]
        var metadataFailed = false
        var firstError: Error? = allRemoteMissing ? failures.first : nil
        // Parents first, so a folder removed from its parent is not resurrected by its own refresh.
        for container in results.keys.sorted(by: { ($0.depth, $0.rawValue) < ($1.depth, $1.rawValue) }) {
            // The root is local provider metadata. A new root folder must still appear
            // while a broken server leaves every remote listing untouched.
            if allRemoteMissing && container != .root { continue }
            guard let result = results[container], !(listings[container].map { $0 == nil } ?? false) else { continue }
            if container != .root, current(container.parent)?.contains(where: { $0.id == container }) != true {
                dropSilently(container)
                continue
            }
            switch result {
            case .success(let entries):
                let diff = Self.diff(old: current(container) ?? [], new: entries)
                changes.merge(diff)
                successfulFetches[container] = now
                if current(container) != entries || dirtyListings.contains(container) { listings[container] = .some(entries) }
                for removed in diff.deleted where removed.isFolder {
                    dropSilently(removed)
                }
            case .failure(ImmichError.notFound) where !Self.permanentContainers.contains(container):
                // The folder itself is gone; report its children too in case its parent was not refreshed.
                changes.deleted += (current(container) ?? []).map(\.id)
                dropSilently(container)
            case .failure(let error):
                firstError = firstError ?? error
                if Self.isMetadataContainer(container) { metadataFailed = true }
                else { failedFetches[container] = now }
            }
        }

        var refresh = PendingRefresh(id: UUID().uuidString, generation: generation, changes: changes.changes, listings: listings)
        refresh.mode = mode
        refresh.requestToken = mode == .full ? requestToken : nil
        refresh.startedAt = now
        refresh.succeeded = firstError == nil
        // Broken asset folders do not make the connection look broken while more folders are
        // listed, since they back off on their own. Metadata folders are fetched on every
        // refresh, so when one fails, or most folders do, the app slows its checks down.
        let listed = successfulFetches.keys.filter { $0 != .root }.count
        refresh.partiallySucceeded = firstError != nil && !metadataFailed && listed > failedFetches.count
        refresh.successfulFetches = successfulFetches
        refresh.failedFetches = failedFetches
        refresh.coldCursor = nextColdCursor
        refresh.listingRevisions = expectedRevisions
        return (refresh, firstError)
    }

    /// Saves a delivered refresh and returns the anchor for the new state.
    ///
    /// The new generation is saved first: if the process dies before the listings are written,
    /// the system's anchor no longer matches and it enumerates from scratch, instead of
    /// resuming against listings that already include changes it never received.
    public func commit(_ refresh: PendingRefresh) -> Data {
        commitWithResult(refresh).anchor
    }

    public func commitWithResult(_ refresh: PendingRefresh) -> (anchor: Data, committed: Bool) {
        guard refresh.generation == meta.generation, pending?.id == refresh.id else { return (anchor, false) }
        pending = nil
        pendingError = nil
        guard refresh.listingRevisions.allSatisfy({ listingRevisions[$0.key, default: 0] == $0.value }) else {
            return (anchor, false)
        }
        if !refresh.changes.isEmpty {
            // If even that cannot be saved, keep the old listings: the system will be asked to
            // enumerate again, and gets a consistent picture.
            let priorRevision = meta.providerMetadataRevision
            if let revision = refresh.providerMetadataRevision {
                meta.providerMetadataRevision = max(priorRevision ?? 0, revision)
            }
            guard bumpGeneration() else {
                meta.providerMetadataRevision = priorRevision
                return (anchor, false)
            }
        }
        var committed = true
        for (container, entries) in refresh.listings {
            if let entries {
                if write(entries, for: container) {
                    dirtyListings.remove(container)
                    cacheListing(entries, for: container)
                    knownContainers?.insert(container)
                    listingRevisions[container, default: 0] &+= 1
                } else {
                    committed = false
                    dirtyListings.insert(container)
                    cacheListing(entries, for: container)
                    knownContainers?.insert(container)
                }
            } else if !remove(container) {
                committed = false
            }
        }
        if committed {
            lastSuccessfulFetch.merge(refresh.successfulFetches) { _, latest in latest }
            for container in refresh.successfulFetches.keys { fetchFailures[container] = nil }
            for (container, date) in refresh.failedFetches {
                fetchFailures[container] = ((fetchFailures[container]?.count ?? 0) + 1, date)
            }
            if let cursor = refresh.coldCursor { coldCursor = cursor }
        } else {
            // Do not let a failed listing write look like a fully saved change set after
            // restart. The new in-memory epoch differs from the metadata file on disk.
            meta.epoch = UUID().uuidString
        }
        return (anchor, committed)
    }

    /// Returns false if the new generation could not be saved. The in-memory epoch then
    /// changes too, so anchors handed out until a restart are rejected.
    @discardableResult
    func bumpGeneration() -> Bool {
        meta.generation += 1
        do {
            try JSONEncoder().encode(meta).write(to: directory.appending(path: "meta.json"), options: .atomic)
            return true
        } catch {
            meta.epoch = UUID().uuidString
            return false
        }
    }

    static func diff(old: [Entry], new: [Entry]) -> ChangeSet {
        let oldByID = Dictionary(old.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let newIDs = Set(new.map(\.id))
        return ChangeSet(
            updated: new.filter { oldByID[$0.id] != $0 },
            deleted: old.map(\.id).filter { !newIDs.contains($0) }
        )
    }
}

extension Data {
    init?(base64URLEncoded string: String) {
        var base64 = string.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        self.init(base64Encoded: base64)
    }

    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

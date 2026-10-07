import AppKit
import FileProvider
import ImmountKit
import os

enum Log {
    private static let subsystem = Bundle.main.bundleIdentifier ?? "immount.FileProvider"
    static let enumeration = Logger(subsystem: subsystem, category: "enumeration")
    static let content = Logger(subsystem: subsystem, category: "content")
    static let connection = Logger(subsystem: subsystem, category: "connection")
}

/// Exposes an Immich library as a read-only folder in Finder.
final class FileProviderExtension: NSObject, NSFileProviderReplicatedExtension, NSFileProviderThumbnailing {
    private let domain: NSFileProviderDomain
    private let store: ListingStore
    /// Uses `ImmichSession.shared`: no disk cache (Finder keeps its own thumbnails) and no
    /// redirects to other hosts.
    private let provider = ConnectionProvider()
    private let tasks = TaskBag()
    private let isInvalidated = OSAllocatedUnfairLock(initialState: false)
    private let reopenCheck: Debouncer

    required init(domain: NSFileProviderDomain) {
        self.domain = domain
        store = ListingStore(directory: SharedContainer.stateDirectory(for: domain.identifier.rawValue))
        reopenCheck = Debouncer(delay: .seconds(1)) { [isInvalidated] in
            guard !isInvalidated.withLock({ $0 }), SettingsStore.shared.isConnectionEnabled,
                  let manager = NSFileProviderManager(for: domain) else { return }
            try? await manager.signalEnumerator(for: .workingSet)
        }
        super.init()
        Self.watchApp(domain: domain)
        // Publishing a new content policy must also update items already registered with
        // macOS. This only schedules a metadata replay; it does not fetch or evict content.
        tasks.run { [store, domain] in
            let needsMetadata = await store.needsMetadataRefresh(revision: FileProviderItem.metadataRevision)
            let needsRoot = await store.needsRootRefresh(Catalog.rootFolders)
            guard needsMetadata || needsRoot,
                  !Task.isCancelled,
                  let manager = NSFileProviderManager(for: domain) else { return }
            do {
                try await manager.signalEnumerator(for: .workingSet)
            } catch {
                // The next normal working-set refresh will retry the uncommitted replay.
                Log.enumeration.error("Could not schedule provider metadata refresh")
            }
        }
    }

    /// Domains whose Finder location the app watcher removes. Entries are never removed, so
    /// a non-empty value means the watcher is already running in this process.
    private static let watchedDomains = OSAllocatedUnfairLock<[NSFileProviderDomainIdentifier: NSFileProviderDomain]>(uncheckedState: [:])

    /// The Finder location exists only while the app runs. A normal quit removes it, but a
    /// crash, a force quit or a stopped debug session cannot, so the extension checks that
    /// the app is still running; when it is gone, it removes the location itself and exits.
    /// This also ends the extension within seconds of a normal quit.
    ///
    /// The system can create the extension more than once in the same process, so only the
    /// first instance starts the observer and the polling loop; later ones add their domain.
    private static func watchApp(domain: NSFileProviderDomain) {
        let isWatching = watchedDomains.withLockUnchecked { domains in
            let isWatching = !domains.isEmpty
            domains[domain.identifier] = domain
            return isWatching
        }
        guard !isWatching else { return }
        // A normal quit has already removed the location; nothing is left to do.
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(), nil, { _, _, _, _, _ in exit(0) },
            SharedContainer.appQuitNotification as CFString, nil, .deliverImmediately
        )
        guard let appID = Bundle.main.object(forInfoDictionaryKey: "ImmountAppBundleID") as? String,
              !appID.isEmpty else { return }
        Task.detached(priority: .utility) {
            var missedChecks = 0
            while true {
                try? await Task.sleep(for: .seconds(2))
                if !NSRunningApplication.runningApplications(withBundleIdentifier: appID).isEmpty {
                    missedChecks = 0
                    continue
                }
                missedChecks += 1
                // Twice in a row, so an app that is relaunching is not taken for gone.
                guard missedChecks >= 2 else { continue }
                Log.connection.notice("Immount is not running; removing the Finder location")
                for domain in watchedDomains.withLockUnchecked({ Array($0.values) }) {
                    do {
                        try await NSFileProviderManager.remove(domain, mode: .removeAll)
                    } catch {
                        // Already removed, usually by the app itself when it quit.
                        Log.connection.info("Removing the Finder location: \(error, privacy: .public)")
                    }
                }
                exit(0)
            }
        }
    }

    /// The shared session stays valid; invalidating it would crash requests still being made.
    func invalidate() {
        isInvalidated.withLock { $0 = true }
        tasks.cancelAll()
    }

    /// The connection for this domain, resolved again for every operation so a new key or
    /// address applies right away.
    private func connection() throws -> Connection {
        guard !isInvalidated.withLock({ $0 }) else { throw CancellationError() }
        return try provider.connection(domainID: domain.identifier.rawValue)
    }

    /// Runs `operation` until it finishes, or until the returned progress is cancelled or the
    /// extension is invalidated. The operation always runs, so it always calls its completion
    /// handler; cancellation makes it finish early.
    private func track(_ progress: Progress = Progress(totalUnitCount: 1), _ operation: @escaping @Sendable () async -> Void) -> Progress {
        let task = Task { await operation() }
        progress.cancellationHandler = { task.cancel() }
        tasks.run {
            await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
        }
        if isInvalidated.withLock({ $0 }) { task.cancel() }
        return progress
    }

    private func catalog() throws -> Catalog {
        try connection().catalog
    }

    /// Maps an error for Finder, and drops the cached key when the server rejected it so the
    /// next attempt picks up a key the app saved in the meantime.
    private func report(_ error: Error) -> Error {
        if case ImmichError.unauthorized = error { provider.invalidateKey() }
        return fileProviderError(error)
    }

    // MARK: Items

    func item(for identifier: NSFileProviderItemIdentifier, request: NSFileProviderRequest, completionHandler: @escaping (NSFileProviderItem?, Error?) -> Void) -> Progress {
        guard let id = ItemID(identifier) else {
            completionHandler(nil, NSFileProviderError(.noSuchItem))
            return Progress()
        }
        if id == .root {
            completionHandler(FileProviderItem(Catalog.rootEntry), nil)
            return Progress()
        }
        return track { [self] in
            do {
                completionHandler(FileProviderItem(try await entry(for: id)), nil)
            } catch {
                completionHandler(nil, report(error))
            }
        }
    }

    private func entry(for id: ItemID) async throws -> Entry {
        if let stored = await store.entry(for: id) { return stored }
        return try await catalog().entry(for: id)
    }

    func fetchContents(
        for itemIdentifier: NSFileProviderItemIdentifier,
        version requestedVersion: NSFileProviderItemVersion?,
        request: NSFileProviderRequest,
        completionHandler: @escaping (URL?, NSFileProviderItem?, Error?) -> Void
    ) -> Progress {
        let progress = Progress(totalUnitCount: 100)
        guard let id = ItemID(itemIdentifier), let assetID = id.assetID else {
            completionHandler(nil, nil, NSFileProviderError(.noSuchItem))
            return progress
        }

        return track(progress) { [self] in
            do {
                let connection = try connection()
                var entry = try await entry(for: id)
                guard let manager = NSFileProviderManager(for: domain) else { throw NSFileProviderError(.providerNotFound) }
                // The system ignores this name; keep it short so long filenames still fit.
                let destination = try manager.temporaryDirectoryURL()
                    .appending(path: UUID().uuidString)
                    .appendingPathExtension((entry.filename as NSString).pathExtension)
                try await connection.client.downloadOriginal(assetID: assetID, to: destination, progress: progress)
                if let size = try? destination.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                    entry.size = Int64(size)
                }
                completionHandler(destination, FileProviderItem(entry), nil)
            } catch {
                Log.content.error("Download of \(assetID, privacy: .public) failed: \(error, privacy: .public)")
                completionHandler(nil, nil, report(error))
            }
        }
    }

    // MARK: Writes
    //
    // Finder offers no way to change the library (items lack the write capabilities), but the
    // Terminal can still try. These answers stop the system from retrying.

    /// Fields that only exist on this Mac and that items never report. Left pending, the system
    /// treats them as unsupported and keeps the local values, instead of taking the missing
    /// value for the server's.
    private static let localOnlyFields: NSFileProviderItemFields = [.tagData, .lastUsedDate, .extendedAttributes, .typeAndCreator]

    /// During a reimport (e.g. the system rebuilding its database), matches items found on
    /// disk to the server's. Anything else created in the library stays on this Mac only.
    func createItem(
        basedOn itemTemplate: NSFileProviderItem,
        fields: NSFileProviderItemFields,
        contents url: URL?,
        options: NSFileProviderCreateItemOptions = [],
        request: NSFileProviderRequest,
        completionHandler: @escaping (NSFileProviderItem?, NSFileProviderItemFields, Bool, Error?) -> Void
    ) -> Progress {
        guard options.contains(.mayAlreadyExist) else {
            completionHandler(nil, [], false, NSFileProviderError(.excludedFromSync))
            return Progress()
        }
        let parent = itemTemplate.parentItemIdentifier
        let filename = itemTemplate.filename
        return track { [self] in
            guard let parentID = ItemID(parent), parentID.isFolder else {
                completionHandler(nil, [], false, nil)
                return
            }
            var siblings = await store.listing(for: parentID)
            if siblings == nil { siblings = try? await catalog().children(of: parentID) }
            if let match = siblings?.first(where: { $0.filename.caseInsensitiveCompare(filename) == .orderedSame }) {
                // The bytes on disk may be stale; fetch the server's copy for files that have one.
                completionHandler(FileProviderItem(match), fields.intersection(Self.localOnlyFields), url != nil && !match.isFolder, nil)
            } else {
                // Not on the server (any more): the system removes the copy on disk.
                completionHandler(nil, [], false, nil)
            }
        }
    }

    /// Puts the server's version back, since nothing is sent to Immich. Changed fields the item
    /// reports are handled, so the system writes the returned values over the local ones and
    /// downloads a changed file again. Local-only fields stay as the user set them.
    func modifyItem(
        _ item: NSFileProviderItem,
        baseVersion version: NSFileProviderItemVersion,
        changedFields: NSFileProviderItemFields,
        contents newContents: URL?,
        options: NSFileProviderModifyItemOptions = [],
        request: NSFileProviderRequest,
        completionHandler: @escaping (NSFileProviderItem?, NSFileProviderItemFields, Bool, Error?) -> Void
    ) -> Progress {
        guard let id = ItemID(item.itemIdentifier) else {
            completionHandler(nil, [], false, NSFileProviderError(.noSuchItem))
            return Progress()
        }
        return track { [self] in
            do {
                let entry = id == .root ? Catalog.rootEntry : try await entry(for: id)
                completionHandler(FileProviderItem(entry), changedFields.intersection(Self.localOnlyFields), changedFields.contains(.contents), nil)
            } catch {
                completionHandler(nil, [], false, report(error))
            }
        }
    }

    func deleteItem(
        identifier: NSFileProviderItemIdentifier,
        baseVersion version: NSFileProviderItemVersion,
        options: NSFileProviderDeleteItemOptions = [],
        request: NSFileProviderRequest,
        completionHandler: @escaping (Error?) -> Void
    ) -> Progress {
        completionHandler(NSFileProviderError(.deletionRejected))
        return Progress()
    }

    // MARK: Enumeration

    func enumerator(for containerItemIdentifier: NSFileProviderItemIdentifier, request: NSFileProviderRequest) throws -> NSFileProviderEnumerator {
        if containerItemIdentifier == .trashContainer {
            return EmptyEnumerator()
        }
        let catalog: CatalogFactory = { [weak self] in
            guard let self else { throw NSFileProviderError(.notAuthenticated) }
            return try self.catalog()
        }
        if containerItemIdentifier == .workingSet {
            return WorkingSetEnumerator(catalog: catalog, store: store, domain: domain)
        }
        guard let id = ItemID(containerItemIdentifier) else {
            throw NSFileProviderError(.noSuchItem)
        }
        guard id.isFolder else {
            // The system follows a document an app has open through an enumerator on it.
            return ItemEnumerator(id: id, catalog: catalog, store: store)
        }
        if request.isFileViewerRequest { folderShown(id) }
        return ContainerEnumerator(container: id, catalog: catalog, store: store, isFileViewerRequest: request.isFileViewerRequest)
    }

    /// Finder asks for a folder's enumerator every time it shows the folder (a new window,
    /// Back, the path bar) and releases it on leaving, but lists a folder it knows from its
    /// own copy. Check such a folder now rather than at the next automatic refresh.
    private func folderShown(_ id: ItemID) {
        tasks.run { [store, reopenCheck] in
            guard await store.recordOpen(id) else { return }
            Log.enumeration.info("Finder showed \(id.rawValue, privacy: .public) again; checking it")
            await reopenCheck.request()
        }
    }

    // MARK: Thumbnails

    func fetchThumbnails(
        for itemIdentifiers: [NSFileProviderItemIdentifier],
        requestedSize size: CGSize,
        perThumbnailCompletionHandler: @escaping (NSFileProviderItemIdentifier, Data?, Error?) -> Void,
        completionHandler: @escaping (Error?) -> Void
    ) -> Progress {
        let progress = Progress(totalUnitCount: Int64(itemIdentifiers.count))
        let client: ImmichClient
        do {
            client = try connection().client
        } catch {
            completionHandler(report(error))
            return progress
        }
        // Finder asks for ~64-512px; the small WebP covers icon sizes, the JPEG preview the rest.
        let large = max(size.width, size.height) > 256

        return track(progress) { [self] in
            await withTaskGroup(of: (NSFileProviderItemIdentifier, Result<Data?, Error>).self) { group in
                var pending = itemIdentifiers[...]
                func addNext() {
                    guard let identifier = pending.popFirst() else { return }
                    _ = group.addTaskUnlessCancelled {
                        guard let assetID = ItemID(identifier)?.assetID else { return (identifier, .success(nil)) }
                        // One return after the do/catch (see `ListingStore.fetchContainers`).
                        let result: Result<Data?, Error>
                        do {
                            result = .success(try await client.thumbnail(assetID: assetID, large: large))
                        } catch {
                            result = .failure(error)
                        }
                        return (identifier, result)
                    }
                }
                for _ in 0..<6 { addNext() }
                while let (identifier, result) = await group.next() {
                    switch result {
                    case .success(let data): perThumbnailCompletionHandler(identifier, data, nil)
                    // No thumbnail yet (e.g. still being generated): nil and nil, as documented.
                    case .failure(ImmichError.notFound): perThumbnailCompletionHandler(identifier, nil, nil)
                    case .failure(let error): perThumbnailCompletionHandler(identifier, nil, report(error))
                    }
                    progress.completedUnitCount += 1
                    addNext()
                }
            }
            completionHandler(Task.isCancelled ? CocoaError(.userCancelled) : nil)
        }
    }
}

/// Translates errors into the codes Finder knows how to present.
func fileProviderError(_ error: Error) -> Error {
    switch error {
    case ImmichError.unauthorized:
        return NSFileProviderError(.notAuthenticated)
    case ImmichError.missingPermission(let message):
        // Not an authentication problem: Finder would offer to sign in, which does not help.
        return CocoaError(.fileReadNoPermission, userInfo: [
            NSLocalizedDescriptionKey: message.map { "The Immich API key is missing a permission: \($0)" } ?? "The Immich API key is missing a permission.",
        ])
    case ImmichError.notFound:
        return NSFileProviderError(.noSuchItem)
    case ImmichError.http(let status, _) where status >= 500:
        // The server is restarting or a proxy cannot reach it. The app signals when it is back.
        return NSFileProviderError(.serverUnreachable)
    case ImmichError.invalidResponse:
        return NSFileProviderError(.serverUnreachable)
    case let failure as ConnectionProvider.Failure:
        switch failure {
        case .notConfigured, .disconnected, .keyMissing:
            return NSFileProviderError(.notAuthenticated)
        case .keychainUnavailable(let status):
            Log.connection.error("Keychain unavailable: \(status)")
            return NSFileProviderError(.serverUnreachable)
        }
    case let error as URLError where error.code == .cancelled:
        return CocoaError(.userCancelled)
    case is URLError:
        return NSFileProviderError(.serverUnreachable)
    case is CancellationError:
        return CocoaError(.userCancelled)
    case let error as NSError where error.domain == NSCocoaErrorDomain || error.domain == NSFileProviderErrorDomain:
        return error
    default:
        // The system accepts only Cocoa and File Provider errors; wrap anything else.
        return NSError(domain: NSCocoaErrorDomain, code: NSXPCConnectionReplyInvalid, userInfo: [
            NSUnderlyingErrorKey: error as NSError,
            NSLocalizedDescriptionKey: (error as? LocalizedError)?.errorDescription ?? error.localizedDescription,
        ])
    }
}

import FileProvider
import Darwin
import Foundation
import os
import Testing
import UniformTypeIdentifiers
@testable import ImmountKit

@Suite struct FileProviderCacheTests {
    @Test func paginatesAndCountsProviderCopiesInsteadOfUniqueAssets() async throws {
        let first = CacheTestItem("asset:favorites/shared", size: 20)
        let otherCopy = CacheTestItem("asset:album:one/shared", size: 30)
        let enumerator = CacheTestEnumerator(pages: [
            [first, CacheTestItem("favorites", size: 99, type: .folder), CacheTestItem("unknown", size: 99)],
            [CacheTestItem(first.itemIdentifier.rawValue, size: 25), otherCopy,
             CacheTestItem("asset:favorites/dataless", size: 90, downloaded: false),
             CacheTestItem("asset:favorites/folder", size: 90, type: .folder)],
        ])
        let usage = try await FileProviderCache.usage(enumerator: enumerator) { id in
            switch id.rawValue {
            case first.itemIdentifier.rawValue: .downloaded(size: 25)
            case otherCopy.itemIdentifier.rawValue: .downloaded(size: 30)
            default: .notDownloaded
            }
        }
        #expect(usage.fileCount == 2)
        #expect(usage.totalBytes == 55)
        #expect(usage.unknownSizeCount == 0)
        #expect(enumerator.pagesRequested == [Data(), Data("1".utf8)])
        #expect(enumerator.invalidations == 1)
    }

    @Test func handlesMissingInvalidAndOverflowingSizesHonestly() async throws {
        let enumerator = CacheTestEnumerator(pages: [[
            CacheTestItem("asset:favorites/a", size: 0),
            CacheTestItem("asset:favorites/b", size: nil),
            CacheTestItem("asset:favorites/c", size: -1),
            CacheTestItem("asset:favorites/d", size: NSNumber(value: 1.5)),
            CacheTestItem("asset:favorites/e", size: NSNumber(value: Int64.max)),
            CacheTestItem("asset:favorites/f", size: 1),
        ]])
        let usage = try await FileProviderCache.usage(enumerator: enumerator) { id in
            switch id.rawValue {
            case "asset:favorites/a": .downloaded(size: 0)
            case "asset:favorites/c": .downloaded(size: -1)
            case "asset:favorites/e": .downloaded(size: Int64.max)
            case "asset:favorites/f": .downloaded(size: 1)
            default: .downloaded(size: nil)
            }
        }
        #expect(usage.fileCount == 6)
        #expect(usage.totalBytes == Int64.max)
        #expect(usage.unknownSizeCount == 4)
    }

    @Test func optionalMetadataDoesNotOverrideTheActualFilesystemState() async throws {
        let id = "asset:favorites/a"
        let enumerator = CacheTestEnumerator(pages: [
            [CacheTestItem(id, size: 20)],
            [CacheTestItem(id, size: nil, type: .folder, downloaded: false)],
        ])
        let usage = try await FileProviderCache.usage(enumerator: enumerator) { _ in .downloaded(size: 42) }
        #expect(usage.fileCount == 1)
        #expect(usage.totalBytes == 42)
    }

    @Test func missingDownloadedFlagUsesFilesystemInspection() async throws {
        let enumerator = CacheTestEnumerator(pages: [[CacheTestItemWithoutDownloadedFlag()]])
        let usage = try await FileProviderCache.usage(enumerator: enumerator) { _ in .downloaded(size: 42) }
        #expect(usage.fileCount == 1)
        #expect(usage.totalBytes == 42)
    }

    @Test func inspectsSeveralFilesAtOnceButNeverMoreThanTheWidth() async throws {
        let items = (0..<40).map { CacheTestItem("asset:favorites/\($0)", size: 1) }
        let counts = OSAllocatedUnfairLock(initialState: (current: 0, peak: 0))
        let usage = try await FileProviderCache.usage(enumerator: CacheTestEnumerator(pages: [items])) { _ in
            counts.withLock {
                $0.current += 1
                $0.peak = max($0.peak, $0.current)
            }
            try await Task.sleep(for: .milliseconds(5))
            counts.withLock { $0.current -= 1 }
            return .downloaded(size: 1)
        }
        #expect(usage.fileCount == 40)
        #expect(usage.totalBytes == 40)
        let peak = counts.withLock { $0.peak }
        #expect(peak > 1)
        #expect(peak <= FileProviderCache.inspectionWidth)
    }

    @Test func clearEvictsInEnumerationOrderWhenInspectionsFinishOutOfOrder() async throws {
        let ids = (0..<12).map { String(format: "asset:favorites/%02d", $0) }
        let evicted = OSAllocatedUnfairLock<[String]>(initialState: [])
        let result = try await FileProviderCache.clear(
            makeEnumerator: { CacheTestEnumerator(pages: [ids.map { CacheTestItem($0, size: 1) }]) },
            inspect: { id in
                // Earlier items take longer, so their inspections complete last.
                let index = ids.firstIndex(of: id.rawValue) ?? 0
                try await Task.sleep(for: .milliseconds(2 * (ids.count - index)))
                return .downloaded(size: 1)
            },
            evict: { id in evicted.withLock { $0.append(id.rawValue) } }
        )
        #expect(result.attempted == ids.count)
        #expect(evicted.withLock { $0 } == ids)
    }

    @Test func enumerationErrorsInvalidateAndDoNotReturnPartialUsage() async {
        let enumerator = CacheTestEnumerator(failure: CocoaError(.fileReadNoPermission))
        await #expect(throws: CocoaError(.fileReadNoPermission)) {
            _ = try await FileProviderCache.usage(enumerator: enumerator) { _ in .notDownloaded }
        }
        #expect(enumerator.invalidations == 1)
    }

    @Test func cancelledEnumerationInvalidatesAndIgnoresLateCompletion() async {
        let (starts, started) = AsyncStream<Void>.makeStream()
        let enumerator = CacheTestEnumerator(hangs: true, onStart: { started.yield(()) })
        let task = Task { try await FileProviderCache.usage(enumerator: enumerator) { _ in .notDownloaded } }
        var iterator = starts.makeAsyncIterator()
        _ = await iterator.next()
        task.cancel()
        await #expect(throws: CancellationError.self) { _ = try await task.value }
        #expect(enumerator.invalidations == 1)
        enumerator.deliverLateCompletion()
        started.finish()
    }

    @Test func aStalledEnumerationTimesOutAndInvalidates() async {
        let enumerator = CacheTestEnumerator(hangs: true)
        await #expect(throws: FileProviderCache.Failure.timedOut) {
            _ = try await FileProviderCache.usage(enumerator: enumerator, inspect: { _ in .notDownloaded }, timeout: 0.01)
        }
        #expect(enumerator.invalidations == 1)
    }

    @Test func clearingContinuesPastProtectedFilesAndRemeasures() async throws {
        let initial = CacheTestEnumerator(pages: [[
            CacheTestItem("asset:favorites/a", size: 10),
            CacheTestItem("asset:favorites/b", size: 20),
            CacheTestItem("asset:favorites/c", size: 30),
        ]])
        let remaining = CacheTestEnumerator(pages: [[CacheTestItem("asset:favorites/b", size: 20)]])
        let enumerators = OSAllocatedUnfairLock(initialState: [initial, remaining])
        let evicted = OSAllocatedUnfairLock<[String]>(initialState: [])
        let result = try await FileProviderCache.clear(
            makeEnumerator: { enumerators.withLock { $0.removeFirst() } },
            inspect: { id in .downloaded(size: id.rawValue == "asset:favorites/b" ? 20 : 10) },
            evict: { id in
                evicted.withLock { $0.append(id.rawValue) }
                if id.rawValue == "asset:favorites/b" { throw NSFileProviderError(.nonEvictable) }
            }
        )
        #expect(result.attempted == 3)
        #expect(result.removed == 2)
        #expect(result.failed == 1)
        #expect(result.failures.map(\.reason) == [.notEvictable])
        #expect(result.failures.map(\.count) == [1])
        #expect(result.remaining?.fileCount == 1)
        #expect(result.remaining?.totalBytes == 20)
        #expect(evicted.withLock { $0 } == ["asset:favorites/a", "asset:favorites/b", "asset:favorites/c"])
    }

    @Test func failedFinalMeasurementIsUnknownInsteadOfZero() async throws {
        let enumerators = OSAllocatedUnfairLock(initialState: [
            CacheTestEnumerator(pages: [[CacheTestItem("asset:favorites/a", size: 10)]]),
            CacheTestEnumerator(failure: CocoaError(.fileReadUnknown)),
        ])
        let result = try await FileProviderCache.clear(
            makeEnumerator: { enumerators.withLock { $0.removeFirst() } },
            inspect: { _ in .downloaded(size: 10) },
            evict: { _ in }
        )
        #expect(result.removed == 1)
        #expect(result.remaining == nil)
    }

    @Test func cancellationWaitsForCurrentEvictionAndStopsBeforeNextItem() async {
        let (starts, started) = AsyncStream<Void>.makeStream()
        let (finishes, finishCurrent) = AsyncStream<Void>.makeStream()
        let attempts = OSAllocatedUnfairLock(initialState: 0)
        let completed = OSAllocatedUnfairLock(initialState: false)
        let task = Task {
            defer { completed.withLock { $0 = true } }
            return try await FileProviderCache.clear(
                makeEnumerator: {
                    CacheTestEnumerator(pages: [[
                        CacheTestItem("asset:favorites/a", size: 10),
                        CacheTestItem("asset:favorites/b", size: 20),
                    ]])
                },
                inspect: { _ in .downloaded(size: 10) },
                evict: { _ in
                    attempts.withLock { $0 += 1 }
                    // A separate task models a native callback unaffected by caller cancellation.
                    let native = Task.detached {
                        var iterator = finishes.makeAsyncIterator()
                        _ = await iterator.next()
                    }
                    started.yield(())
                    await native.value
                }
            )
        }
        var iterator = starts.makeAsyncIterator()
        _ = await iterator.next()
        task.cancel()
        #expect(!completed.withLock { $0 })
        finishCurrent.yield(())
        await #expect(throws: CancellationError.self) { _ = try await task.value }
        #expect(attempts.withLock { $0 } == 1)
        started.finish()
        finishCurrent.finish()
    }

    @Test func inspectionFailureDoesNotProduceZeroUsageOrStartEviction() async {
        let makeEnumerator = {
            CacheTestEnumerator(pages: [[
                CacheTestItem("asset:favorites/a", size: nil, downloaded: false),
                CacheTestItem("asset:favorites/b", size: nil, downloaded: false),
            ]])
        }
        let inspect: @Sendable (NSFileProviderItemIdentifier) async throws -> FileProviderCache.LocalState = { id in
            if id.rawValue == "asset:favorites/b" { throw FileProviderCache.Failure.cannotInspect }
            return .downloaded(size: 42)
        }
        await #expect(throws: FileProviderCache.Failure.cannotInspect) {
            _ = try await FileProviderCache.usage(enumerator: makeEnumerator(), inspect: inspect)
        }
        let evictions = OSAllocatedUnfairLock(initialState: 0)
        await #expect(throws: FileProviderCache.Failure.cannotInspect) {
            _ = try await FileProviderCache.clear(
                makeEnumerator: makeEnumerator,
                inspect: inspect,
                evict: { _ in evictions.withLock { $0 += 1 } }
            )
        }
        #expect(evictions.withLock { $0 } == 0)
    }

    @Test func clearDoesNotEvictDatalessOrNonregularCandidates() async throws {
        let calls = OSAllocatedUnfairLock<[String]>(initialState: [])
        let result = try await FileProviderCache.clear(
            makeEnumerator: {
                CacheTestEnumerator(pages: [[
                    CacheTestItem("asset:favorites/downloaded", size: nil, downloaded: false),
                    CacheTestItem("asset:favorites/dataless", size: 100),
                    CacheTestItem("asset:favorites/symlink", size: 100),
                ]])
            },
            inspect: { id in id.rawValue == "asset:favorites/downloaded" ? .downloaded(size: 42) : .notDownloaded },
            evict: { id in calls.withLock { $0.append(id.rawValue) } }
        )
        #expect(result.attempted == 1)
        #expect(calls.withLock { $0 } == ["asset:favorites/downloaded"])
    }

    @Test func metadataInspectionUsesFileSizeWithoutFollowingLinksAndRestoresPolicy() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "immount-cache-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appending(path: "synthetic.bin")
        try Data(repeating: 0, count: 17).write(to: file)
        let link = directory.appending(path: "synthetic-link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
        let prior = getiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD)
        #expect(try FileProviderCache.inspectLocalFile(at: file) == .downloaded(size: 17))
        #expect(try FileProviderCache.inspectLocalFile(at: link) == .notDownloaded)
        #expect(try FileProviderCache.inspectLocalFile(at: directory) == .notDownloaded)
        #expect(try FileProviderCache.inspectLocalFile(at: directory.appending(path: "missing")) == .notDownloaded)
        #expect(getiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD) == prior)
    }

    @Test func datalessFlagExcludesLargeLogicalSizes() {
        #expect(FileProviderCache.localState(mode: mode_t(S_IFREG), flags: UInt32(SF_DATALESS), size: 5_000_000) == .notDownloaded)
        #expect(FileProviderCache.localState(mode: mode_t(S_IFREG), flags: 0, size: 5_000_000) == .downloaded(size: 5_000_000))
        #expect(FileProviderCache.localState(mode: mode_t(S_IFLNK), flags: 0, size: 5_000_000) == .notDownloaded)
    }

    @Test func distinguishesProtectionPermissionsUnsupportedAndUnknownErrors() {
        let cases: [(NSError, FileProviderCache.EvictionFailureReason)] = [
            (NSFileProviderError(.unsyncedEdits) as NSError, .unsyncedChanges),
            (NSFileProviderError(.nonEvictable) as NSError, .notEvictable),
            (NSError(domain: NSPOSIXErrorDomain, code: Int(EBUSY)), .inUse),
            (NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES)), .permissionDenied),
            (CocoaError(.fileWriteNoPermission) as NSError, .permissionDenied),
            (NSError(domain: NSPOSIXErrorDomain, code: Int(ENOTSUP)), .unsupported),
            (CocoaError(.featureUnsupported) as NSError, .unsupported),
            (NSError(domain: "NSFileProviderInternalErrorDomain", code: 500), .other),
            (NSError(domain: NSPOSIXErrorDomain, code: Int.max), .other),
        ]
        for (error, reason) in cases {
            let failure = FileProviderCache.classifyEvictionError(error)
            #expect(failure.reason == reason)
            #expect(failure.count == 1)
            #expect(failure.diagnostics == [.init(domain: error.domain, code: error.code)])
        }
    }

    @Test func prefersUnderlyingCauseAndOnlyRetainsSafeDiagnosticCodes() {
        let cause = NSError(domain: NSPOSIXErrorDomain, code: Int(EBUSY), userInfo: [
            NSFilePathErrorKey: "/private/synthetic/path",
            NSLocalizedDescriptionKey: "Synthetic private filename and identifier",
        ])
        let wrapper = NSError(domain: NSCocoaErrorDomain, code: CocoaError.Code.fileWriteNoPermission.rawValue, userInfo: [
            NSUnderlyingErrorKey: cause,
        ])
        let failure = FileProviderCache.classifyEvictionError(wrapper)
        #expect(failure.reason == .inUse)
        #expect(failure.diagnostics == [
            .init(domain: NSCocoaErrorDomain, code: CocoaError.Code.fileWriteNoPermission.rawValue),
            .init(domain: NSPOSIXErrorDomain, code: Int(EBUSY)),
        ])
        let unsafeDomain = NSError(domain: "/private/synthetic/path-or-item-id", code: 19)
        #expect(FileProviderCache.classifyEvictionError(unsafeDomain).diagnostics == [
            .init(domain: "OtherErrorDomain", code: 19),
        ])
    }

    @Test func visitsMultipleUnderlyingErrorsAndBoundsDeepChains() {
        let wrapper = NSError(domain: NSFileProviderErrorDomain, code: NSFileProviderError.Code.nonEvictableChildren.rawValue, userInfo: [
            NSMultipleUnderlyingErrorsKey: [
                NSFileProviderError(.unsyncedEdits) as NSError,
                NSError(domain: NSPOSIXErrorDomain, code: Int(EBUSY)),
            ],
        ])
        let failure = FileProviderCache.classifyEvictionError(wrapper)
        #expect(failure.reason == .unsyncedChanges)
        #expect(failure.diagnostics.count == 3)
        var nested = NSError(domain: NSPOSIXErrorDomain, code: Int(EBUSY))
        for code in 0..<50 {
            nested = NSError(domain: "NSFileProviderInternalErrorDomain", code: code, userInfo: [NSUnderlyingErrorKey: nested])
        }
        let bounded = FileProviderCache.classifyEvictionError(nested)
        #expect(bounded.reason == .other)
        #expect(bounded.diagnostics.count == 8)
    }

    @Test func clearAggregatesReasonsWithoutMislabelingEveryFailureAsProtected() async throws {
        let result = try await FileProviderCache.clear(
            makeEnumerator: {
                CacheTestEnumerator(pages: [[
                    CacheTestItem("asset:favorites/a", size: nil),
                    CacheTestItem("asset:favorites/b", size: nil),
                    CacheTestItem("asset:favorites/c", size: nil),
                    CacheTestItem("asset:favorites/d", size: nil),
                ]])
            },
            inspect: { _ in .downloaded(size: 10) },
            evict: { id in
                switch id.rawValue {
                case "asset:favorites/a", "asset:favorites/b": throw NSError(domain: NSPOSIXErrorDomain, code: Int(EBUSY))
                case "asset:favorites/c": throw CocoaError(.fileWriteNoPermission)
                default: break
                }
            }
        )
        #expect(result.attempted == 4)
        #expect(result.removed == 1)
        #expect(result.failed == 3)
        #expect(result.failures.map(\.reason) == [.inUse, .permissionDenied])
        #expect(result.failures.map(\.count) == [2, 1])
        #expect(result.failures.reduce(0) { $0 + $1.count } == result.failed)
        #expect(result.failures[0].diagnostics.count == 1)
    }
}

private final class CacheTestItem: NSObject, NSFileProviderItem, @unchecked Sendable {
    let itemIdentifier: NSFileProviderItemIdentifier
    let parentItemIdentifier = NSFileProviderItemIdentifier.rootContainer
    let filename = "Test item"
    let documentSize: NSNumber?
    let contentType: UTType
    let isDownloaded: Bool

    init(_ id: String, size: NSNumber?, type: UTType = .data, downloaded: Bool = true) {
        itemIdentifier = NSFileProviderItemIdentifier(id)
        documentSize = size
        contentType = type
        isDownloaded = downloaded
    }
}

private final class CacheTestItemWithoutDownloadedFlag: NSObject, NSFileProviderItem, @unchecked Sendable {
    let itemIdentifier = NSFileProviderItemIdentifier("asset:favorites/no-flag")
    let parentItemIdentifier = NSFileProviderItemIdentifier.rootContainer
    let filename = "Test item"
    let documentSize: NSNumber? = 42
}

private final class CacheTestEnumerator: NSObject, NSFileProviderEnumerator, @unchecked Sendable {
    // The observer is our synchronized implementation; its callbacks may be invoked from
    // any queue. This box only stores the reference under the fixture's mutex.
    private struct State: @unchecked Sendable {
        var invalidations = 0
        var pagesRequested: [Data] = []
        var observer: (any NSFileProviderEnumerationObserver)?
    }
    private let state = OSAllocatedUnfairLock(initialState: State())
    private let pages: [[NSFileProviderItem]]
    private let failure: Error?
    private let hangs: Bool
    private let onStart: @Sendable () -> Void

    init(pages: [[NSFileProviderItem]] = [], failure: Error? = nil, hangs: Bool = false, onStart: @escaping @Sendable () -> Void = {}) {
        self.pages = pages
        self.failure = failure
        self.hangs = hangs
        self.onStart = onStart
    }

    var invalidations: Int { state.withLock { $0.invalidations } }
    var pagesRequested: [Data] { state.withLock { $0.pagesRequested } }

    func invalidate() { state.withLock { $0.invalidations += 1 } }

    func enumerateItems(for observer: any NSFileProviderEnumerationObserver, startingAt page: NSFileProviderPage) {
        state.withLockUnchecked {
            $0.pagesRequested.append(page.rawValue)
            $0.observer = observer
        }
        onStart()
        if hangs { return }
        if let failure { observer.finishEnumeratingWithError(failure); return }
        let index = Int(String(decoding: page.rawValue, as: UTF8.self)) ?? 0
        if index < pages.count { observer.didEnumerate(pages[index]) }
        observer.finishEnumerating(upTo: index + 1 < pages.count ? NSFileProviderPage(rawValue: Data("\(index + 1)".utf8)) : nil)
    }

    func deliverLateCompletion() {
        state.withLockUnchecked { $0.observer }?.finishEnumerating(upTo: nil)
    }
}

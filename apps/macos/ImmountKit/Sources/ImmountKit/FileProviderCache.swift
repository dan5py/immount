import FileProvider
import Darwin
import Foundation
import os

/// Inspects and evicts downloaded originals through File Provider. It never deletes file
/// entries, the domain, or Immount's metadata, and does not access the server or credentials.
public enum FileProviderCache {
    public struct Usage: Equatable, Sendable {
        public let fileCount: Int
        /// Sum of known logical file sizes, not allocated disk space or guaranteed savings.
        public let totalBytes: Int64
        /// Files omitted from the byte estimate because their size is unavailable or invalid.
        public let unknownSizeCount: Int
    }

    public struct ClearResult: Equatable, Sendable {
        public let attempted: Int
        /// Successful eviction requests. The system may subsequently download these again.
        public let removed: Int
        public let failed: Int
        /// One classified reason per failed item. No item identifiers or paths are retained.
        public let failures: [EvictionFailureSummary]
        /// Nil when the post-cleanup measurement failed; it must not be presented as zero.
        public let remaining: Usage?
    }

    public enum EvictionFailureReason: String, CaseIterable, Sendable {
        case unsyncedChanges, inUse, notEvictable, permissionDenied, unsupported, other
    }

    public struct ErrorDiagnostic: Equatable, Hashable, Sendable {
        public let domain: String
        public let code: Int
    }

    public struct EvictionFailureSummary: Equatable, Sendable {
        public let reason: EvictionFailureReason
        public let count: Int
        public let diagnostics: [ErrorDiagnostic]
    }

    public enum Failure: Error, Equatable, LocalizedError {
        case timedOut
        case cannotInspect

        public var errorDescription: String? {
            switch self {
            case .timedOut: "macOS did not finish checking the downloaded files. Try again."
            case .cannotInspect: "macOS could not check the downloaded files. Try again."
            }
        }
    }

    public static func usage(manager: NSFileProviderManager) async throws -> Usage {
        let handle = ManagerHandle(manager)
        do {
            return try await usage(
                enumerator: manager.enumeratorForMaterializedItems(),
                inspect: { try await handle.inspect($0) }
            )
        } catch {
            throw publicError(error)
        }
    }

    public static func clear(manager: NSFileProviderManager) async throws -> ClearResult {
        let handle = ManagerHandle(manager)
        do {
            return try await clear(
                makeEnumerator: { handle.manager.enumeratorForMaterializedItems() },
                inspect: { try await handle.inspect($0) },
                evict: { identifier in try await handle.evict(identifier) }
            )
        } catch {
            throw publicError(error)
        }
    }

    enum LocalState: Equatable, Sendable {
        case downloaded(size: Int64?)
        case notDownloaded
    }

    static func usage(
        enumerator: any NSFileProviderEnumerator,
        inspect: @escaping @Sendable (NSFileProviderItemIdentifier) async throws -> LocalState,
        timeout: TimeInterval = 30
    ) async throws -> Usage {
        summarize(try await downloadedFiles(enumerator: enumerator, inspect: inspect, timeout: timeout))
    }

    /// Takes the File Provider calls as closures, so tests can run it without a live domain.
    static func clear(
        makeEnumerator: () -> any NSFileProviderEnumerator,
        inspect: @escaping @Sendable (NSFileProviderItemIdentifier) async throws -> LocalState,
        evict: (NSFileProviderItemIdentifier) async throws -> Void
    ) async throws -> ClearResult {
        // Finish inspecting the whole snapshot before starting any eviction. An incomplete
        // scan cannot silently clear an unknown subset and then claim an empty cache.
        let files = try await downloadedFiles(enumerator: makeEnumerator(), inspect: inspect)
        var removed = 0
        var failed = 0
        var failureCounts: [EvictionFailureReason: Int] = [:]
        var failureDiagnostics: [EvictionFailureReason: Set<ErrorDiagnostic>] = [:]
        for file in files {
            try Task.checkCancellation()
            do {
                try await evict(file.identifier)
                removed += 1
            } catch {
                try Task.checkCancellation()
                if error is CancellationError { throw error }
                failed += 1
                let failure = classifyEvictionError(error)
                failureCounts[failure.reason, default: 0] += 1
                failureDiagnostics[failure.reason, default: []].formUnion(failure.diagnostics)
                let codes = failure.diagnostics.map { "\($0.domain):\($0.code)" }.joined(separator: ", ")
                Logger(subsystem: Bundle.main.bundleIdentifier ?? "ImmountKit", category: "file-provider-cache")
                    .error("Cache eviction failed: \(failure.reason.rawValue, privacy: .public) [\(codes, privacy: .public)]")
            }
        }
        try Task.checkCancellation()
        let remaining: Usage?
        do {
            remaining = try await usage(enumerator: makeEnumerator(), inspect: inspect)
        } catch {
            try Task.checkCancellation()
            if error is CancellationError { throw error }
            remaining = nil
        }
        let failures = EvictionFailureReason.allCases.compactMap { reason -> EvictionFailureSummary? in
            guard let count = failureCounts[reason] else { return nil }
            let diagnostics = (failureDiagnostics[reason] ?? []).sorted {
                $0.domain == $1.domain ? $0.code < $1.code : $0.domain < $1.domain
            }
            return EvictionFailureSummary(reason: reason, count: count, diagnostics: diagnostics)
        }
        return ClearResult(attempted: files.count, removed: removed, failed: failed, failures: failures, remaining: remaining)
    }

    /// Underlying errors often contain the actionable cause while the outer error only
    /// reports a generic failure. Bound traversal and ignore repeated objects defensively.
    static func classifyEvictionError(_ error: Error) -> EvictionFailureSummary {
        var visited: Set<ObjectIdentifier> = []
        var diagnostics: [ErrorDiagnostic] = []
        func visit(_ error: NSError, depth: Int) -> EvictionFailureReason? {
            guard depth < 8, visited.count < 32, visited.insert(ObjectIdentifier(error)).inserted else { return nil }
            let diagnostic = ErrorDiagnostic(domain: diagnosticDomain(error.domain), code: error.code)
            if !diagnostics.contains(diagnostic) { diagnostics.append(diagnostic) }
            // Visit every child to retain safe diagnostic codes, preferring an underlying
            // classified cause over a wrapper's less specific description.
            let reasons = error.underlyingErrors.compactMap { visit($0 as NSError, depth: depth + 1) }
            return reasons.first ?? knownEvictionReason(error)
        }
        let reason = visit(error as NSError, depth: 0) ?? .other
        return EvictionFailureSummary(reason: reason, count: 1, diagnostics: diagnostics)
    }

    private static func knownEvictionReason(_ error: NSError) -> EvictionFailureReason? {
        switch error.domain {
        case NSFileProviderErrorDomain:
            switch error.code {
            case NSFileProviderError.Code.unsyncedEdits.rawValue: return .unsyncedChanges
            case NSFileProviderError.Code.nonEvictable.rawValue,
                 NSFileProviderError.Code.nonEvictableChildren.rawValue: return .notEvictable
            default: return nil
            }
        case NSPOSIXErrorDomain:
            switch error.code {
            case Int(EBUSY), Int(ETXTBSY): return .inUse
            case Int(EACCES), Int(EPERM): return .permissionDenied
            case Int(ENOTSUP), Int(EOPNOTSUPP), Int(ENOSYS): return .unsupported
            default: return nil
            }
        case NSCocoaErrorDomain:
            switch error.code {
            case CocoaError.Code.fileReadNoPermission.rawValue,
                 CocoaError.Code.fileWriteNoPermission.rawValue: return .permissionDenied
            case CocoaError.Code.featureUnsupported.rawValue,
                 CocoaError.Code.fileReadUnsupportedScheme.rawValue,
                 CocoaError.Code.fileWriteUnsupportedScheme.rawValue: return .unsupported
            default: return nil
            }
        default: return nil
        }
    }

    private static func diagnosticDomain(_ domain: String) -> String {
        // Never serialize localized descriptions or userInfo. Keep framework domain names,
        // but redact arbitrary strings that could have been used as a path or identifier.
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._-")
        guard domain.count <= 128, domain.hasPrefix("NS") || domain.hasPrefix("com.apple."),
              domain.unicodeScalars.allSatisfy({ allowed.contains($0) }) else { return "OtherErrorDomain" }
        return domain
    }

    /// Inspecting an item is an XPC round trip to fileproviderd. A few in flight hide its
    /// latency without flooding the daemon when thousands of originals are downloaded.
    static let inspectionWidth = 8

    private static func downloadedFiles(
        enumerator: any NSFileProviderEnumerator,
        inspect: @escaping @Sendable (NSFileProviderItemIdentifier) async throws -> LocalState,
        timeout: TimeInterval = 30
    ) async throws -> [CachedFile] {
        let identifiers = try await MaterializedEnumeration(enumerator: enumerator, timeout: timeout).items()
        // Results are placed by index, so eviction keeps the enumeration's stable order.
        let states = try await withThrowingTaskGroup(of: (Int, LocalState).self) { group in
            var states = [LocalState](repeating: .notDownloaded, count: identifiers.count)
            for (index, identifier) in identifiers.enumerated() {
                if index >= inspectionWidth, let (done, state) = try await group.next() {
                    states[done] = state
                }
                try Task.checkCancellation()
                group.addTask { (index, try await inspect(identifier)) }
            }
            for try await (done, state) in group {
                states[done] = state
            }
            return states
        }
        try Task.checkCancellation()
        return zip(identifiers, states).compactMap { identifier, state in
            guard case .downloaded(let size) = state else { return nil }
            return CachedFile(identifier: identifier, size: size.flatMap { $0 >= 0 ? $0 : nil })
        }
    }

    /// lstat inspects metadata without following symlinks or opening file content. Even
    /// metadata lookup can otherwise materialize intermediate directories (Apple TN3150),
    /// so disable that behavior on this thread and restore it before returning or suspending.
    static func inspectLocalFile(at url: URL) throws -> LocalState {
        guard url.isFileURL else { throw Failure.cannotInspect }
        let priorPolicy = getiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD)
        guard priorPolicy >= 0,
              setiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD, IOPOL_MATERIALIZE_DATALESS_FILES_OFF) == 0 else {
            throw Failure.cannotInspect
        }
        defer { _ = setiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD, priorPolicy) }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        var info = stat()
        let result = try url.withUnsafeFileSystemRepresentation { path in
            guard let path else { throw Failure.cannotInspect }
            return lstat(path, &info)
        }
        guard result == 0 else {
            // A concurrently removed or evicted item is no longer a downloaded candidate.
            if errno == ENOENT || errno == ENOTDIR { return .notDownloaded }
            throw Failure.cannotInspect
        }
        return localState(mode: info.st_mode, flags: info.st_flags, size: info.st_size)
    }

    static func localState(mode: mode_t, flags: UInt32, size: Int64) -> LocalState {
        guard mode & mode_t(S_IFMT) == mode_t(S_IFREG), flags & UInt32(SF_DATALESS) == 0 else {
            return .notDownloaded
        }
        return .downloaded(size: size >= 0 ? size : nil)
    }

    private static func publicError(_ error: Error) -> Error {
        if Task.isCancelled || error is CancellationError { return CancellationError() }
        // Framework errors can contain user-visible paths. Expose only a generic message.
        return error as? Failure ?? Failure.cannotInspect
    }

    private static func summarize(_ files: [CachedFile]) -> Usage {
        var bytes: Int64 = 0
        var unknown = 0
        for file in files {
            guard let size = file.size else { unknown += 1; continue }
            let sum = bytes.addingReportingOverflow(size)
            guard !sum.overflow else { unknown += 1; continue }
            bytes = sum.partialValue
        }
        return Usage(fileCount: files.count, totalBytes: bytes, unknownSizeCount: unknown)
    }
}

private struct CachedFile: Sendable {
    let identifier: NSFileProviderItemIdentifier
    let size: Int64?
}

/// Serializes the observer callbacks and completion so cancellation, errors, and a late page
/// cannot resume a continuation twice. No file content or user-visible paths are inspected.
private final class MaterializedEnumeration: NSObject, NSFileProviderEnumerationObserver, @unchecked Sendable {
    private let enumerator: any NSFileProviderEnumerator
    private let queue = DispatchQueue(label: "com.immount.cache-enumeration")
    private let timeout: TimeInterval
    private var continuation: CheckedContinuation<[NSFileProviderItemIdentifier], Error>?
    private var identifiers: Set<NSFileProviderItemIdentifier> = []
    private var completed = false
    private var timeoutWork: DispatchWorkItem?

    init(enumerator: any NSFileProviderEnumerator, timeout: TimeInterval = 30) {
        self.enumerator = enumerator
        self.timeout = timeout
    }

    func items() async throws -> [NSFileProviderItemIdentifier] {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                queue.async {
                    guard !self.completed else {
                        continuation.resume(throwing: CancellationError())
                        return
                    }
                    self.continuation = continuation
                    // Materialized enumeration requires an empty page, not a sort constant.
                    self.nextPage(NSFileProviderPage(rawValue: Data()))
                }
            }
        } onCancel: {
            self.queue.async { self.finish(.failure(CancellationError())) }
        }
    }

    func didEnumerate(_ updatedItems: [NSFileProviderItem]) {
        // System materialized enumerations may omit or default optional item fields. Only
        // the stable identifier is used here; download state and size come from scoped stat.
        let candidates = updatedItems.compactMap { item -> NSFileProviderItemIdentifier? in
            guard ItemID(rawValue: item.itemIdentifier.rawValue)?.isFolder == false else { return nil }
            return item.itemIdentifier
        }
        queue.async {
            guard !self.completed else { return }
            self.identifiers.formUnion(candidates)
        }
    }

    func finishEnumerating(upTo nextPage: NSFileProviderPage?) {
        queue.async {
            guard !self.completed else { return }
            if let nextPage {
                self.nextPage(nextPage)
            } else {
                self.finish(.success(self.identifiers.sorted { $0.rawValue < $1.rawValue }))
            }
        }
    }

    func finishEnumeratingWithError(_ error: Error) {
        queue.async { self.finish(.failure(error)) }
    }

    private func nextPage(_ page: NSFileProviderPage) {
        timeoutWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.finish(.failure(FileProviderCache.Failure.timedOut)) }
        timeoutWork = work
        queue.asyncAfter(deadline: .now() + timeout, execute: work)
        enumerator.enumerateItems(for: self, startingAt: page)
    }

    private func finish(_ result: Result<[NSFileProviderItemIdentifier], Error>) {
        guard !completed else { return }
        completed = true
        timeoutWork?.cancel()
        timeoutWork = nil
        enumerator.invalidate()
        identifiers.removeAll()
        let pending = continuation
        continuation = nil
        pending?.resume(with: result)
    }
}

/// File Provider permits calls from the host app on arbitrary queues. This handle shares only
/// the immutable framework manager reference.
private final class ManagerHandle: @unchecked Sendable {
    let manager: NSFileProviderManager

    init(_ manager: NSFileProviderManager) { self.manager = manager }

    func inspect(_ identifier: NSFileProviderItemIdentifier) async throws -> FileProviderCache.LocalState {
        try Task.checkCancellation()
        let url: URL
        do {
            // This API also marks access from the process as nonmaterializing.
            url = try await manager.getUserVisibleURL(for: identifier)
        } catch {
            try Task.checkCancellation()
            if let error = error as? NSFileProviderError, error.code == .noSuchItem { return .notDownloaded }
            if let error = error as? CocoaError, error.code == .fileReadNoSuchFile { return .notDownloaded }
            throw FileProviderCache.Failure.cannotInspect
        }
        try Task.checkCancellation()
        return try FileProviderCache.inspectLocalFile(at: url)
    }

    func evict(_ identifier: NSFileProviderItemIdentifier) async throws {
        try Task.checkCancellation()
        try await manager.evictItem(identifier: identifier)
        // macOS cannot revoke an eviction already dispatched. Keep the operation serialized
        // until its callback, then stop before submitting another item.
        try Task.checkCancellation()
    }
}

import Foundation
import os

public enum ImmichSession {
    /// The session for every Immich request. It keeps nothing on disk (requests carry the API
    /// key, responses carry library data) and refuses redirects to other hosts, which would
    /// otherwise receive the `x-api-key` header.
    public static let shared: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: configuration, delegate: RedirectGuard(), delegateQueue: nil)
    }()

    /// Same host and port, or an upgrade from http to https on the same host.
    static func isSafeRedirect(from: URL, to: URL) -> Bool {
        guard let fromHost = from.host()?.lowercased(), fromHost == to.host()?.lowercased() else { return false }
        let fromScheme = from.scheme?.lowercased()
        let toScheme = to.scheme?.lowercased()
        if fromScheme == "http", toScheme == "https" { return true }
        return fromScheme == toScheme && effectivePort(from) == effectivePort(to)
    }

    private static func effectivePort(_ url: URL) -> Int? {
        url.port ?? (url.scheme?.lowercased() == "https" ? 443 : 80)
    }
}

private final class RedirectGuard: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest
    ) async -> URLRequest? {
        // A refused redirect becomes the response, which `ImmichClient.validate` reports.
        guard let original = task.originalRequest, let from = original.url, let to = request.url,
              ImmichSession.isSafeRedirect(from: from, to: to),
              // 301/302/303 turn a POST search into a GET, which Immich answers with 404.
              request.httpMethod == original.httpMethod else { return nil }
        // A request carrying the key already sent it in plain text; make the user save the https
        // address instead of doing that on every request.
        if from.scheme?.lowercased() != to.scheme?.lowercased(), original.value(forHTTPHeaderField: "x-api-key") != nil {
            return nil
        }
        return request
    }
}

/// Mirrors a download task's progress into `progress`, restarting from zero for every attempt.
final class DownloadProgress: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let progress: Progress?
    private let measurement: DownloadMeasurement?
    // Observation tokens stay private to this lock; Foundation does not mark them Sendable.
    private let observations = OSAllocatedUnfairLock<[NSKeyValueObservation]>(uncheckedState: [])

    init(_ progress: Progress?, measurement: DownloadMeasurement? = nil) {
        self.progress = progress
        self.measurement = measurement
        progress?.completedUnitCount = 0
    }

    func urlSession(_ session: URLSession, didCreateTask task: URLSessionTask) {
        if let progress {
            let total = progress.totalUnitCount
            let observer = task.progress.observe(\.fractionCompleted) { taskProgress, _ in
                progress.completedUnitCount = Int64(taskProgress.fractionCompleted * Double(total))
            }
            observations.withLockUnchecked { $0.append(observer) }
        }
        if let measurement {
            // Actual received bytes also work when the server omits Content-Length.
            let observer = task.observe(\.countOfBytesReceived, options: [.initial, .new]) { task, _ in
                measurement.receive(task.countOfBytesReceived)
            }
            observations.withLockUnchecked { $0.append(observer) }
        }
    }

    deinit {
        observations.withLock { $0.forEach { $0.invalidate() } }
    }
}

/// Remembers for a short while whether an address answered, so requests skip a local address
/// that is down instead of waiting for each one to time out.
final class Reachability: Sendable {
    static let shared = Reachability()
    static let lifetime: TimeInterval = 30
    private let state = OSAllocatedUnfairLock<[URL: (reachable: Bool, date: Date)]>(initialState: [:])

    func cached(_ base: URL) -> Bool? {
        state.withLock { state in
            guard let entry = state[base], Date.now.timeIntervalSince(entry.date) < Self.lifetime else { return nil }
            return entry.reachable
        }
    }

    func record(_ base: URL, reachable: Bool) {
        state.withLock { $0[base] = (reachable, .now) }
    }
}

/// Shares one in-flight or recent fetch between concurrent callers.
final class Memo<Value: Sendable>: Sendable {
    private let state = OSAllocatedUnfairLock<(task: Task<Value, Error>, date: Date)?>(initialState: nil)
    private let lifetime: TimeInterval

    init(lifetime: TimeInterval = .infinity) {
        self.lifetime = lifetime
    }

    func value(_ fetch: @escaping @Sendable () async throws -> Value) async throws -> Value {
        let task = state.withLock { state in
            if let state, Date.now.timeIntervalSince(state.date) < lifetime { return state.task }
            let task = Task { try await fetch() }
            state = (task, .now)
            return task
        }
        do {
            return try await task.value
        } catch {
            // Do not keep a failure around; the next caller tries again.
            state.withLock { if $0?.task == task { $0 = nil } }
            throw error
        }
    }

    func store(_ value: Value) {
        state.withLock { $0 = (Task { value }, .now) }
    }

    func reset() {
        state.withLock { $0 = nil }
    }
}

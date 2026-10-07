import Foundation
import ImmountKit
import Observation

/// A pane's lifetime, including the address so a route change discards old measurements.
struct StatisticsContext: Hashable {
    var profileID: String?
    var serverURL: URL?
    var isConnected: Bool
}

struct SpeedSample: Identifiable {
    let id = UUID()
    let date: Date
    let bytesPerSecond: Double
}

/// Polls only while Statistics is enabled and visible. Finder records downloads independently
/// of the window and app icons while the shared statistics preference is enabled.
@MainActor
@Observable
final class StatisticsModel {
    private(set) var downloads = DownloadStatistics.empty
    private(set) var history: [SpeedSample] = []
    private(set) var response: ServerResponseSample?
    private(set) var responseError: String?
    private(set) var library: ImmichLibraryStatistics?
    private(set) var libraryError: String?
    private(set) var storage: ImmichServerStorage?
    private(set) var storageError: String?
    private(set) var updatedAt: Date?
    private(set) var isRefreshing = false

    @ObservationIgnored private let provider = ConnectionProvider()
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var context: StatisticsContext?
    @ObservationIgnored private var monitorTask: Task<Void, Never>?
    @ObservationIgnored private var refreshTask: Task<Void, Never>?

    /// Also cancels manual refreshes, which are launched independently of the pane's task.
    /// Invalidate first so an older request cannot publish results or clear a newer request.
    func stop() {
        generation = UUID()
        context = nil
        monitorTask?.cancel()
        monitorTask = nil
        refreshTask?.cancel()
        refreshTask = nil
        downloads = .empty
        history = []
        response = nil
        responseError = nil
        library = nil
        libraryError = nil
        storage = nil
        storageError = nil
        updatedAt = nil
        isRefreshing = false
    }

    func monitor(_ context: StatisticsContext) async {
        // A cancelled SwiftUI task can start after its replacement. It must not stop that run.
        guard !Task.isCancelled else { return }
        stop()
        guard SettingsStore.shared.statisticsEnabled else { return }
        let run = generation
        self.context = context
        guard context.isConnected, let profileID = context.profileID else { return }
        let task = Task { await monitorDownloads(profileID: profileID, run: run) }
        monitorTask = task
        await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
            // Stop a manual refresh too, even while a background file read is finishing.
            Task { @MainActor in
                if self.generation == run { self.stop() }
            }
        }
        if generation == run { stop() }
    }

    private func monitorDownloads(profileID: String, run: UUID) async {
        let store = DownloadStatisticsStore.forProfile(profileID)

        await withTaskGroup(of: Void.self) { group in
            group.addTask { await self.pollServer(run: run) }
            while !Task.isCancelled, generation == run, SettingsStore.shared.statisticsEnabled {
                // File access stays off the UI actor, including waiting for a writer's lock.
                let snapshot = await Task.detached(priority: .utility) { store.snapshot() }.value
                guard !Task.isCancelled, generation == run, SettingsStore.shared.statisticsEnabled else { break }
                downloads = snapshot
                let now = Date.now
                history.append(SpeedSample(date: now, bytesPerSecond: snapshot.bytesPerSecond))
                history.removeAll { now.timeIntervalSince($0.date) > 60 }
                do { try await Task.sleep(for: .seconds(1)) } catch { break }
            }
            group.cancelAll()
        }
    }

    private func pollServer(run: UUID) async {
        while !Task.isCancelled, generation == run, SettingsStore.shared.statisticsEnabled {
            await refresh()
            guard !Task.isCancelled, generation == run, SettingsStore.shared.statisticsEnabled else { return }
            do { try await Task.sleep(for: .seconds(30)) } catch { return }
        }
    }

    func refresh() async {
        guard !Task.isCancelled, SettingsStore.shared.statisticsEnabled, refreshTask == nil,
              let context, context.isConnected, let profileID = context.profileID else { return }
        let run = generation
        let task = Task { await fetchServer(profileID: profileID, run: run) }
        refreshTask = task
        isRefreshing = true
        await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
        if generation == run, refreshTask == task {
            refreshTask = nil
            isRefreshing = false
        }
    }

    private func fetchServer(profileID: String, run: UUID) async {
        guard !Task.isCancelled, generation == run, SettingsStore.shared.statisticsEnabled else { return }
        do {
            let connection = try provider.connection(domainID: profileID)
            async let measured = Self.capture { try await connection.client.measureResponseTime() }
            async let counted = Self.capture { try await connection.client.libraryStatistics() }
            async let disk = Self.capture { try await connection.client.serverStorage() }
            let (pingResult, libraryResult, storageResult) = await (measured, counted, disk)
            guard generation == run, !Task.isCancelled, SettingsStore.shared.statisticsEnabled else { return }
            switch pingResult {
            case .success(let sample): response = sample; responseError = nil
            case .failure(let error): response = nil; responseError = Self.message(error)
            }
            switch libraryResult {
            case .success(let counts): library = counts; libraryError = nil
            case .failure(let error): library = nil; libraryError = Self.message(error, permission: "asset.statistics")
            }
            switch storageResult {
            case .success(let disk): storage = disk; storageError = nil
            case .failure(let error): storage = nil; storageError = Self.message(error, permission: "server.storage")
            }
            updatedAt = .now
        } catch {
            guard generation == run, !Task.isCancelled, SettingsStore.shared.statisticsEnabled else { return }
            response = nil
            library = nil
            storage = nil
            responseError = Self.message(error)
            libraryError = responseError
            storageError = responseError
        }
    }

    private static func capture<T: Sendable>(_ operation: @Sendable () async throws -> T) async -> Result<T, Error> {
        do { return .success(try await operation()) } catch { return .failure(error) }
    }

    private static func message(_ error: Error, permission: String? = nil) -> String {
        switch error {
        case ImmichError.missingPermission:
            if let permission { return "To show this, enable \(permission) on your Immich API key." }
            return "The API key does not have permission to read this statistic."
        case ImmichError.notFound, ImmichError.http(status: 404, message: _):
            return "This Immich version does not provide this statistic."
        case ConnectionProvider.Failure.keyMissing, ConnectionProvider.Failure.keychainUnavailable:
            return "The API key is unavailable. Check the connection in General."
        case ConnectionProvider.Failure.disconnected, ConnectionProvider.Failure.notConfigured:
            return "Connect to your server in General to see statistics."
        default:
            return AppModel.describe(error)
        }
    }
}

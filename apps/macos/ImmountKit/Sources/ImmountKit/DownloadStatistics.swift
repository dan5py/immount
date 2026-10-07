import Darwin
import Foundation
import os

/// Measurements of original files downloaded by Immount, scoped to one server profile.
/// Totals include only downloads that were validated and saved successfully.
public struct DownloadStatistics: Sendable, Equatable {
    public var activeDownloads: Int = 0
    public var bytesPerSecond: Double = 0
    public var downloadedBytes: Int64 = 0
    public var completedDownloads: Int64 = 0
    public var lastDownloadBytesPerSecond: Double?
    public var lastDownloadAt: Date?

    public static let empty = DownloadStatistics()
}

/// Small, best-effort telemetry shared by the app and File Provider. A separate advisory
/// lock protects read/modify/write across processes; replacing the JSON atomically keeps
/// a terminated writer from leaving a partial file. No asset IDs or addresses are stored.
public final class DownloadStatisticsStore: Sendable {
    static let staleInterval: TimeInterval = 30
    static let speedWindow: TimeInterval = 3
    static let maximumActiveDownloads = 256

    private struct Transfer: Codable, Equatable {
        var processID: Int32
        var startedAt: Date
        var updatedAt: Date
        var bytes: Int64 = 0
    }

    /// Quarter-second buckets bound the speed history to at most 16 entries, even when
    /// many tiny originals finish between the app's refreshes.
    private struct Sample: Codable, Equatable {
        var date: Date
        var bytes: Int64

        var bucket: Int64 { Int64(floor(date.timeIntervalSince1970 * 4)) }
    }

    private struct State: Codable, Equatable {
        var downloadedBytes: Int64 = 0
        var completedDownloads: Int64 = 0
        var lastDownloadBytesPerSecond: Double?
        var lastDownloadAt: Date?
        var active: [String: Transfer] = [:]
        var samples: [Sample] = []
        var measuredSince: Date?
        var collectionGeneration: String?
    }

    private let directory: URL
    private let settings: SettingsStore?

    /// An explicit directory makes tests independent of app-group entitlements and data.
    public init(directory: URL, settings: SettingsStore? = nil) {
        self.directory = directory
        self.settings = settings
    }

    public static func forProfile(_ profileID: String, settings: SettingsStore = .shared) -> DownloadStatisticsStore {
        DownloadStatisticsStore(directory: SharedContainer.stateDirectory(for: profileID)
            .appending(path: "Downloads", directoryHint: .isDirectory), settings: settings)
    }

    private var collection: SettingsStore.StatisticsCollection { settings?.statisticsCollection ?? .initial }

    private func isRecording(_ transfer: DownloadTransfer) -> Bool {
        let collection = collection
        return collection.enabled && collection.generation == transfer.collectionGeneration
    }

    public func snapshot() -> DownloadStatistics {
        snapshot(at: .now)
    }

    func snapshot(at date: Date) -> DownloadStatistics {
        withState(at: date, fallback: .empty) { state in
            let elapsed = min(Self.speedWindow, max(0.001, date.timeIntervalSince(state.measuredSince ?? date)))
            return DownloadStatistics(
                activeDownloads: state.active.count,
                bytesPerSecond: state.samples.reduce(0) { $0 + Double($1.bytes) } / elapsed,
                downloadedBytes: state.downloadedBytes,
                completedDownloads: state.completedDownloads,
                lastDownloadBytesPerSecond: state.lastDownloadBytesPerSecond,
                lastDownloadAt: state.lastDownloadAt
            )
        }
    }

    func begin(at date: Date = .now) -> DownloadTransfer? {
        withState(at: date, fallback: nil) { state in
            guard state.active.count < Self.maximumActiveDownloads else { return nil }
            let transfer = DownloadTransfer(startedAt: date, collectionGeneration: state.collectionGeneration!)
            state.active[transfer.id.uuidString] = Transfer(processID: getpid(), startedAt: date, updatedAt: date)
            state.measuredSince = state.measuredSince ?? date
            return transfer
        }
    }

    /// Called at most once per second by a transfer's heartbeat, even if no bytes arrive.
    /// Keeping heartbeats separate from progress avoids marking a slow request as crashed.
    @discardableResult
    func record(_ transfer: DownloadTransfer, receivedBytes: Int64, at date: Date = .now) -> Bool {
        if isRecording(transfer), !transfer.state.withLock({ $0.finished }) {
            withState(at: date, fallback: ()) { state in
                guard state.collectionGeneration == transfer.collectionGeneration else { return }
                // The watermark moves only while the file lock is held. A completion that waits
                // for this heartbeat then sees the bytes it sampled, and a heartbeat that waited
                // for a completion finds the transfer finished and cannot restore its record.
                let progress = transfer.state.withLock { local -> (bytes: Int64, new: Int64)? in
                    guard !local.finished, date > local.lastRecordedAt else { return nil }
                    let bytes = max(local.recordedBytes, receivedBytes)
                    let new = bytes - local.recordedBytes
                    local.recordedBytes = bytes
                    local.lastRecordedAt = date
                    return (bytes, new)
                }
                guard let progress else { return }
                Self.sample(progress.new, at: date, in: &state)
                // A heartbeat after Mac sleep can restore a record that a reader expired.
                if state.active[transfer.id.uuidString] != nil || state.active.count < Self.maximumActiveDownloads {
                    state.active[transfer.id.uuidString] = Transfer(processID: getpid(), startedAt: transfer.startedAt,
                                                                   updatedAt: date, bytes: progress.bytes)
                }
            }
        }
        let continues = isRecording(transfer)
        return transfer.state.withLock { local in
            if !continues { local.finished = true }
            return !local.finished
        }
    }

    /// A nil byte count means failure or cancellation: remove the active transfer without
    /// counting it. Local completion state prevents duplicates even if shared liveness
    /// records were pruned while the Mac slept or this process was suspended.
    func finish(_ transfer: DownloadTransfer, downloadedBytes: Int64?, at date: Date = .now) {
        let alreadyFinished = transfer.state.withLock { local in
            let wasFinished = local.finished
            local.finished = true
            return wasFinished
        }
        guard !alreadyFinished, isRecording(transfer) else { return }
        withState(at: date, fallback: ()) { state in
            guard state.collectionGeneration == transfer.collectionGeneration else { return }
            state.active.removeValue(forKey: transfer.id.uuidString)
            guard let bytes = downloadedBytes, bytes >= 0 else { return }
            let recordedBytes = transfer.state.withLock { $0.recordedBytes }
            Self.sample(max(0, bytes - recordedBytes), at: date, in: &state)
            state.downloadedBytes = Self.saturatedAdd(state.downloadedBytes, bytes)
            state.completedDownloads = Self.saturatedAdd(state.completedDownloads, 1)
            // Wall-clock corrections must never produce a negative or infinite speed.
            let elapsed = date.timeIntervalSince(transfer.startedAt)
            state.lastDownloadBytesPerSecond = elapsed > 0 ? Double(bytes) / elapsed : nil
            state.lastDownloadAt = date
        }
    }

    private static func sample(_ bytes: Int64, at date: Date, in state: inout State) {
        guard bytes > 0 else { return }
        let sample = Sample(date: date, bytes: bytes)
        if let index = state.samples.firstIndex(where: { $0.bucket == sample.bucket }) {
            state.samples[index].bytes = saturatedAdd(state.samples[index].bytes, bytes)
            state.samples[index].date = max(state.samples[index].date, date)
        } else {
            state.samples.append(sample)
        }
        // A small extra allowance covers writers whose timestamps arrive out of order.
        if state.samples.count > 16 {
            state.samples.sort { $0.date < $1.date }
            state.samples.removeFirst(state.samples.count - 16)
        }
    }

    private static func saturatedAdd(_ lhs: Int64, _ rhs: Int64) -> Int64 {
        let (value, overflow) = lhs.addingReportingOverflow(rhs)
        return overflow ? .max : value
    }

    private func withState<Result>(at date: Date, fallback: Result, _ body: (inout State) -> Result) -> Result {
        // In particular, beginning a download while collection is off must not create
        // a telemetry directory, acquire its lock, write a file or start a heartbeat.
        guard collection.enabled else { return fallback }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            // Never lock the data file itself: atomic replacement changes its inode. Every call
            // opens its own descriptor, so threads in this process also take turns.
            let descriptor = open(directory.appending(path: "statistics.lock").path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
            guard descriptor >= 0 else { return fallback }
            defer { close(descriptor) }
            guard flock(descriptor, LOCK_EX) == 0 else { return fallback }
            defer { flock(descriptor, LOCK_UN) }

            let collection = collection
            guard collection.enabled else { return fallback }

            let url = directory.appending(path: "statistics.json")
            var state = (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode(State.self, from: $0) } ?? State()
            let before = state
            if state.collectionGeneration != collection.generation {
                // Only live activity belongs to a collection session. Historical totals
                // remain intact while old in-flight attempts can never rejoin a new one.
                state.active.removeAll()
                state.samples.removeAll()
                state.measuredSince = nil
                state.collectionGeneration = collection.generation
            }
            state.samples.removeAll {
                let age = date.timeIntervalSince($0.date)
                return age >= Self.speedWindow || age < -Self.staleInterval
            }
            state.active = state.active.filter { _, transfer in
                let age = date.timeIntervalSince(transfer.updatedAt)
                guard age < Self.staleInterval, age >= -Self.staleInterval, transfer.processID > 0 else { return false }
                // ESRCH proves the writer exited; EPERM may just mean another sandbox.
                return kill(transfer.processID, 0) == 0 || errno != ESRCH
            }
            let result = body(&state)
            // A preference change while waiting for I/O invalidates the entire mutation.
            guard self.collection == collection else { return fallback }
            if state != before {
                try JSONEncoder().encode(state).write(to: url, options: .atomic)
            }
            return result
        } catch {
            // Statistics must never prevent Finder from downloading an original.
            return fallback
        }
    }
}

/// A live download retains just enough local state to finish after its shared heartbeat
/// expires. Its byte watermark prevents resuming from counting already sampled bytes.
final class DownloadTransfer: Sendable {
    struct State {
        var recordedBytes: Int64 = 0
        var lastRecordedAt: Date
        var finished = false
    }

    let id = UUID()
    let startedAt: Date
    let collectionGeneration: String
    let state: OSAllocatedUnfairLock<State>

    init(startedAt: Date, collectionGeneration: String) {
        self.startedAt = startedAt
        self.collectionGeneration = collectionGeneration
        state = OSAllocatedUnfairLock(initialState: State(lastRecordedAt: startedAt))
    }
}

/// Progress callbacks only update memory. A one-second heartbeat bounds shared-container
/// writes and refreshes liveness during quiet requests; finishing always flushes totals.
final class DownloadMeasurement: Sendable {
    private struct State {
        var receivedBytes: Int64 = 0
        var finished = false
    }

    private let store: DownloadStatisticsStore
    private let transfer: DownloadTransfer
    private let state = OSAllocatedUnfairLock(initialState: State())
    private let timer: any DispatchSourceTimer

    init?(store: DownloadStatisticsStore) {
        guard let transfer = store.begin() else { return nil }
        self.store = store
        self.transfer = transfer
        timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: .now() + 1, repeating: 1, leeway: .milliseconds(100))
        timer.setEventHandler { [weak self] in self?.sample() }
        timer.resume()
    }

    func receive(_ bytes: Int64) {
        state.withLock { state in
            guard !state.finished else { return }
            state.receivedBytes = max(state.receivedBytes, bytes)
        }
    }

    // The store may wait for another process's file lock, so it is always called after
    // releasing `state`: progress callbacks on the session's delegate queue never wait for I/O.
    func sample() {
        guard let receivedBytes = state.withLock({ $0.finished ? nil : $0.receivedBytes }),
              !store.record(transfer, receivedBytes: receivedBytes) else { return }
        state.withLock { $0.finished = true }
        timer.cancel()
    }

    func finish(success: Bool, bytes: Int64? = nil) {
        let receivedBytes = state.withLock { state -> Int64? in
            guard !state.finished else { return nil }
            state.finished = true
            return state.receivedBytes
        }
        guard let receivedBytes else { return }
        timer.cancel()
        store.finish(transfer, downloadedBytes: success ? max(0, bytes ?? receivedBytes) : nil)
    }

    deinit {
        timer.cancel()
        store.finish(transfer, downloadedBytes: nil)
    }
}

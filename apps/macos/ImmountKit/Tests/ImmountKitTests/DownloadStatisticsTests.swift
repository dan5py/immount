import Foundation
import os
import Testing
@testable import ImmountKit

@Suite struct DownloadStatisticsTests {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appending(path: "immount-download-tests-\(UUID().uuidString)")
    }

    @Test func statisticsPreferenceDefaultsOnAndChangesGenerationOnlyWhenToggled() throws {
        let suite = "immount-statistics-preferences-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = SettingsStore(defaults: defaults)
        let initial = settings.statisticsCollection
        #expect(settings.statisticsEnabled)
        settings.statisticsEnabled = true
        #expect(settings.statisticsCollection == initial)
        settings.statisticsEnabled = false
        let disabled = settings.statisticsCollection
        #expect(!disabled.enabled)
        #expect(disabled.generation != initial.generation)
        settings.statisticsEnabled = false
        #expect(settings.statisticsCollection == disabled)
        settings.statisticsEnabled = true
        #expect(settings.statisticsCollection.generation != disabled.generation)
        #expect(settings.statisticsCollection.generation != initial.generation)
        let reopened = SettingsStore(defaults: try #require(UserDefaults(suiteName: suite)))
        #expect(reopened.statisticsCollection == settings.statisticsCollection)
    }

    @Test func disabledStatisticsDoNotCreateStorageOrMeasurements() throws {
        let suite = "immount-statistics-preferences-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = SettingsStore(defaults: defaults)
        settings.statisticsEnabled = false
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = DownloadStatisticsStore(directory: directory, settings: settings)
        #expect(store.begin(at: start) == nil)
        #expect(DownloadMeasurement(store: store) == nil)
        #expect(store.snapshot(at: start) == .empty)
        #expect(!FileManager.default.fileExists(atPath: directory.path))
        settings.statisticsEnabled = true
        #expect(store.begin(at: start) != nil)
    }

    @Test func disablingStopsWritesAndReenablingKeepsTotalsWithoutOldLiveActivity() throws {
        let suite = "immount-statistics-preferences-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = SettingsStore(defaults: defaults)
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = DownloadStatisticsStore(directory: directory, settings: settings)
        let completed = try #require(store.begin(at: start))
        store.finish(completed, downloadedBytes: 1_000, at: start.addingTimeInterval(1))
        let active = try #require(store.begin(at: start.addingTimeInterval(2)))
        store.record(active, receivedBytes: 500, at: start.addingTimeInterval(3))
        let before = try Data(contentsOf: directory.appending(path: "statistics.json"))

        settings.statisticsEnabled = false
        #expect(!store.record(active, receivedBytes: 1_000, at: start.addingTimeInterval(4)))
        store.finish(active, downloadedBytes: 2_000, at: start.addingTimeInterval(5))
        #expect(store.snapshot(at: start.addingTimeInterval(5)) == .empty)
        #expect(try Data(contentsOf: directory.appending(path: "statistics.json")) == before)

        settings.statisticsEnabled = true
        let retained = store.snapshot(at: start.addingTimeInterval(6))
        #expect(retained.activeDownloads == 0)
        #expect(retained.bytesPerSecond == 0)
        #expect(retained.downloadedBytes == 1_000)
        #expect(retained.completedDownloads == 1)
        #expect(retained.lastDownloadAt == start.addingTimeInterval(1))
        let next = try #require(store.begin(at: start.addingTimeInterval(6)))
        store.finish(next, downloadedBytes: 700, at: start.addingTimeInterval(7))
        #expect(store.snapshot(at: start.addingTimeInterval(7)).downloadedBytes == 1_700)
        #expect(store.snapshot(at: start.addingTimeInterval(7)).completedDownloads == 2)
    }

    @Test func quickOffOnInvalidatesPreviouslyStartedDownloads() throws {
        let suite = "immount-statistics-preferences-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = SettingsStore(defaults: defaults)
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = DownloadStatisticsStore(directory: directory, settings: settings)
        let heartbeat = try #require(store.begin(at: start))
        let completion = try #require(store.begin(at: start))
        store.record(heartbeat, receivedBytes: 100, at: start.addingTimeInterval(1))
        settings.statisticsEnabled = false
        settings.statisticsEnabled = true
        // Neither old handle observed the disabled state; the generation still rejects both.
        #expect(!store.record(heartbeat, receivedBytes: 300, at: start.addingTimeInterval(2)))
        store.finish(completion, downloadedBytes: 500, at: start.addingTimeInterval(2))
        #expect(store.snapshot(at: start.addingTimeInterval(2)) == .empty)
        let fresh = try #require(store.begin(at: start.addingTimeInterval(2)))
        store.finish(fresh, downloadedBytes: 600, at: start.addingTimeInterval(3))
        #expect(store.snapshot(at: start.addingTimeInterval(3)).downloadedBytes == 600)
        #expect(store.snapshot(at: start.addingTimeInterval(3)).completedDownloads == 1)
    }

    @Test func anExistingClientFollowsStatisticsPreferencesWithoutRecreation() async throws {
        let suite = "immount-statistics-preferences-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = SettingsStore(defaults: defaults)
        settings.statisticsEnabled = false
        let directory = temporaryDirectory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let telemetryDirectory = directory.appending(path: "statistics")
        let store = DownloadStatisticsStore(directory: telemetryDirectory, settings: settings)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StatisticsDownloadProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let client = ImmichClient(apiKey: "test-key", session: session,
                                  versionCache: ImmichClient.makeVersionCache(), downloadStatistics: store) {
            [URL(string: "https://download-test.invalid")!]
        }

        try await client.downloadOriginal(assetID: "success", to: directory.appending(path: "disabled"))
        #expect(!FileManager.default.fileExists(atPath: telemetryDirectory.path))
        settings.statisticsEnabled = true
        try await client.downloadOriginal(assetID: "success", to: directory.appending(path: "enabled"))
        #expect(store.snapshot().completedDownloads == 1)
        #expect(store.snapshot().downloadedBytes == 1_234)
        settings.statisticsEnabled = false
        let stored = try Data(contentsOf: telemetryDirectory.appending(path: "statistics.json"))
        try await client.downloadOriginal(assetID: "success", to: directory.appending(path: "disabled-again"))
        #expect(try Data(contentsOf: telemetryDirectory.appending(path: "statistics.json")) == stored)
        settings.statisticsEnabled = true
        #expect(store.snapshot().completedDownloads == 1)
        #expect(store.snapshot().downloadedBytes == 1_234)
        #expect(store.snapshot().activeDownloads == 0)
        #expect(store.snapshot().bytesPerSecond == 0)
    }

    @Test func measuresConcurrentSpeedsAndPersistsCompletedTotals() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let writer = DownloadStatisticsStore(directory: directory)
        let reader = DownloadStatisticsStore(directory: directory)
        let first = try #require(writer.begin(at: start))
        let second = try #require(writer.begin(at: start))
        writer.record(first, receivedBytes: 2_000, at: start.addingTimeInterval(2))
        writer.record(second, receivedBytes: 4_000, at: start.addingTimeInterval(2))

        let active = reader.snapshot(at: start.addingTimeInterval(2))
        #expect(active.activeDownloads == 2)
        #expect(active.bytesPerSecond == 3_000)
        #expect(active.downloadedBytes == 0)
        #expect(active.completedDownloads == 0)

        writer.finish(first, downloadedBytes: 4_000, at: start.addingTimeInterval(4))
        writer.finish(second, downloadedBytes: 8_000, at: start.addingTimeInterval(8))
        let completed = reader.snapshot(at: start.addingTimeInterval(8))
        #expect(completed.activeDownloads == 0)
        #expect(completed.bytesPerSecond == 4_000.0 / 3)
        #expect(reader.snapshot(at: start.addingTimeInterval(11)).bytesPerSecond == 0)
        #expect(completed.downloadedBytes == 12_000)
        #expect(completed.completedDownloads == 2)
        #expect(completed.lastDownloadBytesPerSecond == 1_000)
        #expect(completed.lastDownloadAt == start.addingTimeInterval(8))
    }

    @Test func failedAndCancelledAttemptsDoNotCountAsDownloads() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = DownloadStatisticsStore(directory: directory)
        let failed = try #require(store.begin(at: start))
        store.record(failed, receivedBytes: 500, at: start.addingTimeInterval(1))
        store.finish(failed, downloadedBytes: nil, at: start.addingTimeInterval(2))
        let cancelled = try #require(store.begin(at: start.addingTimeInterval(2)))
        store.finish(cancelled, downloadedBytes: nil, at: start.addingTimeInterval(3))
        #expect(store.snapshot(at: start.addingTimeInterval(3)).activeDownloads == 0)
        #expect(store.snapshot(at: start.addingTimeInterval(3)).completedDownloads == 0)
        #expect(store.snapshot(at: start.addingTimeInterval(3)).downloadedBytes == 0)
        #expect(store.snapshot(at: start.addingTimeInterval(4)) == .empty)

        let successful = try #require(store.begin(at: start.addingTimeInterval(4)))
        store.finish(successful, downloadedBytes: 1_000, at: start.addingTimeInterval(5))
        // A deferred failure handler or a duplicated callback cannot overwrite success.
        store.finish(successful, downloadedBytes: nil, at: start.addingTimeInterval(6))
        store.finish(successful, downloadedBytes: 1_000, at: start.addingTimeInterval(6))
        #expect(store.snapshot(at: start.addingTimeInterval(6)).completedDownloads == 1)
        #expect(store.snapshot(at: start.addingTimeInterval(6)).downloadedBytes == 1_000)
    }

    @Test func heartbeatsKeepWaitingDownloadsActiveWhileRecentSpeedDecays() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = DownloadStatisticsStore(directory: directory)
        let transfer = try #require(store.begin(at: start))
        store.record(transfer, receivedBytes: 2_000, at: start.addingTimeInterval(2))
        #expect(store.snapshot(at: start.addingTimeInterval(2)).bytesPerSecond == 1_000)
        store.record(transfer, receivedBytes: 2_000, at: start.addingTimeInterval(3))
        #expect(store.snapshot(at: start.addingTimeInterval(3)).bytesPerSecond == 2_000.0 / 3)
        #expect(store.snapshot(at: start.addingTimeInterval(6)).bytesPerSecond == 0)
        store.record(transfer, receivedBytes: 2_000, at: start.addingTimeInterval(25))
        #expect(store.snapshot(at: start.addingTimeInterval(40)).activeDownloads == 1)
        // A crashed or abandoned transfer stops heartbeating and is removed permanently.
        #expect(store.snapshot(at: start.addingTimeInterval(60)).activeDownloads == 0)
        #expect(DownloadStatisticsStore(directory: directory).snapshot(at: start.addingTimeInterval(60)) == .empty)
    }

    @Test func staleSpeedIsNotShownWhileWaitingForTheNextHeartbeat() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = DownloadStatisticsStore(directory: directory)
        let transfer = try #require(store.begin(at: start))
        store.record(transfer, receivedBytes: 1_000, at: start.addingTimeInterval(1))
        let snapshot = store.snapshot(at: start.addingTimeInterval(5))
        #expect(snapshot.activeDownloads == 1)
        #expect(snapshot.bytesPerSecond == 0)
        // Regressing counters and timestamps cannot create negative rates.
        store.record(transfer, receivedBytes: 500, at: start.addingTimeInterval(6))
        store.record(transfer, receivedBytes: 2_000, at: start.addingTimeInterval(5))
        #expect(store.snapshot(at: start.addingTimeInterval(6)).bytesPerSecond == 0)
    }

    @Test func fastDownloadsAppearInRollingSpeedAndFinalBytesAreNotCountedTwice() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = DownloadStatisticsStore(directory: directory)
        for index in 0..<3 {
            let begun = start.addingTimeInterval(Double(index) / 10)
            let transfer = try #require(store.begin(at: begun))
            // Complete before a one-second heartbeat can sample anything.
            store.finish(transfer, downloadedBytes: 1_000, at: begun.addingTimeInterval(0.05))
        }
        let burst = store.snapshot(at: start.addingTimeInterval(1))
        #expect(burst.activeDownloads == 0)
        #expect(burst.bytesPerSecond == 3_000)
        #expect(burst.completedDownloads == 3)

        let longer = try #require(store.begin(at: start.addingTimeInterval(1)))
        store.record(longer, receivedBytes: 1_000, at: start.addingTimeInterval(1.2))
        store.finish(longer, downloadedBytes: 2_000, at: start.addingTimeInterval(1.3))
        let completed = store.snapshot(at: start.addingTimeInterval(2))
        #expect(completed.downloadedBytes == 5_000)
        #expect(completed.bytesPerSecond == 2_500)
        #expect(store.snapshot(at: start.addingTimeInterval(4.4)).bytesPerSecond == 0)
    }

    @Test func suspendedTransfersResumeAndCompleteAfterStaleRecordsAreRemoved() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = DownloadStatisticsStore(directory: directory)
        let reader = DownloadStatisticsStore(directory: directory)
        let transfer = try #require(store.begin(at: start))
        store.record(transfer, receivedBytes: 1_000, at: start.addingTimeInterval(1))
        #expect(reader.snapshot(at: start.addingTimeInterval(32)).activeDownloads == 0)
        store.record(transfer, receivedBytes: 1_500, at: start.addingTimeInterval(33))
        #expect(reader.snapshot(at: start.addingTimeInterval(33)).activeDownloads == 1)
        #expect(reader.snapshot(at: start.addingTimeInterval(33)).bytesPerSecond == 500.0 / 3)
        store.finish(transfer, downloadedBytes: 2_000, at: start.addingTimeInterval(34))
        store.finish(transfer, downloadedBytes: 2_000, at: start.addingTimeInterval(34))
        #expect(reader.snapshot(at: start.addingTimeInterval(34)).downloadedBytes == 2_000)
        #expect(reader.snapshot(at: start.addingTimeInterval(34)).completedDownloads == 1)
        #expect(reader.snapshot(at: start.addingTimeInterval(34)).bytesPerSecond == 1_000.0 / 3)

        // Completion may arrive before the next heartbeat after waking the Mac.
        let finishesFirst = try #require(store.begin(at: start.addingTimeInterval(35)))
        store.record(finishesFirst, receivedBytes: 100, at: start.addingTimeInterval(36))
        #expect(reader.snapshot(at: start.addingTimeInterval(67)).activeDownloads == 0)
        store.finish(finishesFirst, downloadedBytes: 500, at: start.addingTimeInterval(68))
        #expect(reader.snapshot(at: start.addingTimeInterval(68)).downloadedBytes == 2_500)
        #expect(reader.snapshot(at: start.addingTimeInterval(68)).completedDownloads == 2)
        #expect(reader.snapshot(at: start.addingTimeInterval(68)).bytesPerSecond == 400.0 / 3)
    }

    @Test func independentWritersDoNotLoseConcurrentCompletions() {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        DispatchQueue.concurrentPerform(iterations: 40) { _ in
            let store = DownloadStatisticsStore(directory: directory)
            guard let transfer = store.begin(at: start) else {
                Issue.record("Could not start a telemetry record")
                return
            }
            store.record(transfer, receivedBytes: 500, at: start.addingTimeInterval(1))
            store.finish(transfer, downloadedBytes: 1_000, at: start.addingTimeInterval(2))
        }
        let snapshot = DownloadStatisticsStore(directory: directory).snapshot(at: start.addingTimeInterval(2))
        #expect(snapshot.completedDownloads == 40)
        #expect(snapshot.downloadedBytes == 40_000)
        #expect(snapshot.activeDownloads == 0)
    }

    @Test func heartbeatsRacingCompletionsNeitherRestoreRecordsNorCountBytesTwice() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = DownloadStatisticsStore(directory: directory)
        let transfers = try (0..<20).map { _ in try #require(store.begin(at: start)) }
        DispatchQueue.concurrentPerform(iterations: transfers.count * 2) { index in
            let transfer = transfers[index / 2]
            if index.isMultiple(of: 2) {
                store.record(transfer, receivedBytes: 600, at: start.addingTimeInterval(1))
            } else {
                store.finish(transfer, downloadedBytes: 1_000, at: start.addingTimeInterval(2))
            }
        }
        let snapshot = store.snapshot(at: start.addingTimeInterval(2))
        #expect(snapshot.activeDownloads == 0)
        #expect(snapshot.completedDownloads == 20)
        #expect(snapshot.downloadedBytes == 20_000)
        // Whichever call took the file lock first, each transfer is sampled exactly once.
        #expect(snapshot.bytesPerSecond == 10_000)
    }

    @Test func progressNeverWaitsForAHeartbeatBlockedOnTheFileLock() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = DownloadStatisticsStore(directory: directory)
        let measurement = try #require(DownloadMeasurement(store: store))
        // Stands in for the app's Statistics pane, or another process, reading the totals.
        let descriptor = open(directory.appending(path: "statistics.lock").path, O_RDWR | O_CLOEXEC)
        try #require(descriptor >= 0)
        defer { close(descriptor) }
        try #require(flock(descriptor, LOCK_EX) == 0)

        let sampled = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            measurement.sample()
            sampled.signal()
        }
        Thread.sleep(forTimeInterval: 0.2)
        let received = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            measurement.receive(1_000)
            received.signal()
        }
        #expect(received.wait(timeout: .now() + 2) == .success)
        #expect(sampled.wait(timeout: .now()) == .timedOut)
        flock(descriptor, LOCK_UN)
        #expect(sampled.wait(timeout: .now() + 5) == .success)

        measurement.finish(success: true)
        #expect(store.snapshot().downloadedBytes == 1_000)
        #expect(store.snapshot().activeDownloads == 0)
    }

    @Test func scopesMeasurementsToTheProfileDirectory() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = DownloadStatisticsStore(directory: directory.appending(path: "first"))
        let second = DownloadStatisticsStore(directory: directory.appending(path: "second"))
        let transfer = try #require(first.begin(at: start))
        first.finish(transfer, downloadedBytes: 123, at: start.addingTimeInterval(1))
        #expect(first.snapshot(at: start.addingTimeInterval(1)).downloadedBytes == 123)
        #expect(second.snapshot(at: start.addingTimeInterval(1)) == .empty)
    }

    @Test func boundsActiveRecordGrowth() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = DownloadStatisticsStore(directory: directory)
        for _ in 0..<DownloadStatisticsStore.maximumActiveDownloads {
            #expect(store.begin(at: start) != nil)
        }
        #expect(store.begin(at: start) == nil)
        #expect(store.snapshot(at: start).activeDownloads == DownloadStatisticsStore.maximumActiveDownloads)
        #expect(store.snapshot(at: start.addingTimeInterval(DownloadStatisticsStore.staleInterval + 1)) == .empty)
        #expect(store.begin(at: start.addingTimeInterval(DownloadStatisticsStore.staleInterval + 2)) != nil)
    }

    @Test func measurementFinalizationIsIdempotentAndAbandonmentIsFailure() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = DownloadStatisticsStore(directory: directory)
        let measurement = try #require(DownloadMeasurement(store: store))
        measurement.receive(1_000)
        measurement.finish(success: true, bytes: 1_234)
        measurement.finish(success: false)
        #expect(store.snapshot().downloadedBytes == 1_234)
        #expect(store.snapshot().completedDownloads == 1)

        var abandoned: DownloadMeasurement? = DownloadMeasurement(store: store)
        #expect(abandoned != nil)
        abandoned?.receive(999)
        #expect(store.snapshot().activeDownloads == 1)
        abandoned = nil
        #expect(store.snapshot().activeDownloads == 0)
        #expect(store.snapshot().downloadedBytes == 1_234)
    }

    @Test func originalDownloadsCountOnlyAfterValidationAndSaving() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = DownloadStatisticsStore(directory: directory)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StatisticsDownloadProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let client = ImmichClient(apiKey: "test-key", session: session,
                                  versionCache: ImmichClient.makeVersionCache(), downloadStatistics: store) {
            [URL(string: "https://download-test.invalid")!]
        }
        let destination = directory.appending(path: "download")
        try await client.downloadOriginal(assetID: "success", to: destination)
        #expect(try Data(contentsOf: destination).count == 1_234)
        #expect(store.snapshot().completedDownloads == 1)
        #expect(store.snapshot().downloadedBytes == 1_234)
        #expect(store.snapshot().activeDownloads == 0)

        await #expect(throws: ImmichError.unauthorized) {
            try await client.downloadOriginal(assetID: "unauthorized", to: directory.appending(path: "failed"))
        }
        // An existing destination makes the file move fail, despite a successful response.
        await #expect(throws: (any Error).self) {
            try await client.downloadOriginal(assetID: "success", to: destination)
        }
        #expect(store.snapshot().completedDownloads == 1)
        #expect(store.snapshot().downloadedBytes == 1_234)
        #expect(store.snapshot().activeDownloads == 0)

        let streamingStore = DownloadStatisticsStore(directory: directory.appending(path: "streaming-statistics"))
        let streamingClient = ImmichClient(apiKey: "test-key", session: session,
                                           versionCache: ImmichClient.makeVersionCache(), downloadStatistics: streamingStore) {
            [URL(string: "https://download-test.invalid")!]
        }
        let task = Task { try await streamingClient.downloadOriginal(assetID: "streaming", to: directory.appending(path: "cancelled")) }
        // Exercise actual URLSession progress, including a response with no Content-Length.
        // Wait for one heartbeat, with a bounded allowance for a busy test runner.
        for _ in 0..<60 where streamingStore.snapshot().bytesPerSecond == 0 {
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(streamingStore.snapshot().activeDownloads == 1)
        #expect(streamingStore.snapshot().bytesPerSecond > 0)
        task.cancel()
        await #expect(throws: (any Error).self) { try await task.value }
        #expect(streamingStore.snapshot().completedDownloads == 0)
        #expect(streamingStore.snapshot().activeDownloads == 0)
    }
}

private final class StatisticsDownloadProtocol: URLProtocol, @unchecked Sendable {
    private let streamingTimer = OSAllocatedUnfairLock<(any DispatchSourceTimer)?>(initialState: nil)

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else { return }
        if url.path.contains("streaming") {
            let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            let timer = DispatchSource.makeTimerSource(queue: .global())
            timer.schedule(deadline: .now(), repeating: .milliseconds(100))
            timer.setEventHandler { [weak self] in
                guard let self else { return }
                client?.urlProtocol(self, didLoad: Data(repeating: 42, count: 1_234))
            }
            streamingTimer.withLock { $0 = timer }
            timer.resume()
            return
        }
        let unauthorized = url.path.contains("unauthorized")
        let data = unauthorized ? Data(#"{"message":"Unauthorized"}"#.utf8) : Data(repeating: 42, count: 1_234)
        let response = HTTPURLResponse(url: url, statusCode: unauthorized ? 401 : 200,
                                       httpVersion: "HTTP/1.1", headerFields: ["Content-Length": String(data.count)])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {
        streamingTimer.withLock { $0?.cancel() }
    }
}

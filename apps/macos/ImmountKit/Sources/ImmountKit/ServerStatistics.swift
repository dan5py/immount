import Foundation

/// Assets owned by the signed-in user, including archived items but excluding hidden and trash.
public struct ImmichLibraryStatistics: Decodable, Equatable, Sendable {
    public let images: Int
    public let videos: Int
    public let total: Int
}

/// Capacity of the server's storage filesystem, not just the space occupied by this library.
public struct ImmichServerStorage: Decodable, Equatable, Sendable {
    public let diskSizeRaw: Int64
    public let diskUseRaw: Int64
    public let diskAvailableRaw: Int64
}

/// One HTTP ping of the endpoint actually selected after local-address fallback.
public struct ServerResponseSample: Equatable, Sendable {
    public let milliseconds: Double
    public let serverURL: URL
    public let measuredAt: Date
}

extension ImmichClient {
    /// Requires the optional `asset.statistics` permission. Explicit timeline and archive
    /// queries keep the scope consistent across Immich versions whose unfiltered defaults
    /// differ, and exclude hidden and trashed assets. Both counts come from the same endpoint.
    public func libraryStatistics() async throws -> ImmichLibraryStatistics {
        try await withFallback { base in
            let timeline = try await assetStatistics(visibility: "timeline", base: base)
            let archive = try await assetStatistics(visibility: "archive", base: base)
            let images = timeline.images.addingReportingOverflow(archive.images)
            let videos = timeline.videos.addingReportingOverflow(archive.videos)
            let total = timeline.total.addingReportingOverflow(archive.total)
            guard !images.overflow, !videos.overflow, !total.overflow else {
                throw ImmichError.invalidResponse
            }
            return ImmichLibraryStatistics(images: images.partialValue, videos: videos.partialValue, total: total.partialValue)
        }
    }

    /// Requires the optional `server.storage` permission; administrator access is not needed.
    public func serverStorage() async throws -> ImmichServerStorage {
        try await withFallback { base in
            let data = try await data(for: request("server/storage", base: base))
            guard let storage = try? Self.decoder.decode(ImmichServerStorage.self, from: data),
                  storage.diskSizeRaw >= 0, storage.diskUseRaw >= 0, storage.diskAvailableRaw >= 0 else {
                throw ImmichError.invalidResponse
            }
            return storage
        }
    }

    /// Measures a public ping without sending the API key or downloading a test asset.
    /// The monotonic duration covers only the successful endpoint's HTTP request, excluding
    /// fallback probes and failed addresses. This is response time, not download throughput.
    public func measureResponseTime() async throws -> ServerResponseSample {
        try await withFallback { base in
            struct Pong: Decodable { let res: String }
            var request = request("server/ping", base: base, timeout: 5)
            request.setValue(nil, forHTTPHeaderField: "x-api-key")
            request.cachePolicy = .reloadIgnoringLocalCacheData
            let clock = ContinuousClock()
            let started = clock.now
            let data = try await data(for: request)
            let elapsed = started.duration(to: clock.now).components
            guard let pong = try? Self.decoder.decode(Pong.self, from: data), pong.res == "pong" else {
                throw ImmichError.invalidResponse
            }
            return ServerResponseSample(
                milliseconds: Double(elapsed.seconds) * 1_000 + Double(elapsed.attoseconds) / 1e15,
                serverURL: base,
                measuredAt: .now
            )
        }
    }

    private func assetStatistics(visibility: String, base: URL) async throws -> ImmichLibraryStatistics {
        let data = try await data(for: request("assets/statistics", query: [
            URLQueryItem(name: "visibility", value: visibility),
            URLQueryItem(name: "isTrashed", value: "false"),
        ], base: base))
        guard let statistics = try? Self.decoder.decode(ImmichLibraryStatistics.self, from: data),
              statistics.images >= 0, statistics.videos >= 0, statistics.total >= 0 else {
            throw ImmichError.invalidResponse
        }
        return statistics
    }
}

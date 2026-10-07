import Foundation
import os
import Testing
@testable import ImmountKit

@Suite struct ServerStatisticsTests {
    @Test func libraryCountsIncludeTimelineAndArchiveButExcludeTrash() async throws {
        let requests = OSAllocatedUnfairLock<[URLRequest]>(initialState: [])
        let fixture = StatisticsFixture { request in
            requests.withLock { $0.append(request) }
            #expect(request.url?.path == "/api/assets/statistics")
            #expect(request.httpMethod == "GET")
            #expect(request.value(forHTTPHeaderField: "x-api-key") == "test-key")
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
            #expect(query.contains(URLQueryItem(name: "isTrashed", value: "false")))
            switch query.first(where: { $0.name == "visibility" })?.value {
            case "timeline": return .json(#"{"images":12,"videos":3,"total":15}"#)
            case "archive": return .json(#"{"images":4,"videos":2,"total":6}"#)
            default: throw ImmichError.invalidResponse
            }
        }
        let statistics = try await fixture.client.libraryStatistics()
        #expect(statistics.images == 16)
        #expect(statistics.videos == 5)
        #expect(statistics.total == 21)
        #expect(requests.withLock { $0.count } == 2)
    }

    @Test func storageReadsNumericByteValues() async throws {
        let fixture = StatisticsFixture { request in
            #expect(request.url?.path == "/api/server/storage")
            #expect(request.value(forHTTPHeaderField: "x-api-key") == "test-key")
            return .json(#"{"diskSize":"8 TiB","diskUse":"3 TiB","diskAvailable":"5 TiB","diskSizeRaw":8796093022208,"diskUseRaw":3298534883328,"diskAvailableRaw":5497558138880,"diskUsagePercentage":37.5}"#)
        }
        let storage = try await fixture.client.serverStorage()
        #expect(storage.diskSizeRaw == 8_796_093_022_208)
        #expect(storage.diskUseRaw == 3_298_534_883_328)
        #expect(storage.diskAvailableRaw == 5_497_558_138_880)
    }

    @Test(arguments: ["asset.statistics", "server.storage"])
    func optionalPermissionFailuresStayDistinct(permission: String) async {
        let message = "Missing required permission: \(permission)"
        let fixture = StatisticsFixture { _ in
            .json("{\"message\":\"\(message)\"}", status: 403)
        }
        await #expect(throws: ImmichError.missingPermission(message)) {
            if permission == "asset.statistics" {
                _ = try await fixture.client.libraryStatistics()
            } else {
                _ = try await fixture.client.serverStorage()
            }
        }
    }

    @Test func unsupportedStorageRouteRemainsAnHTTPError() async {
        let fixture = StatisticsFixture { _ in
            .json(#"{"message":"Cannot GET /api/server/storage"}"#, status: 404)
        }
        await #expect(throws: ImmichError.http(status: 404, message: "Cannot GET /api/server/storage")) {
            _ = try await fixture.client.serverStorage()
        }
    }

    @Test(arguments: [
        #"{}"#,
        #"{"images":"12","videos":3,"total":15}"#,
        #"{"images":-1,"videos":3,"total":2}"#,
        #"{"images":9223372036854775807,"videos":0,"total":9223372036854775807}"#,
    ])
    func rejectsInvalidCountsAndCombinedOverflow(json: String) async {
        let fixture = StatisticsFixture { _ in .json(json) }
        await #expect(throws: ImmichError.invalidResponse) {
            _ = try await fixture.client.libraryStatistics()
        }
    }

    @Test(arguments: [
        #"{}"#,
        #"{"diskSizeRaw":"100","diskUseRaw":40,"diskAvailableRaw":60}"#,
        #"{"diskSizeRaw":100,"diskUseRaw":-40,"diskAvailableRaw":60}"#,
    ])
    func rejectsInvalidStorage(json: String) async {
        let fixture = StatisticsFixture { _ in .json(json) }
        await #expect(throws: ImmichError.invalidResponse) {
            _ = try await fixture.client.serverStorage()
        }
    }

    @Test func responseMeasurementUsesAKeylessUncachedPing() async throws {
        let fixture = StatisticsFixture { request in
            #expect(request.url?.path == "/api/server/ping")
            #expect(request.httpMethod == "GET")
            #expect(request.value(forHTTPHeaderField: "x-api-key") == nil)
            #expect(request.timeoutInterval == 5)
            #expect(request.cachePolicy == .reloadIgnoringLocalCacheData)
            return .json(#"{"res":"pong"}"#)
        }
        let before = Date.now
        let sample = try await fixture.client.measureResponseTime()
        #expect(sample.serverURL == fixture.base)
        #expect(sample.milliseconds.isFinite && sample.milliseconds >= 0)
        #expect(sample.measuredAt >= before && sample.measuredAt <= .now)
    }

    @Test(arguments: [#"{}"#, #"{"res":"not pong"}"#, "<html>Login</html>"])
    func responseMeasurementRejectsNonPongResponses(json: String) async {
        let fixture = StatisticsFixture { _ in .json(json) }
        await #expect(throws: ImmichError.invalidResponse) {
            _ = try await fixture.client.measureResponseTime()
        }
    }

    @Test func responseMeasurementReportsTheSuccessfulFallbackEndpoint() async throws {
        let attempts = OSAllocatedUnfairLock<[URL]>(initialState: [])
        let local = URL(string: "https://local-\(UUID().uuidString).example.invalid")!
        let fixture = StatisticsFixture { request in
            attempts.withLock { $0.append(request.url!) }
            #expect(request.value(forHTTPHeaderField: "x-api-key") == nil)
            if request.url?.host() == local.host() { throw URLError(.cannotConnectToHost) }
            return .json(#"{"res":"pong"}"#)
        }
        Reachability.shared.record(local, reachable: true)
        let remote = fixture.base
        let client = ImmichClient(apiKey: "test-key", session: fixture.session) { [local, remote] }
        let sample = try await client.measureResponseTime()
        #expect(sample.serverURL == remote)
        #expect(attempts.withLock { $0.map { $0.host() } } == [local.host(), remote.host()])
    }

    @Test func aSlowResponseDoesNotSwitchEndpoints() async {
        let attempts = OSAllocatedUnfairLock(initialState: 0)
        let local = URL(string: "https://slow-\(UUID().uuidString).example.invalid")!
        let fixture = StatisticsFixture { _ in
            attempts.withLock { $0 += 1 }
            throw URLError(.timedOut)
        }
        Reachability.shared.record(local, reachable: true)
        let remote = fixture.base
        let client = ImmichClient(apiKey: "test-key", session: fixture.session) { [local, remote] }
        do {
            _ = try await client.measureResponseTime()
            Issue.record("Expected the selected endpoint to time out")
        } catch let error as URLError {
            // URLSession adds task metadata to the error; compare the stable error code.
            #expect(error.code == .timedOut)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
        #expect(attempts.withLock { $0 } == 1)
    }
}

/// Each ephemeral session has its own registered handler. Parallel tests cannot replace each
/// other's stubs, and this protocol fails closed rather than making an actual network request.
private final class StatisticsFixture: Sendable {
    let id = UUID().uuidString
    let base = URL(string: "https://\(UUID().uuidString).example.invalid")!
    let session: URLSession

    var client: ImmichClient { ImmichClient(serverURL: base, apiKey: "test-key", session: session) }

    init(handler: @escaping StatisticsURLProtocol.Handler) {
        let sessionID = id
        StatisticsURLProtocol.handlers.withLock { $0[sessionID] = handler }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StatisticsURLProtocol.self]
        configuration.httpAdditionalHeaders = [StatisticsURLProtocol.sessionHeader: id]
        session = URLSession(configuration: configuration)
    }

    deinit {
        session.invalidateAndCancel()
        StatisticsURLProtocol.handlers.withLock { $0[id] = nil }
    }
}

private final class StatisticsURLProtocol: URLProtocol, @unchecked Sendable {
    struct Reply: Sendable {
        let status: Int
        let body: Data

        static func json(_ body: String, status: Int = 200) -> Self {
            Self(status: status, body: Data(body.utf8))
        }
    }

    typealias Handler = @Sendable (URLRequest) throws -> Reply
    static let sessionHeader = "X-Immount-Statistics-Test"
    static let handlers = OSAllocatedUnfairLock<[String: Handler]>(initialState: [:])

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        do {
            guard let id = request.value(forHTTPHeaderField: Self.sessionHeader),
                  let handler = Self.handlers.withLock({ $0[id] }), let url = request.url else {
                throw URLError(.resourceUnavailable)
            }
            let reply = try handler(request)
            let response = HTTPURLResponse(url: url, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: reply.body)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

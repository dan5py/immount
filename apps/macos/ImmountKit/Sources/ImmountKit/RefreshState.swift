import Foundation

/// Small cross-process status record. It contains no asset IDs, filenames, or credentials.
public struct RefreshOutcome: Codable, Sendable, Equatable {
    public var completedAt: Date
    public var succeeded: Bool
    /// Only asset folders failed, and the server listed more folders than failed. `succeeded`
    /// is false, but the connection works: the failure belongs to those folders, which later
    /// checks retry with growing spacing.
    public var partiallySucceeded: Bool
    public var changedItemCount: Int
    public var duration: TimeInterval
    public var requestToken: String?

    public init(completedAt: Date = .now, succeeded: Bool, partiallySucceeded: Bool = false,
                changedItemCount: Int, duration: TimeInterval, requestToken: String? = nil) {
        self.completedAt = completedAt
        self.succeeded = succeeded
        self.partiallySucceeded = partiallySucceeded
        self.changedItemCount = changedItemCount
        self.duration = duration
        self.requestToken = requestToken
    }

    // Outcomes recorded by older versions have no `partiallySucceeded`.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        completedAt = try container.decode(Date.self, forKey: .completedAt)
        succeeded = try container.decode(Bool.self, forKey: .succeeded)
        partiallySucceeded = try container.decodeIfPresent(Bool.self, forKey: .partiallySucceeded) ?? false
        changedItemCount = try container.decode(Int.self, forKey: .changedItemCount)
        duration = try container.decode(TimeInterval.self, forKey: .duration)
        requestToken = try container.decodeIfPresent(String.self, forKey: .requestToken)
    }
}

extension SettingsStore {
    private enum RefreshKey {
        static let request = "finderFullRefreshRequest"
        static let acknowledgement = "finderFullRefreshAcknowledgement"
        static let outcome = "finderRefreshOutcome"
    }

    private struct Request: Codable {
        let profileID: String
        let token: String
    }

    private struct OutcomeRecord: Codable {
        let profileID: String
        let outcome: RefreshOutcome
    }

    /// Written only by the app. A newer click cannot be consumed by an older in-flight scan.
    @discardableResult
    public func requestFullRefresh(profileID: String) -> String {
        let token = UUID().uuidString
        if let data = try? JSONEncoder().encode(Request(profileID: profileID, token: token)) {
            defaults.set(data, forKey: RefreshKey.request)
        }
        return token
    }

    public func pendingFullRefresh(profileID: String) -> String? {
        guard let data = defaults.data(forKey: RefreshKey.request),
              let request = try? JSONDecoder().decode(Request.self, from: data),
              request.profileID == profileID else { return nil }
        if let data = defaults.data(forKey: RefreshKey.acknowledgement),
           let acknowledged = try? JSONDecoder().decode(Request.self, from: data),
           acknowledged.profileID == profileID, acknowledged.token == request.token { return nil }
        return request.token
    }

    public func refreshOutcome(profileID: String) -> RefreshOutcome? {
        guard let data = defaults.data(forKey: RefreshKey.outcome),
              let record = try? JSONDecoder().decode(OutcomeRecord.self, from: data),
              record.profileID == profileID else { return nil }
        return record.outcome
    }

    /// Written only by the extension, after the final batch has been committed. Keep the
    /// manual acknowledgement separate so later automatic checks cannot erase it.
    public func recordRefreshOutcome(_ outcome: RefreshOutcome, profileID: String) {
        // A late completion from a disconnected/replaced domain must not restore old state.
        guard isConnectionEnabled, loadProfile()?.id == profileID else { return }
        if let previous = refreshOutcome(profileID: profileID), previous.completedAt > outcome.completedAt { return }
        // A partial full scan checked every folder that works, and automatic checks retry the
        // failed ones. Keeping the request would rescan everything while one folder keeps
        // failing. A scan where a metadata folder failed, or as many folders failed as were
        // listed, keeps it for when the server is back.
        if outcome.succeeded || outcome.partiallySucceeded, let token = outcome.requestToken,
           pendingFullRefresh(profileID: profileID) == token,
           let data = try? JSONEncoder().encode(Request(profileID: profileID, token: token)) {
            defaults.set(data, forKey: RefreshKey.acknowledgement)
        }
        if let data = try? JSONEncoder().encode(OutcomeRecord(profileID: profileID, outcome: outcome)) {
            defaults.set(data, forKey: RefreshKey.outcome)
        }
    }

    public func clearRefreshState() {
        defaults.removeObject(forKey: RefreshKey.request)
        defaults.removeObject(forKey: RefreshKey.acknowledgement)
        defaults.removeObject(forKey: RefreshKey.outcome)
    }
}

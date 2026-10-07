import Foundation
import os

/// Settings shared by the app and the File Provider extension, stored in the app group's
/// UserDefaults. The app writes preferences; the extension writes refresh completion records.
public struct SettingsStore: @unchecked Sendable {
    // UserDefaults is documented as thread-safe but not marked Sendable.
    public let defaults: UserDefaults

    public init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    public static var shared: SettingsStore { SettingsStore(defaults: SharedContainer.defaults) }

    /// The opaque preference record changed by `statisticsEnabled`. Keep the enabled flag
    /// and collection generation in one write so another process cannot mix their values.
    public static let statisticsEnabledKey = "statisticsCollection"

    struct StatisticsCollection: Sendable, Equatable {
        var enabled: Bool
        var generation: String

        static let initial = StatisticsCollection(enabled: true, generation: "initial")
    }

    var statisticsCollection: StatisticsCollection {
        guard let record = defaults.dictionary(forKey: Self.statisticsEnabledKey),
              let enabled = record["enabled"] as? Bool,
              let generation = record["generation"] as? String else { return .initial }
        return StatisticsCollection(enabled: enabled, generation: generation)
    }

    /// Collection is enabled by default. Every change invalidates active measurements,
    /// including a quick off/on that the File Provider may not observe until afterward.
    public var statisticsEnabled: Bool {
        get { statisticsCollection.enabled }
        nonmutating set {
            guard newValue != statisticsEnabled else { return }
            defaults.set(["enabled": newValue, "generation": UUID().uuidString], forKey: Self.statisticsEnabledKey)
        }
    }

    enum Key {
        static let profile = "profile"
        static let connectionEnabled = "connectionEnabled"
        static let credentialsGeneration = "credentialsGeneration"
        static let localNetworkUntil = "localNetworkUntil"
        static let localNetworkBootSession = "localNetworkBootSession"
    }

    private static let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "ImmountKit", category: "settings")

    // MARK: Profile

    /// The raw stored profile, used to skip decoding when nothing changed.
    public var profileData: Data? {
        defaults.data(forKey: Key.profile)
    }

    public func loadProfile() -> ServerProfile? {
        guard let data = profileData else { return nil }
        return Self.decodeProfile(data)
    }

    static func decodeProfile(_ data: Data) -> ServerProfile? {
        do {
            return try JSONDecoder().decode(ServerProfile.self, from: data)
        } catch {
            log.error("Stored server profile is unreadable: \(error, privacy: .public)")
            return nil
        }
    }

    public func saveProfile(_ profile: ServerProfile) {
        guard let data = try? JSONEncoder().encode(profile) else { return }
        defaults.set(data, forKey: Key.profile)
    }

    public func removeProfile() {
        defaults.removeObject(forKey: Key.profile)
        defaults.removeObject(forKey: Key.connectionEnabled)
        clearLocalNetwork()
        clearRefreshState()
    }

    // MARK: Connection

    /// Whether Immich should appear in Finder. Disconnect turns this off but keeps the profile.
    public var isConnectionEnabled: Bool {
        get { defaults.bool(forKey: Key.connectionEnabled) }
        nonmutating set {
            defaults.set(newValue, forKey: Key.connectionEnabled)
            if !newValue { clearRefreshState() }
        }
    }

    /// Incremented whenever the API key changes, so the extension rereads the Keychain.
    public var credentialsGeneration: Int {
        defaults.integer(forKey: Key.credentialsGeneration)
    }

    public func bumpCredentialsGeneration() {
        defaults.set(credentialsGeneration + 1, forKey: Key.credentialsGeneration)
    }

    // MARK: Local network

    /// Whether the app recently confirmed the Mac is on a home network where the local URL works.
    ///
    /// Only the app can tell: reading the Wi-Fi name needs Location Services permission. The
    /// confirmation is a short lease the app keeps renewing, so after a crash, a force quit or a
    /// restart the extension goes back to the server URL on its own instead of sending the API
    /// key to a private address on some other network.
    public var isOnLocalNetwork: Bool {
        guard let until = defaults.object(forKey: Key.localNetworkUntil) as? Date, until > .now else { return false }
        return defaults.string(forKey: Key.localNetworkBootSession) == Self.bootSession
    }

    public static let localNetworkLease: TimeInterval = 3 * 60

    public func confirmLocalNetwork() {
        defaults.set(Date.now.addingTimeInterval(Self.localNetworkLease), forKey: Key.localNetworkUntil)
        defaults.set(Self.bootSession, forKey: Key.localNetworkBootSession)
    }

    public func clearLocalNetwork() {
        defaults.removeObject(forKey: Key.localNetworkUntil)
        defaults.removeObject(forKey: Key.localNetworkBootSession)
    }

    /// Changes on every boot, so a lease never survives a restart.
    static let bootSession: String = {
        var size = 0
        guard sysctlbyname("kern.bootsessionuuid", nil, &size, nil, 0) == 0, size > 0 else { return "" }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname("kern.bootsessionuuid", &buffer, &size, nil, 0) == 0 else { return "" }
        return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }()
}

public enum SharedContainer {
    /// Read from the `ImmountAppGroup` Info.plist key, which the build fills in with the
    /// signing team's prefix so forks can build without editing code.
    public static let appGroupID: String = infoValue("ImmountAppGroup")

    /// Read from `ImmountKeychainGroup`: the team-prefixed Keychain access group both targets are entitled to.
    public static let keychainGroupID: String = infoValue("ImmountKeychainGroup")

    /// UserDefaults is documented as thread-safe but not marked Sendable.
    nonisolated(unsafe) public static let defaults = UserDefaults(suiteName: appGroupID)!

    public static var url: URL {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupID)!
    }

    public static var stateRoot: URL {
        url.appending(path: "State", directoryHint: .isDirectory)
    }

    /// Where the extension keeps its listing store for a given profile.
    public static func stateDirectory(for profileID: String) -> URL {
        stateRoot.appending(path: profileID, directoryHint: .isDirectory)
    }

    /// Darwin notification the extension posts after recording a refresh outcome, so the app
    /// shows the new time right away instead of at its next automatic check.
    public static var refreshOutcomeNotification: String { appGroupID + ".refresh-outcome" }

    /// Darwin notification the app posts once it has removed the Finder location on quit,
    /// so the extension exits right away instead of waiting to notice the app is gone.
    public static var appQuitNotification: String { appGroupID + ".app-quit" }

    private static func infoValue(_ key: String) -> String {
        guard let value = Bundle.main.object(forInfoDictionaryKey: key) as? String, !value.isEmpty else {
            fatalError("\(key) is missing from Info.plist")
        }
        return value
    }
}

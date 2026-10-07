import Foundation

/// Everything Immount remembers about the server, except the API key (see `Keychain`).
///
/// The profile outlives the Finder connection: disconnecting keeps it, so connecting again
/// is one click. Only "Forget Server" deletes it. No user name or email is stored.
public struct ServerProfile: Codable, Sendable, Equatable {
    /// Stable for the life of the profile. It names the File Provider domain, the Keychain
    /// item and the listing cache folder. A new one is made only for a different Immich user.
    public var id: String
    public var serverURL: URL
    /// Used instead of `serverURL` while the Mac is on one of `localNetworks`,
    /// e.g. `http://192.168.1.10:2283` to skip the round trip through a reverse proxy.
    public var localServerURL: URL?
    /// Wi-Fi network names (SSIDs) on which `localServerURL` is reachable.
    public var localNetworks: [String]
    /// The Immich user behind the API key. Detects a key for a different account, and hides
    /// partner assets from Timeline and Favorites. Never shown in the UI.
    public var userID: String

    public init(
        id: String = ServerProfile.makeID(),
        serverURL: URL,
        localServerURL: URL? = nil,
        localNetworks: [String] = [],
        userID: String
    ) {
        self.id = id
        self.serverURL = serverURL
        self.localServerURL = localServerURL
        self.localNetworks = localNetworks
        self.userID = userID
    }

    public static func makeID() -> String {
        "immich-" + UUID().uuidString.prefix(8).lowercased()
    }

    /// The local network settings may be missing and unknown fields are ignored, so a profile
    /// written by a newer version keeps decoding. Without `userID` the profile is unreadable.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        serverURL = try container.decode(URL.self, forKey: .serverURL)
        localServerURL = try container.decodeIfPresent(URL.self, forKey: .localServerURL)
        localNetworks = try container.decodeIfPresent([String].self, forKey: .localNetworks) ?? []
        userID = try container.decode(String.self, forKey: .userID)
    }

    /// Whether the local URL applies on the Wi-Fi network named `ssid`.
    public func isLocal(ssid: String?) -> Bool {
        guard localServerURL != nil, let ssid else { return false }
        return localNetworks.contains(ssid)
    }

    public func serverURL(onLocalNetwork: Bool) -> URL {
        onLocalNetwork ? localServerURL ?? serverURL : serverURL
    }

    /// Whether a key saved for `saved` may be sent to `new`: only the same server, or the same
    /// host upgraded from http to https. Never a newly typed host, which could be a typo.
    public static func canReuseKey(from saved: URL, to new: URL) -> Bool {
        guard saved.host()?.lowercased() == new.host()?.lowercased() else { return false }
        let savedScheme = saved.scheme?.lowercased()
        let newScheme = new.scheme?.lowercased()
        if savedScheme == "http", newScheme == "https" { return true }
        return savedScheme == newScheme && saved.port == new.port
    }

    /// Addresses to try, best first. On the local network the server URL is a fallback in case
    /// the hint is stale. The reverse never happens: away from home, a private address could
    /// belong to another device on someone else's network, which must not get the API key.
    public func endpoints(onLocalNetwork: Bool) -> [URL] {
        guard onLocalNetwork, let localServerURL else { return [serverURL] }
        return [localServerURL, serverURL]
    }
}

import Foundation
import os

/// A ready-to-use client for the stored profile.
public struct Connection: Sendable {
    public var profile: ServerProfile
    public var client: ImmichClient

    public var catalog: Catalog {
        Catalog(client: client, ownerID: profile.userID)
    }
}

/// Builds clients from the stored profile and Keychain item, rereading them only when they
/// change. Resolve a connection at the start of every operation instead of keeping one, so a
/// new API key or address takes effect without restarting the extension.
public final class ConnectionProvider: Sendable {
    public enum Failure: Error, Equatable {
        /// No server profile is stored.
        case notConfigured
        /// The profile exists but Finder is disconnected, or belongs to another domain.
        case disconnected
        /// No API key is stored for the profile.
        case keyMissing
        /// The Keychain could not be read right now; worth retrying.
        case keychainUnavailable(OSStatus)
    }

    private struct Cache {
        var profileData: Data?
        var profile: ServerProfile?
        var key: (profileID: String, generation: Int, value: String)?
        var metadata = MetadataResponseCache()
    }

    private let settings: SettingsStore
    private let session: URLSession
    private let versionCache = ImmichClient.makeVersionCache()
    private let cache = OSAllocatedUnfairLock(initialState: Cache())

    public init(settings: SettingsStore = .shared, session: URLSession = ImmichSession.shared) {
        self.settings = settings
        self.session = session
    }

    /// The current profile, decoded again only when the stored bytes change.
    public var profile: ServerProfile? {
        let data = settings.profileData
        return cache.withLock { cache in
            if data != cache.profileData {
                cache.profileData = data
                cache.profile = data.flatMap(SettingsStore.decodeProfile)
                cache.metadata.removeAll()
                cache.metadata = MetadataResponseCache()
                versionCache.reset() // The server may have changed.
            }
            return cache.profile
        }
    }

    /// A connection for the stored profile. Pass the File Provider domain id to also require
    /// that Finder is connected to that profile.
    public func connection(domainID: String? = nil) throws -> Connection {
        guard let profile else { throw Failure.notConfigured }
        if let domainID, profile.id != domainID || !settings.isConnectionEnabled {
            throw Failure.disconnected
        }
        let key = try apiKey(for: profile.id)
        let metadataCache = cache.withLock { $0.metadata }
        let client = ImmichClient(apiKey: key, session: session, versionCache: versionCache,
                                  downloadStatistics: .forProfile(profile.id, settings: settings),
                                  metadataCache: metadataCache, metadataScope: profile.id) { [self, settings] in
            // Follow edits to this profile's addresses, but never pair this key with another profile.
            guard let current = self.profile, current.id == profile.id else { return [profile.serverURL] }
            return current.endpoints(onLocalNetwork: settings.isOnLocalNetwork)
        }
        return Connection(profile: profile, client: client)
    }

    /// Forgets the cached key, e.g. after the server rejected it, so the next connection
    /// reads the Keychain again.
    public func invalidateKey() {
        cache.withLock {
            $0.key = nil
            $0.metadata.removeAll()
            $0.metadata = MetadataResponseCache()
        }
    }

    private func apiKey(for profileID: String) throws -> String {
        let generation = settings.credentialsGeneration
        if let key = cache.withLock({ $0.key }), key.profileID == profileID, key.generation == generation {
            return key.value
        }
        switch Keychain.apiKey(for: profileID) {
        case .found(let value):
            cache.withLock {
                if $0.key?.profileID != profileID || $0.key?.generation != generation || $0.key?.value != value {
                    $0.metadata.removeAll()
                    $0.metadata = MetadataResponseCache()
                }
                $0.key = (profileID, generation, value)
            }
            return value
        case .notFound:
            throw Failure.keyMissing
        case .unavailable(let status):
            throw Failure.keychainUnavailable(status)
        }
    }
}

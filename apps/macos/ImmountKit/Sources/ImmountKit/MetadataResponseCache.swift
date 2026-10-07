import CryptoKit
import Foundation
import os

/// A bounded, memory-only cache of validated metadata indexes. Every use still contacts the
/// server; an ETag match also lets the client reuse the decoded response. No credentials or
/// original/thumbnail bytes are retained here. The byte budget measures encoded response size.
public final class MetadataResponseCache: Sendable {
    struct Key: Hashable, Sendable {
        let url: URL
        let credentialDigest: String
        let scope: String

        init(url: URL, apiKey: String, scope: String = "") {
            self.url = url
            credentialDigest = SHA256.hash(data: Data(apiKey.utf8)).description
            self.scope = scope
        }
    }

    struct Lookup<Value: Sendable>: Sendable {
        let key: Key
        let generation: UUID
        let sequence: UInt64
        let cached: (etag: String, value: Value)?
    }

    private struct Entry: Sendable {
        let etag: String
        let value: any Sendable
        let cost: Int
        let sequence: UInt64
        var lastAccess: UInt64
    }

    private struct State: Sendable {
        var entries: [Key: Entry] = [:]
        var cost = 0
        var sequence: UInt64 = 0
        var generation = UUID()
    }

    private let maxEntries: Int
    private let maxBytes: Int
    private let state = OSAllocatedUnfairLock(initialState: State())

    public init(maxEntries: Int = 64, maxBytes: Int = 8 * 1_024 * 1_024) {
        self.maxEntries = max(0, maxEntries)
        self.maxBytes = max(0, maxBytes)
    }

    /// Also prevents a response already in flight from repopulating the cleared cache.
    public func removeAll() {
        state.withLock { $0 = State() }
    }

    func lookup<Value: Sendable>(url: URL, apiKey: String, scope: String = "", as: Value.Type) -> Lookup<Value> {
        let key = Key(url: url, apiKey: apiKey, scope: scope)
        return state.withLock { state in
            state.sequence &+= 1
            let sequence = state.sequence
            var cached: (etag: String, value: Value)?
            if var entry = state.entries[key], let value = entry.value as? Value {
                entry.lastAccess = sequence
                state.entries[key] = entry
                cached = (entry.etag, value)
            }
            return Lookup(key: key, generation: state.generation, sequence: sequence, cached: cached)
        }
    }

    func store<Value: Sendable>(_ value: Value, etag: String?, encodedBytes: Int, for lookup: Lookup<Value>) {
        state.withLock { state in
            guard state.generation == lookup.generation,
                  (state.entries[lookup.key]?.sequence ?? 0) <= lookup.sequence else { return }
            if let old = state.entries.removeValue(forKey: lookup.key) { state.cost -= old.cost }
            guard let etag, !etag.isEmpty, etag.utf8.count <= 4_096,
                  !etag.contains("\r"), !etag.contains("\n"), maxEntries > 0 else { return }
            let overhead = lookup.key.url.absoluteString.utf8.count + lookup.key.credentialDigest.utf8.count
                + lookup.key.scope.utf8.count + etag.utf8.count
            guard encodedBytes >= 0, overhead <= maxBytes, encodedBytes <= maxBytes - overhead else { return }
            let cost = encodedBytes + overhead
            while state.entries.count >= maxEntries || state.cost > maxBytes - cost {
                guard let oldest = state.entries.min(by: { $0.value.lastAccess < $1.value.lastAccess })?.key,
                      let removed = state.entries.removeValue(forKey: oldest) else { break }
                state.cost -= removed.cost
            }
            state.entries[lookup.key] = Entry(etag: etag, value: value, cost: cost,
                                              sequence: lookup.sequence, lastAccess: state.sequence)
            state.cost += cost
        }
    }

    /// Unexpected Vary dimensions cannot be represented by our URL + credential key.
    static func permitsStorage(_ response: HTTPURLResponse) -> Bool {
        let directives = (response.value(forHTTPHeaderField: "Cache-Control") ?? "")
            .lowercased().split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        guard !directives.contains("no-store") else { return false }
        let vary = (response.value(forHTTPHeaderField: "Vary") ?? "")
            .lowercased().split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        return vary.allSatisfy { ["accept", "accept-encoding", "x-api-key"].contains($0) }
    }

    static func matches(_ responseETag: String?, sent etag: String) -> Bool {
        guard let responseETag else { return true }
        func opaque(_ value: String) -> String {
            let trimmed = value.trimmingCharacters(in: .whitespaces)
            return trimmed.hasPrefix("W/") ? String(trimmed.dropFirst(2)) : trimmed
        }
        return opaque(responseETag) == opaque(etag)
    }
}

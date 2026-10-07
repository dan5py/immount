import Foundation

/// A quick look at the album list between automatic checks, so an album changed in Immich
/// shows up in Finder within seconds, including the one being browsed. The watch never reads
/// album contents: a change only asks the extension for its usual check, which then fetches
/// the albums whose name, count or dates moved.
public enum AlbumWatchPolicy {
    public static let interval: TimeInterval = 10
    /// No keyboard or pointer input for this long pauses the watch.
    public static let idleLimit: TimeInterval = 5 * 60

    /// Only while someone is likely looking, on mains power and an unrestricted network, and
    /// while recent checks succeed. Otherwise the regular automatic cadence applies alone.
    public static func isActive(conditions: RefreshPolicy.Conditions, onBattery: Bool,
                                idleTime: TimeInterval, consecutiveFailures: Int) -> Bool {
        conditions.isConnected && !conditions.isAsleep && conditions.networkAvailable
            && !conditions.lowPower && !conditions.constrainedNetwork && !conditions.expensiveNetwork
            && !onBattery && idleTime.isFinite && idleTime < idleLimit && consecutiveFailures == 0
    }

    /// Spaces the checks the watch asks for like automatic ones, so a slow library cannot turn
    /// a stream of changes into back-to-back scans. A refused request is retried next time.
    public static func canRequestCheck(sinceLastCheck elapsed: TimeInterval?, lastRefreshDuration: TimeInterval) -> Bool {
        guard let elapsed else { return true }
        let duration = lastRefreshDuration.isFinite ? max(0, lastRefreshDuration) : RefreshPolicy.maximumInterval
        return elapsed.isFinite && elapsed >= max(interval, duration * 2)
    }

    /// Whether Finder would show something different: an album added, removed, renamed, or
    /// with a new count or date. The order the server lists them in does not matter.
    public static func changed(from old: [ImmichAlbum], to new: [ImmichAlbum]) -> Bool {
        func sorted(_ albums: [ImmichAlbum]) -> [ImmichAlbum] { albums.sorted { $0.id < $1.id } }
        return sorted(old) != sorted(new)
    }
}

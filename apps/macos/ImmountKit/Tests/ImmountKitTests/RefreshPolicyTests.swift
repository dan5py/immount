import Foundation
import Testing
@testable import ImmountKit

@Suite struct RefreshPolicyTests {
    @Test func cadenceUsesPowerAndNetworkCost() {
        #expect(RefreshPolicy.interval(for: .init()) == 30)
        #expect(RefreshPolicy.interval(for: .init(lowPower: true)) == 60)
        #expect(RefreshPolicy.interval(for: .init(constrainedNetwork: true)) == 120)
        #expect(RefreshPolicy.interval(for: .init(expensiveNetwork: true)) == 120)
        #expect(RefreshPolicy.interval(for: .init(lowPower: true, expensiveNetwork: true)) == 120)
    }

    @Test func disconnectedSleepingAndOfflinePauseAutomaticWork() {
        for conditions in [RefreshPolicy.Conditions(isConnected: false), .init(isAsleep: true), .init(networkAvailable: false)] {
            #expect(RefreshPolicy.interval(for: conditions) == nil)
            #expect(RefreshPolicy.delay(for: conditions, elapsed: 1000) == nil)
        }
    }

    @Test func failuresBackOffWithACapAndSuccessRestoresCadence() {
        #expect((0...6).map { RefreshPolicy.interval(for: .init(), consecutiveFailures: $0) } == [30, 60, 120, 240, 480, 600, 600])
        #expect(RefreshPolicy.interval(for: .init(), consecutiveFailures: Int.max) == 600)
        #expect(RefreshPolicy.interval(for: .init(), consecutiveFailures: -1) == 30)
        #expect(RefreshPolicy.interval(for: .init(), consecutiveFailures: 0) == 30)
    }

    @Test func slowRefreshesSetAMinimumSpacing() {
        #expect(RefreshPolicy.interval(for: .init(), lastRefreshDuration: 25) == 50)
        #expect(RefreshPolicy.interval(for: .init(), consecutiveFailures: 1, lastRefreshDuration: 25) == 100)
        #expect(RefreshPolicy.interval(for: .init(), lastRefreshDuration: 1000) == 600)
        #expect(RefreshPolicy.interval(for: .init(), lastRefreshDuration: -.infinity) == 600)
        #expect(RefreshPolicy.interval(for: .init(), lastRefreshDuration: .nan) == 600)
        #expect(RefreshPolicy.interval(for: .init(), lastRefreshDuration: -10) == 30)
    }

    @Test func resourceChangesPreserveElapsedTimeAndDueChecks() {
        #expect(RefreshPolicy.delay(for: .init(), elapsed: nil) == 30)
        #expect(RefreshPolicy.delay(for: .init(), elapsed: 20) == 10)
        #expect(RefreshPolicy.delay(for: .init(lowPower: true), elapsed: 20) == 40)
        #expect(RefreshPolicy.delay(for: .init(), elapsed: 60) == 0)
        #expect(RefreshPolicy.delay(for: .init(expensiveNetwork: true), elapsed: 60) == 60)
        #expect(RefreshPolicy.delay(for: .init(), elapsed: -10) == 30)
    }
}

@Suite struct AlbumWatchPolicyTests {
    private func album(_ id: String, name: String = "Trip", count: Int = 3, lastModified: Date? = nil) -> ImmichAlbum {
        ImmichAlbum(id: id, albumName: name, assetCount: count, createdAt: Date(timeIntervalSince1970: 0),
                    updatedAt: Date(timeIntervalSince1970: 100), lastModifiedAssetTimestamp: lastModified)
    }

    @Test func runsOnlyWhenSomeoneIsLikelyLookingOnMainsPower() {
        #expect(AlbumWatchPolicy.isActive(conditions: .init(), onBattery: false, idleTime: 5, consecutiveFailures: 0))
        #expect(!AlbumWatchPolicy.isActive(conditions: .init(), onBattery: true, idleTime: 5, consecutiveFailures: 0))
        #expect(!AlbumWatchPolicy.isActive(conditions: .init(), onBattery: false, idleTime: 5 * 60, consecutiveFailures: 0))
        #expect(!AlbumWatchPolicy.isActive(conditions: .init(), onBattery: false, idleTime: .nan, consecutiveFailures: 0))
        #expect(!AlbumWatchPolicy.isActive(conditions: .init(), onBattery: false, idleTime: 5, consecutiveFailures: 1))
        for conditions in [RefreshPolicy.Conditions(isConnected: false), .init(isAsleep: true), .init(networkAvailable: false),
                           .init(lowPower: true), .init(constrainedNetwork: true), .init(expensiveNetwork: true)] {
            #expect(!AlbumWatchPolicy.isActive(conditions: conditions, onBattery: false, idleTime: 5, consecutiveFailures: 0))
        }
    }

    @Test func requestedChecksKeepTheAutomaticSpacing() {
        #expect(AlbumWatchPolicy.canRequestCheck(sinceLastCheck: nil, lastRefreshDuration: 0))
        #expect(!AlbumWatchPolicy.canRequestCheck(sinceLastCheck: 5, lastRefreshDuration: 0))
        #expect(AlbumWatchPolicy.canRequestCheck(sinceLastCheck: 10, lastRefreshDuration: 0))
        #expect(!AlbumWatchPolicy.canRequestCheck(sinceLastCheck: 30, lastRefreshDuration: 20))
        #expect(AlbumWatchPolicy.canRequestCheck(sinceLastCheck: 40, lastRefreshDuration: 20))
        #expect(!AlbumWatchPolicy.canRequestCheck(sinceLastCheck: 60, lastRefreshDuration: .infinity))
        #expect(!AlbumWatchPolicy.canRequestCheck(sinceLastCheck: .nan, lastRefreshDuration: 0))
    }

    @Test func changesAreWhatFinderWouldShowRegardlessOfOrder() {
        let list = [album("a"), album("b")]
        #expect(!AlbumWatchPolicy.changed(from: list, to: list.reversed()))
        #expect(AlbumWatchPolicy.changed(from: list, to: [album("a")]))
        #expect(AlbumWatchPolicy.changed(from: list, to: list + [album("c")]))
        #expect(AlbumWatchPolicy.changed(from: list, to: [album("a", name: "Renamed"), album("b")]))
        #expect(AlbumWatchPolicy.changed(from: list, to: [album("a", count: 4), album("b")]))
        #expect(AlbumWatchPolicy.changed(from: list, to: [album("a", lastModified: Date(timeIntervalSince1970: 200)), album("b")]))
    }
}

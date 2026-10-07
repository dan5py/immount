import Foundation
import Testing
@testable import ImmountKit

@Suite struct RefreshOutcomeTests {
    private func connectedStore() -> (SettingsStore, ServerProfile) {
        let store = SettingsStore(defaults: UserDefaults(suiteName: "immount-refresh-outcome-tests-\(UUID().uuidString)")!)
        let profile = ServerProfile(serverURL: URL(string: "https://photos.example.com")!, userID: "u1")
        store.saveProfile(profile)
        store.isConnectionEnabled = true
        return (store, profile)
    }

    @Test func partialFullScanAcknowledgesTheManualRequest() {
        let (store, profile) = connectedStore()
        let token = store.requestFullRefresh(profileID: profile.id)
        let partial = RefreshOutcome(succeeded: false, partiallySucceeded: true, changedItemCount: 2, duration: 1, requestToken: token)
        store.recordRefreshOutcome(partial, profileID: profile.id)
        #expect(store.pendingFullRefresh(profileID: profile.id) == nil)
        #expect(store.refreshOutcome(profileID: profile.id) == partial)
    }

    @Test func fullScanThatListedNothingKeepsTheManualRequest() {
        let (store, profile) = connectedStore()
        let token = store.requestFullRefresh(profileID: profile.id)
        store.recordRefreshOutcome(.init(succeeded: false, changedItemCount: 0, duration: 1, requestToken: token), profileID: profile.id)
        #expect(store.pendingFullRefresh(profileID: profile.id) == token)
    }

    @Test func outcomesRecordedBeforePartialSuccessExistedStillDecode() throws {
        let json = #"{"completedAt":700000000,"succeeded":false,"changedItemCount":3,"duration":1.5,"requestToken":"t"}"#
        let outcome = try JSONDecoder().decode(RefreshOutcome.self, from: Data(json.utf8))
        #expect(outcome == RefreshOutcome(completedAt: Date(timeIntervalSinceReferenceDate: 700_000_000), succeeded: false,
                                          changedItemCount: 3, duration: 1.5, requestToken: "t"))
        let roundTripped = try JSONDecoder().decode(RefreshOutcome.self, from: JSONEncoder().encode(
            RefreshOutcome(succeeded: false, partiallySucceeded: true, changedItemCount: 0, duration: 0)
        ))
        #expect(roundTripped.partiallySucceeded)
    }
}

import Foundation
import Testing
@testable import ImmountKit

@Suite struct RefreshStateTests {
    private func connectedStore() -> (SettingsStore, ServerProfile) {
        let store = SettingsStore(defaults: UserDefaults(suiteName: "immount-refresh-tests-\(UUID().uuidString)")!)
        let profile = ServerProfile(serverURL: URL(string: "https://photos.example.com")!, userID: "u1")
        store.saveProfile(profile)
        store.isConnectionEnabled = true
        return (store, profile)
    }

    @Test func automaticAndFailedChecksDoNotConsumeManualRequests() {
        let (store, profile) = connectedStore()
        let token = store.requestFullRefresh(profileID: profile.id)
        store.recordRefreshOutcome(.init(succeeded: true, changedItemCount: 0, duration: 1), profileID: profile.id)
        #expect(store.pendingFullRefresh(profileID: profile.id) == token)
        store.recordRefreshOutcome(.init(succeeded: false, changedItemCount: 1, duration: 1, requestToken: token), profileID: profile.id)
        #expect(store.pendingFullRefresh(profileID: profile.id) == token)
        store.recordRefreshOutcome(.init(succeeded: true, changedItemCount: 1, duration: 1, requestToken: token), profileID: profile.id)
        #expect(store.pendingFullRefresh(profileID: profile.id) == nil)
        store.recordRefreshOutcome(.init(succeeded: true, changedItemCount: 0, duration: 1), profileID: profile.id)
        #expect(store.pendingFullRefresh(profileID: profile.id) == nil)
    }

    @Test func olderBatchCannotAcknowledgeANewerManualRequest() {
        let (store, profile) = connectedStore()
        let old = store.requestFullRefresh(profileID: profile.id)
        let latest = store.requestFullRefresh(profileID: profile.id)
        store.recordRefreshOutcome(.init(succeeded: true, changedItemCount: 1, duration: 1, requestToken: old), profileID: profile.id)
        #expect(store.pendingFullRefresh(profileID: profile.id) == latest)
        store.recordRefreshOutcome(.init(succeeded: true, changedItemCount: 1, duration: 1, requestToken: latest), profileID: profile.id)
        store.recordRefreshOutcome(.init(succeeded: true, changedItemCount: 1, duration: 1, requestToken: old), profileID: profile.id)
        #expect(store.pendingFullRefresh(profileID: profile.id) == nil)
    }

    @Test func completionIsSharedAndScopedToTheConnectedProfile() {
        let (store, profile) = connectedStore()
        let reader = SettingsStore(defaults: store.defaults)
        let token = store.requestFullRefresh(profileID: profile.id)
        let outcome = RefreshOutcome(succeeded: true, changedItemCount: 3, duration: 0.25, requestToken: token)
        store.recordRefreshOutcome(outcome, profileID: profile.id)
        #expect(reader.refreshOutcome(profileID: profile.id) == outcome)
        #expect(reader.refreshOutcome(profileID: "another-profile") == nil)
        #expect(reader.pendingFullRefresh(profileID: "another-profile") == nil)
        store.isConnectionEnabled = false
        store.recordRefreshOutcome(outcome, profileID: profile.id)
        #expect(reader.refreshOutcome(profileID: profile.id) == nil)
        #expect(reader.pendingFullRefresh(profileID: profile.id) == nil)
    }
}

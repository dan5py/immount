import AppKit
import Sparkle

/// App updates through Sparkle.
///
/// Immount usually runs in the background, often without a Dock icon, so a scheduled check that
/// finds an update does not open a window over whatever the user is doing. The update waits in
/// the menu bar menu and in Settings until the user looks at it ("gentle reminders").
///
/// Builds without a feed URL and public key (see Config/Base.xcconfig) never start Sparkle and
/// hide every update control.
@Observable
final class AppUpdater: NSObject {
    @ObservationIgnored private var controller: SPUStandardUpdaterController?
    @ObservationIgnored private var observations: [NSKeyValueObservation] = []

    private(set) var canCheckForUpdates = false
    private(set) var lastCheck: Date?
    /// The version a scheduled check found and the user has not seen yet.
    private(set) var pendingVersion: String?

    /// Whether this build was configured for updates.
    let isAvailable: Bool

    override init() {
        isAvailable = Self.isConfigured
        super.init()
        guard isAvailable else { return }
        let controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: self, userDriverDelegate: self)
        self.controller = controller
        let updater = controller.updater
        observations = [
            updater.observe(\.canCheckForUpdates, options: [.initial, .new]) { [weak self] updater, _ in
                MainActor.assumeIsolated { self?.canCheckForUpdates = updater.canCheckForUpdates }
            },
            updater.observe(\.lastUpdateCheckDate, options: [.initial, .new]) { [weak self] updater, _ in
                MainActor.assumeIsolated { self?.lastCheck = updater.lastUpdateCheckDate }
            },
        ]
    }

    var automaticallyChecks: Bool {
        get {
            access(keyPath: \.automaticallyChecks)
            return controller?.updater.automaticallyChecksForUpdates ?? false
        }
        set {
            withMutation(keyPath: \.automaticallyChecks) {
                controller?.updater.automaticallyChecksForUpdates = newValue
            }
        }
    }

    var automaticallyDownloads: Bool {
        get {
            access(keyPath: \.automaticallyDownloads)
            return controller?.updater.automaticallyDownloadsUpdates ?? false
        }
        set {
            withMutation(keyPath: \.automaticallyDownloads) {
                controller?.updater.automaticallyDownloadsUpdates = newValue
            }
        }
    }

    /// Shows Sparkle's update window, in front even when Immount has no Dock icon.
    func checkForUpdates() {
        guard let controller else { return }
        NSApp.activate(ignoringOtherApps: true)
        controller.checkForUpdates(nil)
    }

    private static var isConfigured: Bool {
        let info = Bundle.main.infoDictionary
        let feed = info?["SUFeedURL"] as? String ?? ""
        let key = info?["SUPublicEDKey"] as? String ?? ""
        #if DEBUG
        let hasFeed = !feed.isEmpty || UserDefaults.standard.string(forKey: "ImmountUpdateFeedURL") != nil
        #else
        let hasFeed = !feed.isEmpty
        #endif
        return hasFeed && !key.isEmpty
    }
}

extension AppUpdater: @MainActor SPUUpdaterDelegate {
    #if DEBUG
    /// Debug builds can test an update against a local appcast:
    /// `Immount.app/Contents/MacOS/Immount -ImmountUpdateFeedURL http://localhost:8000/appcast.xml`
    func feedURLString(for updater: SPUUpdater) -> String? {
        UserDefaults.standard.string(forKey: "ImmountUpdateFeedURL")
    }
    #endif
}

extension AppUpdater: @MainActor SPUStandardUserDriverDelegate {
    var supportsGentleScheduledUpdateReminders: Bool { true }

    /// Sparkle shows a scheduled update itself only when Immount is already in front.
    func standardUserDriverShouldHandleShowingScheduledUpdate(_ update: SUAppcastItem, andInImmediateFocus immediateFocus: Bool) -> Bool {
        immediateFocus
    }

    func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState) {
        // A background check that Sparkle won't show: remind the user in the menus instead.
        if !handleShowingUpdate && !state.userInitiated {
            pendingVersion = update.displayVersionString
        }
    }

    func standardUserDriverDidReceiveUserAttention(forUpdate update: SUAppcastItem) {
        pendingVersion = nil
    }

    func standardUserDriverWillFinishUpdateSession() {
        pendingVersion = nil
    }
}

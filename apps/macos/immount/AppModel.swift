import AppKit
import FileProvider
import ImmountKit
import Observation
import os
import ServiceManagement

/// What the sidebar header and the menu bar say about the connection.
enum ConnectionStatus: Equatable {
    case notConfigured
    case disconnected
    case checking
    case connected(local: Bool)
    case unreachable
    case keyRejected
    case keyMissing
    case missingPermissions([String])
    /// A problem retrying will not fix, e.g. the server redirects elsewhere.
    case failed(String)

    var title: String {
        switch self {
        case .notConfigured: "Not set up"
        case .disconnected: "Not connected"
        case .checking: "Checking…"
        case .connected(let local): local ? "Connected locally" : "Connected"
        case .unreachable: "Can't reach server"
        case .keyRejected: "API key not accepted"
        case .keyMissing: "API key missing"
        case .missingPermissions: "Missing permissions"
        case .failed: "Needs attention"
        }
    }

    var color: NSColor {
        switch self {
        case .notConfigured, .disconnected: .secondaryLabelColor
        case .checking: .systemYellow
        case .connected: .systemGreen
        case .unreachable: .systemOrange
        case .keyRejected, .keyMissing, .missingPermissions, .failed: .systemRed
        }
    }

    var needsAttention: Bool {
        switch self {
        case .unreachable, .keyRejected, .keyMissing, .missingPermissions, .failed: true
        default: false
        }
    }
}

/// Owns the server profile and the File Provider domain that shows it in Finder.
///
/// What is stored where:
/// - App group defaults (`SettingsStore`): the server profile and whether Finder is connected.
/// - Keychain: the API key.
/// - Standard defaults: app-only preferences (menu bar and Dock icon, last refresh).
/// Disconnect only removes the Finder location; "Forget Server" erases everything.
@Observable
final class AppModel {
    enum Activity: Equatable {
        case starting, connecting, disconnecting, forgetting, refreshing, savingLocalURL, clearingCache
    }

    enum SaveOutcome: Equatable {
        case saved
        case failed(String)
        /// The key belongs to a different Immich account; saving replaces the Finder location.
        case needsAccountSwitch
    }

    struct CacheConfirmation: Identifiable {
        let id = UUID()
        let title: String
        let detail: String
    }

    private(set) var profile: ServerProfile?
    private(set) var isConnected = false
    private(set) var status: ConnectionStatus = .notConfigured
    private(set) var hasSavedKey = false
    private(set) var serverVersion: String?
    private(set) var lastRefresh: Date? = UserDefaults.standard.object(forKey: "lastRefresh") as? Date
    private(set) var activity: Activity?
    private(set) var loginItemStatus = SMAppService.mainApp.status
    private(set) var statisticsEnabled = SettingsStore.shared.statisticsEnabled
    private(set) var cacheUsage: FileProviderCache.Usage?
    private(set) var isCheckingCache = false
    private(set) var cacheConfirmation: CacheConfirmation?
    private var cacheScanError: String?
    private var cacheClearError: String?
    var cacheError: String? { cacheClearError ?? cacheScanError }
    var errorMessage: String?

    // Drafts for the first-time connect form and the local URL field.
    var serverInput = ""
    var apiKeyInput = ""
    var localURLInput = ""
    private(set) var localURLError: String?

    let wifi = WiFiMonitor()
    /// Whether requests currently go to the local URL: on a listed network, and it answered.
    private(set) var isOnLocalNetwork = false
    /// On a listed network, but the local URL did not answer, so the server URL is used.
    private(set) var localURLUnreachable = false

    @ObservationIgnored private let settings = SettingsStore.shared
    @ObservationIgnored private let provider = ConnectionProvider()
    @ObservationIgnored private var refreshLoop: Task<Void, Never>?
    @ObservationIgnored private var leaseLoop: Task<Void, Never>?
    @ObservationIgnored private var healthCheck: Task<Void, Never>?
    @ObservationIgnored private var healthRequest: (id: UUID, epoch: Int, route: UUID, task: Task<Void, Never>)?
    @ObservationIgnored private var healthRouteGeneration = UUID()
    @ObservationIgnored private var refreshSignal: (id: UUID, task: Task<Void, Error>)?
    @ObservationIgnored private var networkCheck: Task<Void, Never>?
    @ObservationIgnored private var albumWatchLoop: Task<Void, Never>?
    /// The album list at the last look, tagged with the epoch it belongs to.
    @ObservationIgnored private var watchedAlbums: (epoch: Int, albums: [ImmichAlbum])?
    @ObservationIgnored private var albumWatchFailures = 0
    @ObservationIgnored private var automaticGeneration = UUID()
    @ObservationIgnored private var automaticFailures = 0
    @ObservationIgnored private var healthFailures = 0
    @ObservationIgnored private var lastRefreshDuration: TimeInterval = 0
    @ObservationIgnored private var lastRefreshOutcomeAt: Date?
    @ObservationIgnored private var lastAutomaticAttempt: ContinuousClock.Instant?
    @ObservationIgnored private var lastHealthCheckAt: Date?
    @ObservationIgnored private var cacheScan: (id: UUID, task: Task<FileProviderCache.Usage, Error>)?
    @ObservationIgnored private var cacheClear: (id: UUID, task: Task<FileProviderCache.ClearResult, Error>)?
    /// Clears that left the cache size unknown. The General pane checks the size again after one.
    @ObservationIgnored private var unmeasuredCacheClears = 0
    @ObservationIgnored private var cacheConfirmationExpiry: Task<Void, Never>?
    /// Between sleep and wake no network is trusted.
    @ObservationIgnored private var isAsleep = false
    /// Changes whenever the profile or connection changes, so slow checks can tell their
    /// result is out of date.
    @ObservationIgnored private var epoch = 0
    @ObservationIgnored private let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "immount", category: "app")

    /// How often the Wi-Fi network and local URL are checked again, renewing the lease the
    /// extension relies on (see `SettingsStore.isOnLocalNetwork`).
    static let networkInterval: Duration = .seconds(60)

    var activeServerURL: URL? {
        profile?.serverURL(onLocalNetwork: isOnLocalNetwork)
    }

    var isBusy: Bool { activity != nil }

    init() {
        // A lease left by a crash must not outlive this launch's own check.
        settings.clearLocalNetwork()
        loadStoredState()
        wifi.onChange = { [weak self] in self?.applyNetwork() }
        wifi.onPathChange = { [weak self] becameAvailable in
            guard let self else { return }
            self.restartAutomaticRefresh(promptly: becameAvailable)
            if !self.wifi.networkAvailable {
                self.healthCheck?.cancel()
                self.healthRequest?.task.cancel()
            }
            if becameAvailable, !self.isAsleep, self.isConnected { self.scheduleHealthCheck() }
        }
        observeSystem()
        Task { await start() }
    }

    private func loadStoredState() {
        profile = settings.loadProfile()
        isConnected = profile != nil && settings.isConnectionEnabled
        hasSavedKey = profile.map { Keychain.apiKey(for: $0.id) != .notFound } ?? false
        serverInput = profile?.serverURL.absoluteString ?? ""
        localURLInput = profile?.localServerURL?.absoluteString ?? ""
        status = profile == nil ? .notConfigured : (isConnected ? .checking : .disconnected)
    }

    private func observeSystem() {
        let center = NotificationCenter.default
        center.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.loginItemStatus = SMAppService.mainApp.status
                if self.status.needsAttention { self.scheduleHealthCheck() }
            }
        }
        center.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            // The extension cannot see the Wi-Fi network; without the app it must assume it is away.
            MainActor.assumeIsolated {
                self?.stopLoops()
                self?.settings.clearLocalNetwork()
            }
        }
        // The model lives as long as the app, so the unretained pointer stays valid.
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(), Unmanaged.passUnretained(self).toOpaque(),
            { _, observer, _, _, _ in
                guard let observer else { return }
                let model = Unmanaged<AppModel>.fromOpaque(observer).takeUnretainedValue()
                Task { @MainActor in model.refreshOutcomeArrived() }
            },
            SharedContainer.refreshOutcomeNotification as CFString, nil, .deliverImmediately
        )
        center.addObserver(forName: .NSProcessInfoPowerStateDidChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.restartAutomaticRefresh() }
        }
        let workspace = NSWorkspace.shared.notificationCenter
        workspace.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            // The Mac may wake up on another network.
            MainActor.assumeIsolated {
                guard let self else { return }
                self.isAsleep = true
                self.stopLoops()
                self.networkCheck?.cancel()
                self.setLocal(false, unreachable: false)
            }
        }
        workspace.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.isAsleep = false
                self.wifi.update()
                if self.isConnected {
                    self.startLoops(reset: false, promptly: true)
                    if self.wifi.networkAvailable { self.scheduleHealthCheck() }
                }
            }
        }
    }

    private func start() async {
        #if DEBUG
        // Lets `IMMOUNT_SERVER=... IMMOUNT_API_KEY=... Immount.app/Contents/MacOS/Immount` connect without the UI.
        let environment = ProcessInfo.processInfo.environment
        if profile == nil, let server = environment["IMMOUNT_SERVER"], let key = environment["IMMOUNT_API_KEY"] {
            serverInput = server
            apiKeyInput = key
            await connect()
            return
        }
        #endif
        activity = .starting
        await reconcile()
        activity = nil
        if isConnected {
            startLoops()
            applyNetwork()
            await checkHealth()
        }
    }

    /// Makes the registered Finder locations, listing caches and Keychain items match the
    /// stored settings, cleaning up whatever an interrupted connect or disconnect left.
    private func reconcile() async {
        // Settings that exist but cannot be read (written by a newer version, or by a build
        // that stored no user) may still name the Finder location, cache and key; keep
        // everything until they can be read again or a new connection replaces them.
        guard !(settings.profileData != nil && profile == nil) else {
            log.error("Stored settings are unreadable; skipping cleanup")
            return
        }
        do {
            let domains = try await NSFileProviderManager.domains()
            for domain in domains {
                let keep = isConnected ? profile?.id : nil
                guard domain.identifier.rawValue != keep else { continue }
                log.info("Removing stale Finder location \(domain.identifier.rawValue, privacy: .public)")
                _ = try? await NSFileProviderManager.remove(domain, mode: .removeAll)
            }
            if isConnected, let profile, !domains.contains(where: { $0.identifier.rawValue == profile.id }) {
                try await NSFileProviderManager.add(Self.domain(for: profile))
            }
        } catch {
            log.error("Reconciling Finder locations failed: \(error, privacy: .public)")
            errorMessage = "Immount could not set up its Finder location: \(error.localizedDescription)"
        }

        let keepFolder = isConnected ? profile?.id : nil
        let stateFolders = (try? FileManager.default.contentsOfDirectory(at: SharedContainer.stateRoot, includingPropertiesForKeys: nil)) ?? []
        for folder in stateFolders where folder.lastPathComponent != keepFolder {
            try? FileManager.default.removeItem(at: folder)
        }
        let keepKey = profile?.id
        for id in Keychain.storedProfileIDs() where id != keepKey {
            Keychain.deleteAPIKey(for: id)
        }
    }

    // MARK: Connecting

    /// Connects with the first-time form's server URL and API key.
    func connect() async {
        guard !isBusy else { return }
        errorMessage = nil
        if case .failed(let message) = await saveConnection(serverText: serverInput, keyText: apiKeyInput, connect: true, allowAccountSwitch: true) {
            errorMessage = message
        }
    }

    /// Validates a server URL and API key, saves them, and connects Finder if `connect`.
    /// An empty key reuses the saved one, but only for the server it was saved for.
    func saveConnection(serverText: String, keyText: String, connect: Bool, allowAccountSwitch: Bool) async -> SaveOutcome {
        guard !isBusy else { return .failed("Another change is still in progress.") }
        guard var url = ImmichClient.normalizeServerURL(serverText) else {
            return .failed("Enter the address of your Immich server, like https://photos.example.com")
        }
        var apiKey = keyText.trimmingCharacters(in: .whitespacesAndNewlines)
        if apiKey.isEmpty {
            guard let profile else { return .failed("Paste an API key from Immich (Account Settings > API Keys).") }
            guard ServerProfile.canReuseKey(from: profile.serverURL, to: url) else {
                return .failed("Enter the API key for this server. The saved key is only sent to the server it was created on.")
            }
            guard case .found(let saved) = Keychain.apiKey(for: profile.id) else {
                return .failed("Paste your API key again.")
            }
            apiKey = saved
        }

        activity = .connecting
        defer { activity = nil }
        let old = profile
        let wasConnected = isConnected
        let replacesUnreadable = old == nil && settings.profileData != nil
        do {
            // A server that redirects http to https is saved as https, so the key is never sent
            // in plain text. Checked without the key.
            url = await ImmichClient(serverURL: url, apiKey: "").upgradedServerURL()
            let userID = try await validate(url: url, apiKey: apiKey)
            let sameAccount = old?.userID == userID
            if old != nil, !sameAccount, !allowAccountSwitch { return .needsAccountSwitch }

            // Same account: keep the profile id, so the Finder location and cache stay. Another
            // account gets a fresh id and none of the previous account's files.
            var updated = sameAccount ? old! : ServerProfile(serverURL: url, localNetworks: old?.localNetworks ?? [], userID: userID)
            // The local URL belongs to a server; keep it only while the server stays the same.
            let sameHost = old?.serverURL.host()?.lowercased() == url.host()?.lowercased()
            updated.localServerURL = sameHost ? old?.localServerURL : nil
            updated.serverURL = url

            // Store the new settings before removing anything, so an interruption loses nothing.
            try Keychain.setAPIKey(apiKey, for: updated.id)
            settings.saveProfile(updated)
            settings.bumpCredentialsGeneration()
            epoch += 1
            resetCacheState()
            if let old, old.id != updated.id {
                await removeFinderLocation(for: old)
                Keychain.deleteAPIKey(for: old.id)
                setLastRefresh(nil)
            }
            profile = updated
            // Nothing else removes the Finder location, cache and key the unreadable settings named.
            if replacesUnreadable { await reconcile() }
            hasSavedKey = true
            serverInput = url.absoluteString
            apiKeyInput = ""
            localURLInput = updated.localServerURL?.absoluteString ?? ""
            localURLError = nil
            if old?.localServerURL != nil, updated.localServerURL == nil {
                errorMessage = "The server changed, so the local URL was cleared. Set it again in Local Network."
            }

            if connect || wasConnected {
                do {
                    try await connectFinder(to: updated)
                    if !wasConnected || old?.id != updated.id { await showInFinder() }
                } catch {
                    status = .disconnected
                    errorMessage = "Saved, but Immich could not be added to Finder: \(error.localizedDescription)"
                }
            } else if !isConnected {
                status = .disconnected
            }
            return .saved
        } catch {
            log.error("Saving the connection failed: \(error, privacy: .public)")
            hasSavedKey = profile.map { Keychain.apiKey(for: $0.id) != .notFound } ?? false
            return .failed(Self.describe(error))
        }
    }

    /// Connects Finder again with the saved URL and key.
    func reconnect() async {
        guard let profile, !isBusy else { return }
        errorMessage = nil
        guard case .found(let key) = Keychain.apiKey(for: profile.id) else {
            errorMessage = "Paste your API key again to connect."
            hasSavedKey = false
            return
        }
        activity = .connecting
        defer { activity = nil }
        do {
            let userID = try await validate(url: profile.serverURL, apiKey: key)
            guard self.profile?.id == profile.id else { return }
            guard profile.userID == userID else {
                errorMessage = "The saved API key now belongs to a different Immich account. Enter the key again in Details."
                return
            }
            try await connectFinder(to: self.profile ?? profile)
            await showInFinder()
        } catch {
            errorMessage = Self.describe(error)
        }
    }

    /// Checks that the key works and has every permission Immount needs. Returns the user id.
    private func validate(url: URL, apiKey: String) async throws -> String {
        let client = ImmichClient(serverURL: url, apiKey: apiKey)
        do {
            let missing = try await client.apiKeyInfo().missingPermissions
            if !missing.isEmpty { throw ValidationError.missingPermissions(missing) }
        } catch ImmichError.notFound {
            // Servers too old to describe the key; the calls below still check it.
        }
        return try await client.currentUser().id
    }

    private func connectFinder(to profile: ServerProfile) async throws {
        let domain = Self.domain(for: profile)
        let wasEnabled = settings.isConnectionEnabled
        settings.isConnectionEnabled = true
        do {
            try await NSFileProviderManager.add(domain)
        } catch {
            if !wasEnabled { settings.isConnectionEnabled = false }
            throw error
        }
        isConnected = true
        epoch += 1
        resetCacheState()
        applyNetwork()
        // Tell the extension to retry anything that failed for lack of a valid key.
        if let manager = NSFileProviderManager(for: domain) {
            try? await manager.signalErrorResolved(NSFileProviderError(.notAuthenticated))
            try? await manager.signalEnumerator(for: .workingSet)
        }
        startLoops()
        await checkHealth()
    }

    /// Removes Immich from Finder. The server, API key and local network settings stay.
    func disconnect() async {
        guard let profile else { return }
        guard !isBusy else {
            errorMessage = "Immount is busy. Try again in a moment."
            return
        }
        activity = .disconnecting
        defer { activity = nil }
        await removeFinderLocation(for: profile)
    }

    /// Disconnects and erases the server profile and API key from this Mac.
    func forgetServer() async {
        guard let profile else { return }
        guard !isBusy else {
            errorMessage = "Immount is busy. Try again in a moment."
            return
        }
        activity = .forgetting
        defer { activity = nil }
        await removeFinderLocation(for: profile)
        Keychain.deleteAPIKey(for: profile.id)
        settings.removeProfile()
        self.profile = nil
        hasSavedKey = false
        serverInput = ""
        apiKeyInput = ""
        localURLInput = ""
        localURLError = nil
        errorMessage = nil
        setLastRefresh(nil)
        status = .notConfigured
    }

    /// The extension removes the Finder location when it finds the app gone (see
    /// `FileProviderExtension.watchApp`). If that raced with this launch, add it back.
    private func restoreFinderLocationIfMissing(for profile: ServerProfile) async {
        guard let domains = try? await NSFileProviderManager.domains(),
              !domains.contains(where: { $0.identifier.rawValue == profile.id }),
              isConnected, self.profile?.id == profile.id else { return }
        log.info("Finder location missing; adding it back")
        do {
            try await NSFileProviderManager.add(Self.domain(for: profile))
        } catch {
            log.error("Adding the Finder location back failed: \(error, privacy: .public)")
        }
    }

    /// Quitting takes Immich out of Finder, so nothing of Immount keeps running: macOS stops
    /// the extension once its location is gone. The connection stays on and the saved
    /// listings stay, so the next launch adds the location back at once (`reconcile`).
    /// Downloaded originals go with the location; opening a file downloads it again.
    func removeFinderLocationForQuit() async {
        guard isConnected, let profile else { return }
        stopLoops()
        networkCheck?.cancel()
        settings.clearLocalNetwork()
        do {
            try await NSFileProviderManager.remove(Self.domain(for: profile), mode: .removeAll)
        } catch {
            log.error("Removing the Finder location on quit failed: \(error, privacy: .public)")
        }
        // Only once the removal returned: the notification makes the extension exit without
        // removing anything. If the removal hangs and the app quits on its timeout, the
        // extension finds the app gone and removes the location itself.
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                             CFNotificationName(SharedContainer.appQuitNotification as CFString),
                                             nil, nil, true)
    }

    private func removeFinderLocation(for profile: ServerProfile) async {
        stopLoops()
        epoch += 1
        resetCacheState()
        settings.isConnectionEnabled = false
        isConnected = false
        serverVersion = nil
        status = .disconnected
        networkCheck?.cancel()
        setLocal(false, unreachable: false)
        do {
            _ = try await NSFileProviderManager.remove(Self.domain(for: profile), mode: .removeAll)
        } catch {
            // Not registered, or already gone. The next launch's cleanup retries otherwise.
            log.error("Removing the Finder location failed: \(error, privacy: .public)")
        }
        // The listing cache describes a Finder copy that no longer exists.
        try? FileManager.default.removeItem(at: SharedContainer.stateDirectory(for: profile.id))
    }

    // MARK: Health

    /// Asks the server whether the key still works, without showing anything about the user.
    func checkHealth() async {
        guard !Task.isCancelled, !isAsleep else { return }
        while let request = healthRequest {
            await request.task.value
            guard !Task.isCancelled, !isAsleep else { return }
            if request.epoch == epoch, request.route == healthRouteGeneration, !request.task.isCancelled { return }
            if healthRequest?.id == request.id { healthRequest = nil }
        }
        let id = UUID()
        let task = Task { [weak self] in
            guard let self else { return }
            await self.performHealthCheck()
        }
        healthRequest = (id, epoch, healthRouteGeneration, task)
        defer { if healthRequest?.id == id { healthRequest = nil } }
        await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
    }

    private func performHealthCheck() async {
        guard !Task.isCancelled, !isAsleep else { return }
        guard let profile else { status = .notConfigured; return }
        guard isConnected else { status = .disconnected; return }
        let checkedAt = Date.now
        lastHealthCheckAt = checkedAt
        var completed = false
        let started = epoch
        let route = healthRouteGeneration
        let previous = status
        if previous.needsAttention || previous == .disconnected || previous == .notConfigured { status = .checking }
        func isCurrent() -> Bool {
            started == epoch && route == healthRouteGeneration && isConnected && self.profile?.id == profile.id
        }
        defer {
            if !completed {
                if lastHealthCheckAt == checkedAt { lastHealthCheckAt = nil }
                if isCurrent(), status == .checking { status = previous }
            }
        }

        var next: ConnectionStatus
        do {
            let client = try provider.connection().client
            let missing = try await client.apiKeyInfo().missingPermissions
            let version = try? await client.serverVersion().description
            guard isCurrent(), !Task.isCancelled else { return }
            serverVersion = version
            next = missing.isEmpty ? .connected(local: isOnLocalNetwork) : .missingPermissions(missing)
        } catch ConnectionProvider.Failure.keyMissing {
            next = .keyMissing
            hasSavedKey = false
        } catch ImmichError.unauthorized {
            next = .keyRejected
        } catch ImmichError.notFound {
            // Old servers without api-keys/me.
            next = .connected(local: isOnLocalNetwork)
        } catch let error as URLError where error.code == .cancelled {
            return // Replaced by a newer check.
        } catch is CancellationError {
            return
        } catch let error as URLError {
            log.error("Health check failed: \(error, privacy: .public)")
            next = .unreachable
        } catch ImmichError.http(let status, _) where status >= 500 {
            next = .unreachable
        } catch {
            // Redirects, unreadable answers and the like: retrying will not help.
            log.error("Health check failed: \(error, privacy: .public)")
            next = .failed(Self.describe(error))
        }
        guard isCurrent(), !Task.isCancelled else { return }
        status = next
        completed = true
        if next.needsAttention { healthFailures = min(5, healthFailures + 1) } else { healthFailures = 0 }

        if case .connected = next, let manager = NSFileProviderManager(for: Self.domain(for: profile)) {
            // Let the extension retry what failed while the server was down or the key was bad.
            if previous != next {
                try? await manager.signalErrorResolved(NSFileProviderError(.notAuthenticated))
            }
            try? await manager.signalErrorResolved(NSFileProviderError(.serverUnreachable))
        }
    }

    private func scheduleHealthCheck() {
        healthCheck?.cancel()
        healthCheck = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled, let self, !self.isAsleep, self.isConnected, self.wifi.networkAvailable else { return }
            await self.checkHealth()
        }
    }

    // MARK: Local network

    /// Saves the local URL typed in the field. When the Mac is on one of the listed networks,
    /// the address is tested first.
    func commitLocalURL() async {
        guard let profile, activity != .savingLocalURL else { return }
        localURLError = nil
        let text = localURLInput.trimmingCharacters(in: .whitespacesAndNewlines)
        var url: URL?
        if !text.isEmpty {
            guard let parsed = ImmichClient.normalizeServerURL(text) else {
                localURLError = "Enter an address like http://192.168.1.10:2283"
                errorMessage = "The local URL was not saved: \(localURLError!)"
                return
            }
            url = parsed
        }
        guard url != profile.localServerURL else {
            // Back to the saved value: nothing to save, and an earlier failure no longer applies.
            localURLInput = url?.absoluteString ?? ""
            if errorMessage?.hasPrefix("The local URL was not saved") == true { errorMessage = nil }
            return
        }

        if let url, profile.localNetworks.contains(wifi.ssid ?? "") {
            let ownsActivity = activity == nil
            if ownsActivity { activity = .savingLocalURL }
            defer { if ownsActivity { activity = nil } }
            do {
                try await ImmichClient(serverURL: url, apiKey: "").ping(timeout: 5)
            } catch {
                localURLError = "Could not reach this address from here."
                errorMessage = "The local URL was not saved: Immount could not reach \(url.absoluteString)."
                return
            }
        }

        // Apply the change to the profile as it is now, not as it was before the test.
        guard var current = self.profile, current.id == profile.id else { return }
        current.localServerURL = url
        saveProfile(current)
        localURLInput = url?.absoluteString ?? ""
    }

    /// Shows the saved local URL again, unless a draft failed to save: that one stays, with
    /// its error, so it can be fixed.
    func resetLocalURLDraft() {
        guard localURLError == nil else { return }
        localURLInput = profile?.localServerURL?.absoluteString ?? ""
    }

    func addLocalNetwork(_ name: String) {
        let name = name.trimmingCharacters(in: .whitespaces)
        guard var profile, !name.isEmpty, !profile.localNetworks.contains(name) else { return }
        profile.localNetworks.append(name)
        saveProfile(profile)
        if wifi.isUndetermined { wifi.requestAuthorization() }
    }

    func removeLocalNetwork(_ name: String) {
        guard var profile else { return }
        profile.localNetworks.removeAll { $0 == name }
        saveProfile(profile)
    }

    private func saveProfile(_ updated: ServerProfile) {
        let endpointChanged = profile?.serverURL != updated.serverURL || profile?.localServerURL != updated.localServerURL
        settings.saveProfile(updated)
        profile = updated
        if endpointChanged { invalidateHealthRoute() }
        applyNetwork()
        if endpointChanged, isConnected { scheduleHealthCheck() }
    }

    /// Decides between the local and remote address for the current Wi-Fi network. The local
    /// URL is used only after it answers, so a listed network with the server down or a
    /// same-named network elsewhere falls back to the server URL.
    private func applyNetwork() {
        networkCheck?.cancel()
        guard !isAsleep, wifi.networkAvailable, isConnected, let profile, profile.isLocal(ssid: wifi.ssid), let localURL = profile.localServerURL else {
            setLocal(false, unreachable: false)
            return
        }
        let ssid = wifi.ssid
        networkCheck = Task { [weak self] in
            let reachable = (try? await ImmichClient(serverURL: localURL, apiKey: "").ping(timeout: 3)) != nil
            // Confirm only if nothing changed while waiting.
            guard let self, !Task.isCancelled, !isAsleep, isConnected, wifi.ssid == ssid,
                  self.profile?.localServerURL == localURL else { return }
            setLocal(reachable, unreachable: !reachable)
        }
    }

    private func setLocal(_ local: Bool, unreachable: Bool) {
        if local { settings.confirmLocalNetwork() } else { settings.clearLocalNetwork() }
        let changed = local != isOnLocalNetwork
        isOnLocalNetwork = local
        localURLUnreachable = unreachable
        if case .connected = status { status = .connected(local: local) }
        if changed, isConnected {
            invalidateHealthRoute()
            log.info("Switched to the \(local ? "local" : "remote", privacy: .public) server address")
            scheduleHealthCheck()
        }
    }

    private func invalidateHealthRoute() {
        healthRouteGeneration = UUID()
        healthRequest?.task.cancel()
        lastHealthCheckAt = nil
    }

    // MARK: Finder

    func showInFinder() async {
        guard isConnected, let manager = manager() else { return }
        do {
            // The URL is security-scoped: without access, the sandbox stops Finder from opening it.
            let url = try await manager.getUserVisibleURL(for: .rootContainer)
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }
            try await NSWorkspace.shared.open(url, configuration: NSWorkspace.OpenConfiguration())
        } catch {
            errorMessage = "Could not open Immich in Finder: \(error.localizedDescription)"
        }
    }

    /// Manual checks request a full reconciliation. Automatic checks let the extension
    /// choose inexpensive indexes and folders due for reconciliation.
    func refresh(userInitiated: Bool = true) async {
        guard !Task.isCancelled, !isAsleep, isConnected, !isBusy, let profile else { return }
        let started = epoch
        let ownsActivity = userInitiated
        if ownsActivity { activity = .refreshing }
        defer {
            if ownsActivity, activity == .refreshing { activity = nil }
            if userInitiated, started == epoch, isConnected, self.profile?.id == profile.id {
                consumeRefreshOutcome(profileID: profile.id)
                // A manual recovery must replace an automatic sleep based on older failures.
                restartAutomaticRefresh()
            }
        }

        // A submitted native signal is not cancellable. Drain it before another signal,
        // even when the automatic loop that submitted it has since been replaced.
        if let signal = refreshSignal {
            _ = try? await signal.task.value
            guard !Task.isCancelled, started == epoch, isConnected else { return }
            if !userInitiated { return }
            if refreshSignal?.id == signal.id { refreshSignal = nil }
        }
        guard let manager = manager() else { recordAutomaticFailure(); return }
        if userInitiated {
            automaticFailures = 0
            healthFailures = 0
            _ = settings.requestFullRefresh(profileID: profile.id)
            wifi.update()
        }
        lastAutomaticAttempt = .now
        let id = UUID()
        let task = Task { try await manager.signalEnumerator(for: .workingSet) }
        refreshSignal = (id, task)
        defer { if refreshSignal?.id == id { refreshSignal = nil } }
        do {
            try await task.value
            guard !Task.isCancelled, started == epoch, isConnected, self.profile?.id == profile.id else { return }
        } catch {
            guard !Task.isCancelled, started == epoch, isConnected else { return }
            recordAutomaticFailure()
            log.error("Refresh failed: \(error, privacy: .public)")
            await restoreFinderLocationIfMissing(for: profile)
        }
        if userInitiated { await checkHealth() }
    }

    private func setLastRefresh(_ date: Date?) {
        lastRefresh = date
        UserDefaults.standard.set(date, forKey: "lastRefresh")
    }

    private func startLoops(reset: Bool = true, promptly: Bool = false) {
        if reset {
            automaticFailures = 0
            healthFailures = 0
            lastRefreshDuration = 0
            lastRefreshOutcomeAt = profile.flatMap { settings.refreshOutcome(profileID: $0.id)?.completedAt }
            lastAutomaticAttempt = .now
            lastHealthCheckAt = nil
        }
        restartAutomaticRefresh(promptly: promptly)
        startAlbumWatch()
        leaseLoop?.cancel()
        guard isConnected, !isAsleep else { return }
        leaseLoop = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: Self.networkInterval) } catch { return }
                guard let self, !Task.isCancelled, !self.isAsleep, self.isConnected else { return }
                self.wifi.update()
            }
        }
    }

    private var refreshConditions: RefreshPolicy.Conditions {
        .init(isConnected: isConnected, isAsleep: isAsleep, networkAvailable: wifi.networkAvailable,
              lowPower: ProcessInfo.processInfo.isLowPowerModeEnabled,
              constrainedNetwork: wifi.isConstrained, expensiveNetwork: wifi.isExpensive)
    }

    private func automaticDelay() -> TimeInterval? {
        RefreshPolicy.delay(for: refreshConditions, consecutiveFailures: max(automaticFailures, healthFailures),
                            lastRefreshDuration: lastRefreshDuration, elapsed: secondsSinceAutomaticAttempt)
    }

    private func restartAutomaticRefresh(promptly: Bool = false) {
        automaticGeneration = UUID()
        refreshLoop?.cancel()
        refreshLoop = nil
        guard let profile, automaticDelay() != nil else { return }
        if promptly {
            lastAutomaticAttempt = ContinuousClock.now.advanced(by: .seconds(-RefreshPolicy.maximumInterval))
        }
        let generation = automaticGeneration
        let started = epoch
        refreshLoop = Task { [weak self] in
            var minimumDelay: TimeInterval = promptly ? 3 : 0
            while !Task.isCancelled {
                guard let self, self.automaticGeneration == generation, self.epoch == started,
                      self.profile?.id == profile.id else { return }
                self.consumeRefreshOutcome(profileID: profile.id)
                guard let delay = self.automaticDelay() else { return }
                do { try await Task.sleep(for: .seconds(max(minimumDelay, delay)), tolerance: .seconds(1)) } catch { return }
                minimumDelay = 0
                guard !Task.isCancelled, self.automaticGeneration == generation, self.epoch == started,
                      self.profile?.id == profile.id else { return }
                self.consumeRefreshOutcome(profileID: profile.id)
                guard let updatedDelay = self.automaticDelay() else { return }
                if updatedDelay > 0.1 { continue }
                // Busy operations get another normal interval without signaling in parallel.
                self.lastAutomaticAttempt = .now
                if self.isBusy { continue }
                await self.refresh(userInitiated: false)
                guard !Task.isCancelled, self.automaticGeneration == generation, self.epoch == started else { return }
                if self.lastHealthCheckAt.map({ Date.now.timeIntervalSince($0) >= RefreshPolicy.healthInterval }) ?? true {
                    await self.checkHealth()
                }
            }
        }
    }

    private func consumeRefreshOutcome(profileID: String) {
        guard let outcome = settings.refreshOutcome(profileID: profileID),
              lastRefreshOutcomeAt.map({ outcome.completedAt > $0 }) ?? true else { return }
        lastRefreshOutcomeAt = outcome.completedAt
        lastRefreshDuration = outcome.duration
        // A partial outcome means the server listed more folders than failed, and only asset
        // folders failed. The extension spaces out retries of those folders itself, so the
        // outcome must not slow the cadence or stop the album watch.
        if outcome.succeeded || outcome.partiallySucceeded {
            automaticFailures = 0
            albumWatchFailures = 0
            setLastRefresh(outcome.completedAt)
            // Successful server-backed enumeration is recovery evidence. Recheck health
            // once instead of showing an old unreachable status for another ten minutes.
            if case .unreachable = status { scheduleHealthCheck() }
        } else {
            recordAutomaticFailure()
        }
    }

    /// The extension finished a check. The shared defaults may take a moment to show it in
    /// this process, so look once more shortly after if nothing new is there yet.
    private func refreshOutcomeArrived(retry: Bool = true) {
        guard let profile, isConnected else { return }
        let before = lastRefreshOutcomeAt
        consumeRefreshOutcome(profileID: profile.id)
        guard retry, lastRefreshOutcomeAt == before else { return }
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            self?.refreshOutcomeArrived(retry: false)
        }
    }

    private func recordAutomaticFailure() {
        automaticFailures = min(5, automaticFailures + 1)
    }

    private func stopLoops() {
        automaticGeneration = UUID()
        refreshLoop?.cancel()
        refreshLoop = nil
        leaseLoop?.cancel()
        leaseLoop = nil
        albumWatchLoop?.cancel()
        albumWatchLoop = nil
        watchedAlbums = nil
        healthCheck?.cancel()
        healthRequest?.task.cancel()
    }

    // MARK: Album watch

    /// Between automatic checks, looks at the album list alone (usually answered with "not
    /// modified") and asks for a check as soon as an album changes. See `AlbumWatchPolicy`.
    private func startAlbumWatch() {
        albumWatchLoop?.cancel()
        watchedAlbums = nil
        albumWatchFailures = 0
        guard isConnected, !isAsleep else { return }
        albumWatchLoop = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(AlbumWatchPolicy.interval), tolerance: .seconds(1)) } catch { return }
                guard let self, !Task.isCancelled else { return }
                await self.watchAlbums()
            }
        }
    }

    private var albumWatchIsActive: Bool {
        guard case .connected = status else { return false }
        return AlbumWatchPolicy.isActive(
            conditions: refreshConditions, onBattery: SystemActivity.isOnBattery, idleTime: SystemActivity.idleTime,
            consecutiveFailures: max(albumWatchFailures, automaticFailures)
        )
    }

    private func watchAlbums() async {
        // While paused, the regular checks keep Finder current; start from a fresh list later.
        guard albumWatchIsActive, let profile else { watchedAlbums = nil; return }
        let started = epoch
        let albums: [ImmichAlbum]
        do {
            albums = try await provider.connection().client.albums()
        } catch {
            guard !Task.isCancelled, started == epoch else { return }
            // Pause until a regular check succeeds, rather than retrying a failing server every few seconds.
            albumWatchFailures += 1
            watchedAlbums = nil
            return
        }
        guard !Task.isCancelled, started == epoch, isConnected, self.profile?.id == profile.id else { return }
        guard let previous = watchedAlbums, previous.epoch == started else {
            watchedAlbums = (started, albums)
            return
        }
        guard AlbumWatchPolicy.changed(from: previous.albums, to: albums) else { return }
        // A check already on its way may have started before the change. Keep the old list,
        // so the change is seen again next time and gets its own check.
        guard refreshSignal == nil, !isBusy,
              AlbumWatchPolicy.canRequestCheck(sinceLastCheck: secondsSinceAutomaticAttempt,
                                               lastRefreshDuration: lastRefreshDuration) else { return }
        watchedAlbums = (started, albums)
        log.info("Album list changed; asking Finder to check now")
        await refresh(userInitiated: false)
    }

    private var secondsSinceAutomaticAttempt: TimeInterval? {
        lastAutomaticAttempt.map { instant in
            let parts = instant.duration(to: .now).components
            return Double(parts.seconds) + Double(parts.attoseconds) / 1e18
        }
    }

    private func manager() -> NSFileProviderManager? {
        profile.flatMap { NSFileProviderManager(for: Self.domain(for: $0)) }
    }

    private static func domain(for profile: ServerProfile) -> NSFileProviderDomain {
        NSFileProviderDomain(identifier: NSFileProviderDomainIdentifier(profile.id), displayName: "Immich")
    }

    // MARK: Downloaded files

    /// How often the General pane checks the downloaded files when nothing else asks for it.
    /// macOS can evict files on its own, e.g. when the disk runs low.
    static let cacheUsageInterval: Duration = .seconds(5 * 60)
    /// How often the General pane looks for downloads Immount finished since its last check.
    static let cacheDownloadCheckInterval: Duration = .seconds(15)
    /// The shortest time between checks prompted by downloads, so a long batch of downloads
    /// does not keep fileproviderd busy answering one check after another.
    static let cacheDownloadRescanDelay: Duration = .seconds(60)

    /// Keeps the cache size current while the General pane shows it. A check costs a File
    /// Provider call per downloaded file, so it runs when the pane appears, after the
    /// connection changes, after a clear that left the size unknown, after Immount downloads
    /// originals (counted only while statistics are collected) and otherwise every few minutes.
    func monitorCacheUsage() async {
        guard let profile else { return }
        let downloads = DownloadStatisticsStore.forProfile(profile.id)
        var lastCheck: (epoch: Int, clears: Int, completedDownloads: Int64, at: ContinuousClock.Instant)?
        var completed: Int64 = 0
        var nextRead = ContinuousClock.now
        // Wakes every second: a connection change clears the size, which should come back
        // right away, and a check skipped while another change runs is retried soon. Only
        // the download count, which reads a file, waits for its own interval.
        while !Task.isCancelled {
            if nextRead <= .now {
                completed = await Task.detached(priority: .utility) { downloads.snapshot().completedDownloads }.value
                nextRead = .now + Self.cacheDownloadCheckInterval
                guard !Task.isCancelled else { return }
            }
            let isDue = lastCheck.map { last in
                let elapsed = last.at.duration(to: .now)
                return last.epoch != epoch || last.clears != unmeasuredCacheClears || elapsed >= Self.cacheUsageInterval
                    || (last.completedDownloads != completed && elapsed >= Self.cacheDownloadRescanDelay)
            } ?? true
            if isDue {
                let started = (epoch: epoch, clears: unmeasuredCacheClears)
                if await refreshCacheUsage() { lastCheck = (started.epoch, started.clears, completed, .now) }
            }
            do { try await Task.sleep(for: .seconds(1), tolerance: .milliseconds(500)) } catch { return }
        }
    }

    /// Reads only File Provider's materialized items; enumerating the cache never fetches
    /// originals. Returns false if no check ran, so the caller can try again soon. A missing
    /// Finder location counts as a finished check: it reports an error instead.
    @discardableResult
    func refreshCacheUsage() async -> Bool {
        guard !Task.isCancelled, isConnected, let profile else { return false }
        // A check already running answers this request too, unless a change cancelled it.
        if let scan = cacheScan, !scan.task.isCancelled {
            _ = try? await scan.task.value
            return true
        }
        guard !isBusy, cacheScan == nil, cacheClear == nil else { return false }
        guard let manager = manager() else {
            cacheUsage = nil
            cacheScanError = "The Finder location is unavailable. Reconnect Immich to check downloaded files."
            return true
        }
        let started = epoch
        let id = UUID()
        let task = Task { try await FileProviderCache.usage(manager: manager) }
        cacheScan = (id, task)
        isCheckingCache = true
        cacheScanError = nil
        defer {
            if cacheScan?.id == id {
                cacheScan = nil
                isCheckingCache = false
            }
        }
        func isCurrent() -> Bool {
            epoch == started && isConnected && self.profile?.id == profile.id && cacheScan?.id == id
        }

        do {
            let usage = try await withTaskCancellationHandler {
                try await task.value
            } onCancel: {
                task.cancel()
            }
            guard isCurrent(), !Task.isCancelled, !task.isCancelled else { return true }
            cacheUsage = usage
        } catch {
            guard isCurrent(), !task.isCancelled, !Self.isCacheCancellation(error) else { return true }
            cacheUsage = nil
            cacheScanError = "Could not check downloaded files: \(error.localizedDescription)"
        }
        return true
    }

    /// Requests native per-item eviction. Busy state keeps disconnect/account changes from
    /// replacing the domain while macOS removes its downloaded copies.
    func clearCachedFiles() async {
        guard !Task.isCancelled, !isBusy, cacheClear == nil,
              isConnected, let profile else { return }
        dismissCacheConfirmation()
        guard let manager = manager() else {
            cacheClearError = "The Finder location is unavailable. Reconnect Immich before clearing downloaded files."
            return
        }
        let started = epoch
        activity = .clearingCache
        cacheClearError = nil
        cacheScanError = nil
        cacheUsage = nil
        defer { if activity == .clearingCache { activity = nil } }
        defer { if cacheUsage == nil { unmeasuredCacheClears += 1 } }
        func isCurrent() -> Bool {
            epoch == started && isConnected && self.profile?.id == profile.id
        }

        // A confirmation can remain open while the pane starts another scan. Drain it
        // before clearing so scans and eviction never enumerate the same domain together.
        if let scan = cacheScan {
            scan.task.cancel()
            _ = try? await scan.task.value
            if cacheScan?.id == scan.id {
                cacheScan = nil
                isCheckingCache = false
            }
        }
        guard isCurrent(), !Task.isCancelled else { return }

        let id = UUID()
        let task = Task { try await FileProviderCache.clear(manager: manager) }
        cacheClear = (id, task)
        defer { if cacheClear?.id == id { cacheClear = nil } }
        do {
            let result = try await withTaskCancellationHandler {
                try await task.value
            } onCancel: {
                task.cancel()
            }
            guard isCurrent(), cacheClear?.id == id, !Task.isCancelled else { return }
            cacheUsage = result.remaining
            let noun = result.attempted == 1 ? "file" : "files"
            let summary: String
            if result.attempted == 0 {
                summary = "No downloaded files to remove."
            } else if result.removed == 0, result.failed > 0 {
                summary = "Could not remove \(result.attempted.formatted()) cached \(noun)."
            } else if result.failed > 0 {
                summary = "Removed \(result.removed.formatted()) of \(result.attempted.formatted()) cached \(noun)."
            } else {
                let noun = result.removed == 1 ? "file" : "files"
                summary = "Removed \(result.removed.formatted()) cached \(noun)."
            }
            if result.failed > 0 {
                cacheClearError = summary + " " + Self.describeCacheFailures(result.failures)
            }
            if result.remaining == nil {
                cacheClearError = (cacheClearError ?? summary)
                    + " The remaining downloaded files could not be checked."
            }
            if cacheClearError == nil {
                showCacheConfirmation(title: result.attempted == 0 ? "Cache already empty" : "Cache cleared", detail: summary)
            }
        } catch {
            guard isCurrent(), cacheClear?.id == id, !Self.isCacheCancellation(error) else { return }
            cacheClearError = "Could not clear downloaded files: \(error.localizedDescription)"
        }
    }

    private func showCacheConfirmation(title: String, detail: String) {
        dismissCacheConfirmation()
        let confirmation = CacheConfirmation(title: title, detail: detail)
        cacheConfirmation = confirmation
        // Model-owned so closing Settings or changing panes cannot restart the timeout.
        cacheConfirmationExpiry = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(4)) } catch { return }
            guard !Task.isCancelled, self?.cacheConfirmation?.id == confirmation.id else { return }
            self?.cacheConfirmation = nil
            self?.cacheConfirmationExpiry = nil
        }
    }

    private func dismissCacheConfirmation() {
        cacheConfirmationExpiry?.cancel()
        cacheConfirmationExpiry = nil
        cacheConfirmation = nil
    }

    func dismissCacheError() {
        cacheScanError = nil
        cacheClearError = nil
    }

    private static func describeCacheFailures(_ failures: [FileProviderCache.EvictionFailureSummary]) -> String {
        guard !failures.isEmpty else {
            return "macOS did not provide a reason for the failure. Try Remove Download in Finder."
        }
        return failures.map { failure in
            let files = "\(failure.count.formatted()) \(failure.count == 1 ? "file" : "files")"
            switch failure.reason {
            case .unsyncedChanges:
                return "\(files) \(failure.count == 1 ? "has" : "have") unsynced changes. Let Finder finish syncing before trying again."
            case .inUse:
                return "\(files) \(failure.count == 1 ? "is" : "are") in use. Close apps using \(failure.count == 1 ? "it" : "them"), then try again."
            case .notEvictable:
                return "macOS marked \(files) as not removable. Check Keep Downloaded in Finder; provider restrictions can also prevent removal."
            case .permissionDenied:
                return "macOS denied permission to remove \(files). Try Remove Download in Finder."
            case .unsupported:
                return "macOS reports that removing \(files) is unsupported. Try Remove Download in Finder."
            case .other:
                let codes = failure.diagnostics.prefix(3).map { "\($0.domain) (\($0.code))" }.joined(separator: ", ")
                let details = codes.isEmpty ? "" : " Error: \(codes)."
                return "macOS could not remove \(files).\(details) Try Remove Download in Finder."
            }
        }.joined(separator: " ")
    }

    private func resetCacheState() {
        // Keep task handles until their awaiters drain: a new scope must not overlap a
        // cancelled enumeration that has not returned yet.
        cacheScan?.task.cancel()
        cacheClear?.task.cancel()
        cacheUsage = nil
        isCheckingCache = false
        dismissCacheConfirmation()
        cacheScanError = nil
        cacheClearError = nil
    }

    private static func isCacheCancellation(_ error: Error) -> Bool {
        if Task.isCancelled || error is CancellationError { return true }
        let error = error as NSError
        return (error.domain == NSURLErrorDomain && error.code == NSURLErrorCancelled)
            || (error.domain == NSCocoaErrorDomain && error.code == NSUserCancelledError)
    }

    // MARK: Statistics

    func setStatisticsEnabled(_ enabled: Bool) {
        settings.statisticsEnabled = enabled
        statisticsEnabled = settings.statisticsEnabled
    }

    // MARK: Login item

    var launchAtLogin: Bool {
        loginItemStatus == .enabled || loginItemStatus == .requiresApproval
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            errorMessage = "Could not change the login item: \(error.localizedDescription)"
        }
        loginItemStatus = SMAppService.mainApp.status
    }

    // MARK: Errors

    enum ValidationError: Error {
        case missingPermissions([String])
    }

    static func describe(_ error: Error) -> String {
        switch error {
        case ValidationError.missingPermissions(let missing):
            "The API key is missing these permissions: \(missing.joined(separator: ", ")). Edit the key in Immich or create a new one."
        case ImmichError.unauthorized:
            "Immich did not accept this API key. Check that you copied all of it and that it was not deleted."
        case let error as URLError where error.isUnreachable:
            "Could not reach the server. Check the address and your connection."
        case let error as LocalizedError where error.errorDescription != nil:
            error.errorDescription!
        default:
            error.localizedDescription
        }
    }
}

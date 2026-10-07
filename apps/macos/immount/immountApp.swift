import ImmountKit
import SwiftUI

/// App-only preferences, in the standard UserDefaults.
enum Preferences {
    static let showMenuBarIcon = "showMenuBarIcon"
    static let showDockIcon = "showDockIcon"
}

@main
struct immountApp: App {
    @NSApplicationDelegateAdaptor private var appDelegate: AppDelegate
    @State private var model = AppModel()
    @State private var updater = AppUpdater()
    @State private var menuClock = MenuClock()
    @AppStorage(Preferences.showMenuBarIcon) private var showMenuBarIcon = true
    @AppStorage(Preferences.showDockIcon) private var showDockIcon = true
    @Environment(\.openSettings) private var openSettings

    var body: some Scene {
        let _ = connectDelegate()

        // Settings opens only on request, keeping connected login launches quiet on
        // every supported macOS version without relying on newer scene modifiers.
        Settings {
            SettingsView(model: model)
                .environment(updater)
                .background(SettingsWindowRegistration())
        }
        .defaultSize(width: 715, height: 640)
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(after: .appInfo) {
                if updater.isAvailable {
                    Button("Check for Updates…") { updater.checkForUpdates() }
                        .disabled(!updater.canCheckForUpdates)
                }
            }
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") { SettingsWindow.show(openSettings) }
                    .keyboardShortcut(",")
            }
        }
        .onChange(of: showDockIcon) { _, visible in SettingsWindow.applyDockIcon(visible) }

        MenuBarExtra(isInserted: $showMenuBarIcon) {
            MenuContent(model: model, updater: updater, clock: menuClock)
        } label: {
            // The image(named:) initializer would announce the asset name to VoiceOver.
            Image("MenuBarIcon").accessibilityLabel("Immount")
        }
    }

    /// Lets the delegate open the window when no SwiftUI view exists, e.g. a reopen with the
    /// window closed and the menu bar icon hidden.
    private func connectDelegate() {
        let openSettings = openSettings
        appDelegate.isConnected = model.isConnected
        appDelegate.showSettings = { SettingsWindow.show(openSettings) }
        appDelegate.prepareForQuit = { [model] in await model.removeFinderLocationForQuit() }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    var showSettings: (() -> Void)?
    var prepareForQuit: (() async -> Void)?
    var isConnected = false
    private var isQuitting = false
    private var hasAllowedTermination = false

    /// How long quitting may wait for the Finder location to go away, e.g. during logout.
    private static let quitTimeout: Duration = .seconds(5)

    func applicationWillFinishLaunching(_ notification: Notification) {
        // Before any window exists, so the Dock icon does not flash when it is hidden.
        Self.restoreActivationPolicy()
    }

    /// Connected login launches stay quiet. A launch by hand or an unconfigured app
    /// opens Settings explicitly.
    func applicationDidFinishLaunching(_ notification: Notification) {
        let event = NSAppleEventManager.shared().currentAppleEvent
        let isLoginLaunch = event?.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem
        guard !isLoginLaunch || !isConnected else { return }
        DispatchQueue.main.async { self.showSettings?() }
    }

    /// Opening the app again (Dock, Finder, Spotlight) shows Settings.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // Reopening from Finder or Spotlight makes the app regular before this call, which would
        // keep a hidden Dock icon after the window closes.
        Self.restoreActivationPolicy()
        // Accessory apps also need activation when their window is visible behind another app.
        showSettings?()
        return false
    }

    /// A real quit (menu, Command-Q, Dock, logout) removes Immich from Finder first, so no
    /// part of Immount stays alive. Closing the window does not quit.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let prepareForQuit else { return .terminateNow }
        guard !isQuitting else { return .terminateLater }
        isQuitting = true
        // The removal is an Objective-C call that ignores cancellation, so the timeout cannot
        // stop it. Whichever finishes first lets the app quit, even with the removal still running.
        Task { @MainActor in
            await prepareForQuit()
            self.allowTermination()
        }
        Task { @MainActor in
            try? await Task.sleep(for: Self.quitTimeout)
            self.allowTermination()
        }
        return .terminateLater
    }

    /// AppKit expects exactly one reply to `.terminateLater`.
    private func allowTermination() {
        guard !hasAllowedTermination else { return }
        hasAllowedTermination = true
        NSApp.reply(toApplicationShouldTerminate: true)
    }

    /// Keep refreshes running after the window closes, even with both icons hidden.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    /// Applies the Dock icon preference, without deactivating the app when it already matches.
    private static func restoreActivationPolicy() {
        let showDock = UserDefaults.standard.object(forKey: Preferences.showDockIcon) as? Bool ?? true
        let policy: NSApplication.ActivationPolicy = showDock ? .regular : .accessory
        guard NSApp.activationPolicy() != policy else { return }
        NSApp.setActivationPolicy(policy)
    }
}

enum SettingsWindow {
    fileprivate static weak var registeredWindow: NSWindow?

    static func show(_ openSettings: OpenSettingsAction) {
        openSettings()
        // Let SwiftUI create or restore the window before activating an accessory app.
        DispatchQueue.main.async { bringToFront() }
    }

    static func bringToFront() {
        // Without a Dock icon the app is not active; plain activate() is not honored then.
        NSApp.activate(ignoringOtherApps: true)
        let window = NSApp.windows.first { isSettingsWindow($0) }
        if window?.isMiniaturized == true { window?.deminiaturize(nil) }
        window?.makeKeyAndOrderFront(nil)
    }

    static func isSettingsWindow(_ window: NSWindow?) -> Bool {
        guard let window else { return false }
        return window === registeredWindow
    }

    static func applyDockIcon(_ visible: Bool) {
        let policy: NSApplication.ActivationPolicy = visible ? .regular : .accessory
        guard NSApp.activationPolicy() != policy else { return }
        // Changing the policy deactivates the app; bring Settings back afterwards.
        NSApp.setActivationPolicy(policy)
        DispatchQueue.main.async { bringToFront() }
    }
}

/// Adjusts the Settings window from inside its content (no AppKit restoration, normal window
/// chrome) without changing SwiftUI's window identifier or replacing its delegate. The weak
/// reference also identifies visibility notifications from a Settings scene, whose identifier
/// belongs to SwiftUI.
private struct SettingsWindowRegistration: NSViewRepresentable {
    func makeNSView(context: Context) -> WindowRegistrationView { WindowRegistrationView() }
    func updateNSView(_ nsView: WindowRegistrationView, context: Context) {}

    final class WindowRegistrationView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            window.isRestorable = false
            // Settings scenes otherwise use preference-window chrome and omit the
            // minimize control. Keep the normal, resizable library-settings window.
            window.styleMask.formUnion([.miniaturizable, .resizable, .fullSizeContentView])
            window.toolbarStyle = .unified
            window.collectionBehavior.subtract([.fullScreenNone, .fullScreenAuxiliary])
            window.collectionBehavior.insert(.fullScreenPrimary)
            SettingsWindow.registeredWindow = window
        }
    }
}

/// The time, refreshed when a menu opens and every second while it stays open, so relative
/// times in the menu bar menu are current. Menus cannot use `TimelineView`, and a timer that
/// runs while every menu is closed would only rebuild them for nothing. The app owns the only
/// instance: its observers are never removed, so more instances would pile them up.
@Observable
private final class MenuClock {
    private(set) var now = Date.now
    @ObservationIgnored private var timer: Timer?

    init() {
        let center = NotificationCenter.default
        center.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.start() }
        }
        center.addObserver(forName: NSMenu.didEndTrackingNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.stop() }
        }
    }

    private func start() {
        now = .now
        guard timer == nil else { return }
        // Common modes: menus run the run loop in event tracking mode while open.
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.now = .now }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func stop() {
        timer?.invalidate()
        timer = nil
    }
}

/// The menu bar menu. Shows the connection state, never who is signed in.
private struct MenuContent: View {
    let model: AppModel
    let updater: AppUpdater
    let clock: MenuClock
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Text(model.status.title)
        if model.isConnected {
            Button("Show in Finder") { Task { await model.showInFinder() } }
            Button("Refresh Now") { Task { await model.refresh() } }
                .disabled(model.isBusy)
            if let lastRefresh = model.lastRefresh {
                Text("Last refresh: \(RelativeTimeText.describe(lastRefresh, now: clock.now).localizedLowercase)")
            }
        } else if model.profile != nil, model.hasSavedKey {
            Button("Connect") { Task { await model.reconnect() } }
                .disabled(model.isBusy)
        }
        Divider()
        if let version = updater.pendingVersion {
            Button("Update to \(version) Available…") { updater.checkForUpdates() }
        } else if updater.isAvailable {
            Button("Check for Updates…") { updater.checkForUpdates() }
                .disabled(!updater.canCheckForUpdates)
        }
        Button("Settings…") { SettingsWindow.show(openSettings) }
            .keyboardShortcut(",")
        Button("Quit Immount") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}

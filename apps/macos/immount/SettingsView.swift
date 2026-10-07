import AppKit
import Combine
import ImmountKit
import ServiceManagement
import SwiftUI

enum SettingsPane: String, CaseIterable, Identifiable, Hashable {
    case general, localNetwork, statistics, about

    var id: Self { self }

    var title: String {
        switch self {
        case .general: "General"
        case .localNetwork: "Local Network"
        case .statistics: "Statistics"
        case .about: "About"
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape.fill"
        case .localNetwork: "wifi"
        case .statistics: "chart.xyaxis.line"
        case .about: "info"
        }
    }

    var tint: Color {
        switch self {
        case .general: .gray
        case .localNetwork: .green
        case .statistics: .blue
        case .about: .purple
        }
    }

    /// The words on the pane, so searching finds a pane by its settings.
    private var keywords: [String] {
        switch self {
        case .general: ["Cache", "Cached downloads", "Storage", "Clear cache", "Free space", "Background", "Hidden", "Launch at login", "Open at login", "Login items", "Visibility", "Menu bar icon", "Dock icon", "Finder", "Library", "Albums", "Favorites", "People", "Tags", "Timeline", "Show in Finder", "Last refresh", "Refresh now", "Server", "Connection", "Status", "Server URL", "Address", "Details", "API key", "Keychain", "Permissions", "Immich version", "Disconnect", "Connect", "Forget this server", "Check again"]
        case .localNetwork: ["Local address", "Local URL", "Now using", "Wi-Fi networks", "Network name", "Current network", "Location Services", "Home"]
        case .statistics: ["Enable", "Disable", "Collect", "Server", "Speed", "Download", "Transfer", "Response time", "Latency", "Photos", "Videos", "Storage", "Disk", "Library", "Activity"]
        case .about: ["Version", "Updates", "Check for updates", "Automatic updates", "Download updates", "Install", "Immich", "Immich API", "Not affiliated"]
        }
    }

    /// Every word of the query must appear somewhere on the pane.
    func matches(_ query: String) -> Bool {
        let words = query.split(whereSeparator: \.isWhitespace)
        guard !words.isEmpty else { return true }
        let text = ([title] + keywords).joined(separator: " ")
        return words.allSatisfy { text.localizedStandardContains($0) }
    }
}

/// Back and forward history for the panes, like System Settings.
@Observable
final class SettingsNavigator {
    private(set) var history: [SettingsPane]
    private(set) var index = 0

    init(start: SettingsPane) {
        history = [start]
    }

    var current: SettingsPane { history[index] }
    var canGoBack: Bool { index > 0 }
    var canGoForward: Bool { index < history.count - 1 }

    func show(_ pane: SettingsPane) {
        guard pane != current else { return }
        history.removeSubrange((index + 1)...)
        history.append(pane)
        index += 1
    }

    func back() { if canGoBack { index -= 1 } }
    func forward() { if canGoForward { index += 1 } }
}

struct SettingsView: View {
    @Bindable var model: AppModel
    @State private var navigator: SettingsNavigator
    @State private var query = ""
    @State private var statistics = StatisticsModel()
    @State private var isWindowVisible = true

    init(model: AppModel) {
        self.model = model
        _navigator = State(initialValue: SettingsNavigator(start: .general))
    }

    private var selection: Binding<SettingsPane?> {
        Binding(get: { navigator.current }, set: { if let pane = $0 { navigator.show(pane) } })
    }

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 215, ideal: 215, max: 215)
                // Like System Settings, the sidebar stays: bringing a collapsed one back makes
                // AppKit and SwiftUI rebuild and lay it out on every frame, which stutters.
                .toolbar(removing: .sidebarToggle)
        } detail: {
            detail
                .navigationTitle(navigator.current.title)
        }
        .searchable(text: $query, placement: .sidebar, prompt: "Search settings")
        .toolbar {
            ToolbarItem(placement: .navigation) {
                ControlGroup {
                    Button("Back", systemImage: "chevron.left") { navigator.back() }
                        .disabled(!navigator.canGoBack)
                        .keyboardShortcut("[", modifiers: .command)
                    Button("Forward", systemImage: "chevron.right") { navigator.forward() }
                        .disabled(!navigator.canGoForward)
                        .keyboardShortcut("]", modifiers: .command)
                }
                .controlGroupStyle(.navigation)
            }
        }
        .frame(minWidth: 680, minHeight: 460)
        .onChange(of: navigator.current) { model.errorMessage = nil }
    }

    private var sidebar: some View {
        List(selection: selection) {
            if query.isEmpty {
                // The connection itself lives in General.
                Button { navigator.show(.general) } label: { AppIdentityHeader(status: model.status) }
                    .buttonStyle(.plain)
                    .help("Show the connection in General.")
            }
            let main = [SettingsPane.general, .localNetwork, .statistics].filter { $0.matches(query) }
            if !main.isEmpty {
                Section {
                    ForEach(main) { pane in sidebarRow(pane) }
                }
            }
            if SettingsPane.about.matches(query) {
                Section { sidebarRow(.about) }
            }
        }
        .overlay {
            if !query.isEmpty, SettingsPane.allCases.allSatisfy({ !$0.matches(query) }) {
                ContentUnavailableView.search(text: query)
            }
        }
    }

    private func sidebarRow(_ pane: SettingsPane) -> some View {
        Label {
            Text(pane.title)
        } icon: {
            SettingsIcon(symbol: pane.symbol, tint: pane.tint)
        }
        .tag(pane)
    }

    @ViewBuilder
    private var detail: some View {
        Form {
            if let error = model.errorMessage {
                Section {
                    ErrorBanner(message: error) { model.errorMessage = nil }
                }
            }
            switch navigator.current {
            case .general: GeneralPane(model: model)
            case .localNetwork: LocalNetworkPane(model: model, navigator: navigator)
            case .statistics: StatisticsPane(model: model, navigator: navigator, statistics: statistics)
            case .about: AboutPane()
            }
        }
        .formStyle(.grouped)
        // Keep monitoring tied to the pane, not a scrolling section's appearance.
        .task(id: statisticsContext) {
            guard !Task.isCancelled else { return }
            if let context = statisticsContext {
                await statistics.monitor(context)
            } else {
                statistics.stop()
            }
        }
        .task(id: cacheContextID) {
            guard !Task.isCancelled, cacheContextID != nil else { return }
            await model.monitorCacheUsage()
        }
        .onChange(of: model.statisticsEnabled) { _, enabled in
            if !enabled { statistics.stop() }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.willCloseNotification)
            .merge(with: NotificationCenter.default.publisher(for: NSWindow.didMiniaturizeNotification))) { notification in
            if SettingsWindow.isSettingsWindow(notification.object as? NSWindow) {
                isWindowVisible = false
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)
            .merge(with: NotificationCenter.default.publisher(for: NSWindow.didDeminiaturizeNotification))) { notification in
            if SettingsWindow.isSettingsWindow(notification.object as? NSWindow) {
                isWindowVisible = true
            }
        }
    }

    private var cacheContextID: String? {
        guard navigator.current == .general, isWindowVisible, model.isConnected else { return nil }
        return model.profile?.id
    }

    private var statisticsContext: StatisticsContext? {
        guard navigator.current == .statistics, isWindowVisible, model.statisticsEnabled else { return nil }
        return StatisticsContext(profileID: model.profile?.id, serverURL: model.activeServerURL, isConnected: model.isConnected)
    }
}

// MARK: - General

private struct GeneralPane: View {
    @Bindable var model: AppModel
    @AppStorage(Preferences.showMenuBarIcon) private var showMenuBarIcon = true
    @AppStorage(Preferences.showDockIcon) private var showDockIcon = true

    var body: some View {
        Section {
            Toggle(isOn: Binding(get: { model.launchAtLogin }, set: { model.setLaunchAtLogin($0) })) {
                SettingLabel(
                    title: "Launch at login",
                    subtitle: model.loginItemStatus == .requiresApproval ? "Turn on Immount in Login Items to finish." : nil,
                    info: "Open Immount when you log in. Your library is in Finder only while Immount runs."
                )
            }
            .toggleStyle(.switch)
            if model.loginItemStatus == .requiresApproval {
                LabeledContent {
                    Button("Open Login Items") { SMAppService.openSystemSettingsLoginItems() }
                } label: {
                    SettingLabel(title: "Approval needed")
                }
            }
            LabeledContent {
                HStack(spacing: 16) {
                    Toggle("Menu bar icon", isOn: $showMenuBarIcon)
                        .help("Show Immount in the menu bar.")
                    Toggle("Dock icon", isOn: $showDockIcon)
                        .help("Show Immount in the Dock and the app switcher.")
                }
                .toggleStyle(.checkbox)
            } label: {
                SettingLabel(title: "Visibility", info: "Immount keeps running when you close this window, even with both icons hidden. Open Immount from Finder or Spotlight to return to Settings.")
            }
        } footer: {
            if !showMenuBarIcon && !showDockIcon {
                Text("Running in the background. Open Immount from Finder or Spotlight to return to Settings.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }

        ServerSection(model: model)

        Section {
            LabeledContent {
                Button("Show in Finder") { Task { await model.showInFinder() } }
            } label: {
                SettingLabel(title: "Library", subtitle: "Albums, Favorites, People, Tags and Timeline.")
            }
            LabeledContent {
                HStack {
                    if model.activity == .refreshing {
                        ProgressView().controlSize(.small)
                    } else if let lastRefresh = model.lastRefresh {
                        RelativeTimeText(date: lastRefresh)
                            .foregroundStyle(.secondary)
                    }
                    Button("Refresh Now") { Task { await model.refresh() } }
                        .disabled(model.isBusy)
                }
            } label: {
                SettingLabel(title: "Last refresh", info: "Checks for library changes about every 30 seconds. Checks slow down in Low Power Mode, on costly connections, or when the server is unavailable. Refresh Now checks every folder you’ve browsed.")
            }
        } header: {
            SectionHeader(title: "Finder", subtitle: "Your library appears in the Finder sidebar under Locations.")
        } footer: {
            if !model.isConnected {
                Text("Connect to your server to use these.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .disabled(!model.isConnected)

        CacheSection(model: model)
    }
}

// MARK: - Server

/// The server part of General: a form to connect, or the connection at a glance.
private struct ServerSection: View {
    @Bindable var model: AppModel
    @State private var showDetails = false

    var body: some View {
        if let profile = model.profile {
            Section {
                ConnectionCard(model: model, profile: profile) { showDetails = true }
            } header: {
                SectionHeader(title: "Server")
            }
            .sheet(isPresented: $showDetails) {
                ServerDetailsSheet(model: model, profile: profile)
            }
            if case .missingPermissions = model.status {
                PermissionsSection()
            }
        } else {
            connectForm
        }
    }

    @ViewBuilder
    private var connectForm: some View {
        Section {
            TextField(text: $model.serverInput, prompt: Text(verbatim: "https://photos.example.com")) {
                SettingLabel(title: "Server URL", info: "The address you use to open Immich in a browser.")
            }
            .textContentType(.URL)
            .autocorrectionDisabled()
            SecureField(text: $model.apiKeyInput, prompt: Text("Paste your key")) {
                SettingLabel(title: "API key", info: "Create one in Immich under Account Settings > API Keys.")
            }
        } header: {
            SectionHeader(title: "Connect to Immich", subtitle: "Immount only reads your library. It never changes anything on the server.")
        } footer: {
            HStack {
                if let url = apiKeysPage(for: model.serverInput) {
                    Button("Create a Key in Immich") { NSWorkspace.shared.open(url) }
                        .buttonStyle(.link)
                }
                Spacer()
                if model.activity == .connecting { ProgressView().controlSize(.small) }
                Button("Connect") { Task { await model.connect() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.isBusy)
            }
            .padding(.top, 4)
        }
        .onSubmit { Task { await model.connect() } }

        PermissionsSection()
    }
}

/// Where Immount connects right now and how that is going, with the one action that fits.
private struct ConnectionCard: View {
    let model: AppModel
    let profile: ServerProfile
    let showDetails: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            SettingsIcon(symbol: icon.symbol, tint: icon.tint, size: 36)
            VStack(alignment: .leading, spacing: 3) {
                Text(verbatim: host)
                    .font(.headline)
                    .textSelection(.enabled)
                    .help(url.absoluteString)
                HStack(spacing: 6) {
                    StatusDot(color: Color(nsColor: model.status.color))
                    Text(statusLine)
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)
                if let detail {
                    Text(detail)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
            if isWorking { ProgressView().controlSize(.small) }
            if model.status.needsAttention {
                Button("Check Again") { Task { await model.checkHealth() } }
                    .disabled(model.isBusy)
            } else if !model.isConnected, model.hasSavedKey {
                Button("Connect") { Task { await model.reconnect() } }
                    .disabled(model.isBusy)
            }
            Button("Details…", action: showDetails)
                .disabled(model.isBusy)
        }
        .padding(.vertical, 4)
    }

    private var url: URL { model.activeServerURL ?? profile.serverURL }

    private var host: String {
        let name = url.host(percentEncoded: false) ?? url.absoluteString
        return url.port.map { "\(name):\($0)" } ?? name
    }

    /// A house at home, a globe away from it; the status color while something is off.
    private var icon: (symbol: String, tint: Color) {
        switch model.status {
        case .connected(let local): local ? ("house.fill", .green) : ("globe", .blue)
        case .unreachable: ("server.rack", .orange)
        case .keyRejected, .keyMissing, .missingPermissions, .failed: ("server.rack", .red)
        default: ("server.rack", .gray)
        }
    }

    private var statusLine: String {
        var parts = [model.status.title]
        if model.isConnected, let version = model.serverVersion { parts.append("Immich \(version)") }
        return parts.joined(separator: " · ")
    }

    private var detail: String? {
        switch model.status {
        case .missingPermissions(let missing): "Missing: \(missing.joined(separator: ", "))"
        case .keyRejected: "Immich no longer accepts the saved key. Change it in Details."
        case .keyMissing: "The saved key is gone. Add it again in Details."
        case .unreachable: "Immount keeps trying in the background."
        case .failed(let message): message
        case .connected where model.localURLUnreachable: "The local URL did not answer, so Immount uses the server URL."
        default: nil
        }
    }

    private var isWorking: Bool {
        switch model.activity {
        case .connecting, .disconnecting, .forgetting: true
        default: model.status == .checking
        }
    }
}

/// "Local URL" or "Server URL", noting when the local URL did not answer.
private struct NowUsingLabel: View {
    let model: AppModel

    var body: some View {
        HStack(spacing: 6) {
            if model.activity == .savingLocalURL { ProgressView().controlSize(.small) }
            StatusDot(color: model.isOnLocalNetwork ? .green : (model.localURLUnreachable ? .orange : .secondary))
            Text(model.isOnLocalNetwork ? "Local URL" : "Server URL")
        }
        .help(model.localURLUnreachable ? "The local URL did not answer on this network, so Immount uses the server URL." : "")
    }
}

/// The Immich page where API keys are created, once the typed address parses.
private func apiKeysPage(for serverInput: String) -> URL? {
    ImmichClient.normalizeServerURL(serverInput).map { $0.appending(path: "user-settings").appending(queryItems: [URLQueryItem(name: "isOpen", value: "api-keys")]) }
}

private struct PermissionsSection: View {
    private static let purposes: [(String, String)] = [
        ("asset.read", "List photos and videos."),
        ("asset.view", "Show thumbnails in Finder."),
        ("asset.download", "Download originals when you open a file."),
        ("album.read", "List albums."),
        ("person.read", "List people."),
        ("tag.read", "List tags and their folders."),
        ("user.read", "Check which account the key belongs to."),
    ]

    var body: some View {
        Section {
            ForEach(Self.purposes, id: \.0) { permission, purpose in
                LabeledContent {
                    Text(purpose).foregroundStyle(.secondary)
                } label: {
                    Text(verbatim: permission).monospaced()
                }
            }
        } header: {
            SectionHeader(title: "API key permissions", subtitle: "Turn these on when you create the key, or choose all.")
        }
    }
}

/// Changes the server URL or API key, or disconnects and forgets the server. Edits work on
/// their own drafts, so cancelling leaves the saved settings and the pane untouched.
private struct ServerDetailsSheet: View {
    let model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var server: String
    @State private var key = ""
    @State private var error: String?
    @State private var isSaving = false
    @State private var confirmSwitch = false
    @State private var confirmDisconnect = false
    @State private var confirmForget = false

    init(model: AppModel, profile: ServerProfile) {
        self.model = model
        _server = State(initialValue: profile.serverURL.absoluteString)
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    TextField(text: $server, prompt: Text(verbatim: "https://photos.example.com")) {
                        SettingLabel(title: "Server URL")
                    }
                    .textContentType(.URL)
                    .autocorrectionDisabled()
                    SecureField(text: $key, prompt: Text("Keep the saved key")) {
                        SettingLabel(title: "API key", info: "Leave empty to keep the key saved in your Keychain. A different server needs its own key.")
                    }
                } header: {
                    SectionHeader(title: "Server", subtitle: "Immount checks the address and key before saving.")
                }
                .onSubmit { save(allowAccountSwitch: false) }
                if let error {
                    Section {
                        ErrorBanner(message: error) { self.error = nil }
                    }
                }
            }
            .formStyle(.grouped)

            HStack {
                if model.isConnected {
                    Button("Disconnect…") { confirmDisconnect = true }
                        .help("Remove Immich from Finder. The server and API key stay saved.")
                        .disabled(isSaving)
                        .confirmationDialog("Disconnect from Immich?", isPresented: $confirmDisconnect) {
                            Button("Disconnect", role: .destructive) {
                                dismiss()
                                Task { await model.disconnect() }
                            }
                        } message: {
                            Text("Immich disappears from Finder and downloaded copies are removed. You can connect again at any time.")
                        }
                }
                Button("Forget Server…", role: .destructive) { confirmForget = true }
                    .foregroundStyle(.red)
                    .help("Remove the server, API key and local network settings from this Mac.")
                    .disabled(isSaving)
                    .confirmationDialog("Forget this server?", isPresented: $confirmForget) {
                        Button("Forget", role: .destructive) {
                            dismiss()
                            Task { await model.forgetServer() }
                        }
                    } message: {
                        Text("Immount removes Immich from Finder and deletes the saved address, API key and local network settings from this Mac. Nothing changes on the server.")
                    }
                Spacer()
                if isSaving { ProgressView().controlSize(.small) }
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(isSaving)
                Button("Save") { save(allowAccountSwitch: false) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(isSaving)
            }
            .padding([.horizontal, .bottom], 20)
        }
        .frame(width: 520)
        .interactiveDismissDisabled(isSaving)
        .confirmationDialog("Switch to another Immich account?", isPresented: $confirmSwitch) {
            Button("Switch Account", role: .destructive) { save(allowAccountSwitch: true) }
        } message: {
            Text("This key belongs to a different account. Immount removes the current library from Finder and sets it up again for the new account.")
        }
    }

    private func save(allowAccountSwitch: Bool) {
        guard !isSaving else { return }
        isSaving = true
        error = nil
        Task {
            let outcome = await model.saveConnection(serverText: server, keyText: key, connect: model.isConnected, allowAccountSwitch: allowAccountSwitch)
            isSaving = false
            switch outcome {
            case .saved: dismiss()
            case .failed(let message): error = message
            case .needsAccountSwitch: confirmSwitch = true
            }
        }
    }
}

// MARK: - Local network

private struct LocalNetworkPane: View {
    @Bindable var model: AppModel
    let navigator: SettingsNavigator
    /// Whether a new network row is open, and the name typed in it. Kept apart so the field
    /// writing its text back as it goes away cannot reopen the row.
    @State private var isAddingNetwork = false
    @State private var newNetworkName = ""
    @FocusState private var isEditingURL: Bool
    @FocusState private var isEditingNetwork: Bool

    var body: some View {
        if let profile = model.profile {
            configured(profile)
                .onAppear { model.resetLocalURLDraft() }
                .onDisappear { Task { await model.commitLocalURL() } }
        } else {
            Section {
                LabeledContent {
                    Button("Go to General") { navigator.show(.general) }
                } label: {
                    SettingLabel(title: "Connect to your server first.")
                }
            }
        }
    }

    @ViewBuilder
    private func configured(_ profile: ServerProfile) -> some View {
        Section {
            TextField(text: $model.localURLInput, prompt: Text(verbatim: "http://192.168.1.10:2283")) {
                SettingLabel(title: "Local URL", subtitle: model.localURLError, info: "Used only on the Wi-Fi networks below. Leave empty to always use the server URL.")
            }
            .textContentType(.URL)
            .autocorrectionDisabled()
            .focused($isEditingURL)
            .onSubmit { Task { await model.commitLocalURL() } }
            .onChange(of: isEditingURL) { _, editing in
                if !editing { Task { await model.commitLocalURL() } }
            }
            LabeledContent {
                NowUsingLabel(model: model)
            } label: {
                SettingLabel(
                    title: "Now using",
                    subtitle: model.localURLUnreachable ? "The local URL did not answer on this network." : nil
                )
            }
        } header: {
            SectionHeader(title: "Local address", subtitle: "At home, connect to your server directly.")
        } footer: {
            if profile.localServerURL?.scheme?.lowercased() == "http" {
                Label("On these networks the API key travels unencrypted. Use an https address if your server has one.", systemImage: "lock.open")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }

        Section {
            if profile.localNetworks.isEmpty, !isAddingNetwork {
                Text("No networks yet.").foregroundStyle(.secondary)
            }
            ForEach(profile.localNetworks, id: \.self) { name in
                LabeledContent {
                    Button("Remove", systemImage: "minus.circle.fill") { model.removeLocalNetwork(name) }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.borderless)
                        .foregroundStyle(.secondary)
                        .help("Remove")
                } label: {
                    Label {
                        HStack {
                            Text(verbatim: name)
                            if name == model.wifi.ssid {
                                Text("Current").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    } icon: {
                        Image(systemName: "wifi")
                    }
                }
            }
            if isAddingNetwork {
                newNetworkRow
            }
            HStack {
                Button("Add Network", systemImage: "plus", action: startAddingNetwork)
                    .buttonStyle(.borderless)
                    .disabled(isAddingNetwork)
                Spacer()
                if model.wifi.isAuthorized, let ssid = model.wifi.ssid, !profile.localNetworks.contains(ssid) {
                    Button("Add \u{201C}\(ssid)\u{201D}") { model.addLocalNetwork(ssid) }
                        .help("Add the network this Mac is on.")
                }
            }
            locationPermissionRow
        } header: {
            SectionHeader(title: "Wi-Fi networks", subtitle: "Use the local URL on these networks.")
        }
    }

    /// A row with a focused field for the name of a network to add.
    private var newNetworkRow: some View {
        LabeledContent {
            Button("Cancel", systemImage: "xmark.circle.fill") { isAddingNetwork = false }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help("Cancel")
        } label: {
            Label {
                TextField("Network name", text: $newNetworkName, prompt: Text("Network name"))
                    .labelsHidden()
                    .focused($isEditingNetwork)
                    .onSubmit(finishAddingNetwork)
                    .onKeyPress(.escape) {
                        isAddingNetwork = false
                        return .handled
                    }
                    // The row is new: focus it once it exists, after the pane's own initial focus.
                    .onAppear { DispatchQueue.main.async { isEditingNetwork = true } }
            } icon: {
                Image(systemName: "wifi")
            }
        }
        .onChange(of: isEditingNetwork) { _, editing in
            if !editing { finishAddingNetwork() }
        }
    }

    private func startAddingNetwork() {
        newNetworkName = ""
        isAddingNetwork = true
    }

    /// Adds the typed name; an empty row just goes away.
    private func finishAddingNetwork() {
        guard isAddingNetwork else { return }
        isAddingNetwork = false
        model.addLocalNetwork(newNetworkName)
    }

    /// Explains how to let Immount see the Wi-Fi name, when it cannot yet.
    @ViewBuilder
    private var locationPermissionRow: some View {
        let info = "macOS only shares the Wi-Fi name with apps allowed to use Location Services."
        if model.wifi.isDenied {
            LabeledContent {
                Button("Open Settings") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocationServices")!)
                }
            } label: {
                SettingLabel(title: "Current network", subtitle: "Location Services is off for Immount.", info: info)
            }
        } else if !model.wifi.isAuthorized {
            LabeledContent {
                Button("Allow…") { model.wifi.requestAuthorization() }
            } label: {
                SettingLabel(title: "Current network", subtitle: "Allow Location Services to read the Wi-Fi name.", info: info)
            }
        }
    }
}

// MARK: - About

private struct AboutPane: View {
    @Environment(AppUpdater.self) private var updater

    private var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "Version \(short) (\(build))"
    }

    var body: some View {
        Section {
            VStack(spacing: 6) {
                AppBadge(size: 80)
                Text("Immount").font(.title2.weight(.semibold))
                Text(version).foregroundStyle(.secondary)
                Text("Immich in your Finder.").foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
        }
        if updater.isAvailable {
            UpdatesSection(updater: updater)
        }
        Section {
            LinkRow(title: "Immich", subtitle: "The self-hosted photo library Immount connects to.", url: URL(string: "https://immich.app")!)
            LinkRow(title: "Immich API", subtitle: "Reference for the endpoints Immount uses.", url: URL(string: "https://api.immich.app")!)
        } footer: {
            Text("Immount is an independent project. It is not affiliated with or endorsed by Immich or FUTO.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }
}

private struct UpdatesSection: View {
    @Bindable var updater: AppUpdater

    var body: some View {
        Section {
            LabeledContent {
                HStack {
                    if let lastCheck = updater.lastCheck {
                        RelativeTimeText(date: lastCheck)
                            .foregroundStyle(.secondary)
                    }
                    Button(updater.pendingVersion.map { "Update to \($0)…" } ?? "Check Now") {
                        updater.checkForUpdates()
                    }
                    .disabled(!updater.canCheckForUpdates)
                }
            } label: {
                SettingLabel(
                    title: "Last check",
                    subtitle: updater.lastCheck == nil ? "Not checked yet." : nil
                )
            }
            Toggle(isOn: $updater.automaticallyChecks) {
                SettingLabel(title: "Check for updates automatically", info: "Immount checks once a day. A new version waits in the menu bar menu and here, without interrupting you.")
            }
            .toggleStyle(.switch)
            Toggle(isOn: $updater.automaticallyDownloads) {
                SettingLabel(title: "Download and install automatically", info: "New versions install the next time Immount quits.")
            }
            .toggleStyle(.switch)
            .disabled(!updater.automaticallyChecks)
        } header: {
            Text("Updates")
        }
    }
}

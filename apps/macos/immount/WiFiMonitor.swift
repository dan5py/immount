import CoreLocation
import CoreWLAN
import Network
import Observation

/// Tracks the name of the Wi-Fi network the Mac is on.
///
/// macOS only reveals the network name (SSID) to apps allowed to use Location Services,
/// so the monitor asks for that permission the first time a home network is configured.
@Observable
final class WiFiMonitor: NSObject, CLLocationManagerDelegate {
    private(set) var ssid: String?
    private(set) var authorization: CLAuthorizationStatus
    private(set) var networkAvailable = false
    private(set) var isConstrained = false
    private(set) var isExpensive = false

    /// Called whenever the network may have changed.
    @ObservationIgnored var onChange: (() -> Void)?
    /// Actual path availability/cost changes, separate from periodic SSID/lease checks.
    @ObservationIgnored var onPathChange: ((_ becameAvailable: Bool) -> Void)?

    @ObservationIgnored private let locationManager = CLLocationManager()
    @ObservationIgnored private let pathMonitor = NWPathMonitor()
    @ObservationIgnored private var pendingCheck: Task<Void, Never>?

    override init() {
        authorization = locationManager.authorizationStatus
        super.init()
        locationManager.delegate = self
        pathMonitor.pathUpdateHandler = { [weak self] path in
            MainActor.assumeIsolated { self?.networkDidChange(path) }
        }
        pathMonitor.start(queue: .main)
        update()
    }

    var isAuthorized: Bool { authorization == .authorizedAlways }
    var isDenied: Bool { authorization == .denied || authorization == .restricted }
    var isUndetermined: Bool { authorization == .notDetermined }

    func requestAuthorization() {
        locationManager.requestWhenInUseAuthorization()
    }

    func update() {
        let current = CWWiFiClient.shared().interface()?.ssid()
        if current != ssid { ssid = current }
        onChange?()
    }

    private func networkDidChange(_ path: NWPath) {
        let available = path.status == .satisfied
        let becameAvailable = available && !networkAvailable
        let changed = networkAvailable != available || isConstrained != path.isConstrained || isExpensive != path.isExpensive
        networkAvailable = available
        isConstrained = path.isConstrained
        isExpensive = path.isExpensive
        update()
        if changed { onPathChange?(becameAvailable) }
        // The new path is often reported before the Wi-Fi association completes; look again shortly.
        pendingCheck?.cancel()
        pendingCheck = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            self?.update()
        }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        MainActor.assumeIsolated {
            authorization = status
            update()
        }
    }
}

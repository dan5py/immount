import CoreGraphics
import Foundation
import IOKit.ps

/// Power and presence signals for the album watch (see `AlbumWatchPolicy`).
enum SystemActivity {
    /// True when the Mac runs on its battery; desktops and unknown sources count as mains power.
    static var isOnBattery: Bool {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let source = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() else { return false }
        return (source as String) == kIOPMBatteryPowerKey
    }

    /// Seconds since the last keyboard, pointer or trackpad input in this login session.
    static var idleTime: TimeInterval {
        guard let anyInput = CGEventType(rawValue: ~0) else { return 0 }
        return CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: anyInput)
    }
}

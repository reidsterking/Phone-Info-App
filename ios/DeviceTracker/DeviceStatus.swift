import Foundation
import UIKit

struct BatteryInfo: Codable, Equatable {
    /// 0.0 to 1.0, or -1 when unknown (for example in the Simulator).
    /// iOS only exposes this in 5% steps to third-party apps. There is no public API for 1% precision.
    let level: Float
    /// "charging", "full", "unplugged" or "unknown".
    let state: String
    let lowPowerMode: Bool

    var percentText: String { level < 0 ? "Unknown" : "\(Int((level * 100).rounded()))%" }

    var stateText: String {
        switch state {
        case "charging": return "Charging"
        case "full": return "Full (plugged in)"
        case "unplugged": return "Not charging"
        default: return "Unknown"
        }
    }
}

/// Live battery and charging state, reporting changes to the server while the app is running.
@MainActor
final class DeviceStatus: ObservableObject {
    static let shared = DeviceStatus()

    @Published private(set) var battery: BatteryInfo

    private init() {
        UIDevice.current.isBatteryMonitoringEnabled = true
        battery = Self.readBattery()
        let names: [Notification.Name] = [
            UIDevice.batteryLevelDidChangeNotification,
            UIDevice.batteryStateDidChangeNotification,
            .NSProcessInfoPowerStateDidChange,
        ]
        for name in names {
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.update() }
            }
        }
    }

    func update() {
        let new = Self.readBattery()
        guard new != battery else { return }
        let pluggedChanged = new.state != battery.state
        battery = new
        Task { await Reporter.shared.report(reason: pluggedChanged ? "charging-changed" : "battery-changed", force: pluggedChanged) }
    }

    static func readBattery() -> BatteryInfo {
        let device = UIDevice.current
        device.isBatteryMonitoringEnabled = true
        let state: String
        switch device.batteryState {
        case .charging: state = "charging"
        case .full: state = "full"
        case .unplugged: state = "unplugged"
        default: state = "unknown"
        }
        return BatteryInfo(level: device.batteryLevel, state: state, lowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled)
    }

    /// Hardware identifier such as "iPhone16,1".
    static var modelIdentifier: String {
        var info = utsname()
        uname(&info)
        return withUnsafeBytes(of: &info.machine) { buffer in
            String(decoding: buffer.prefix { $0 != 0 }, as: UTF8.self)
        }
    }
}

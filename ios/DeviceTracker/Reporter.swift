import CoreLocation
import Foundation
import UIKit
import UserNotifications

/// Sends status reports to the server and runs any commands it hands back.
@MainActor
final class Reporter: ObservableObject {
    static let shared = Reporter()

    @Published private(set) var lastResult = "No report sent yet"
    @Published private(set) var lastSent: Date?

    private var inFlight = false
    private var lastAttempt = Date.distantPast
    /// Reports that are not user-initiated are rate limited so continuous GPS doesn't hammer the server.
    private let minimumInterval: TimeInterval = 30

    func report(reason: String, force: Bool = false) async {
        let settings = Settings.shared
        guard settings.isConfigured, let base = URL(string: settings.serverURL) else {
            lastResult = "Enter the server URL and API key first"
            return
        }
        guard !inFlight else { return }
        guard force || Date().timeIntervalSince(lastAttempt) >= minimumInterval else { return }
        inFlight = true
        lastAttempt = Date()
        defer { inFlight = false }

        // Ask iOS for extra time in case we were woken in the background.
        let backgroundTask = BackgroundTask(name: "report")
        defer { backgroundTask.end() }

        let location = await LocationService.shared.currentLocation()
        let payload = ReportPayload(
            name: settings.deviceName,
            model: DeviceStatus.modelIdentifier,
            systemName: UIDevice.current.systemName,
            systemVersion: UIDevice.current.systemVersion,
            appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?",
            pushToken: settings.pushToken,
            apnsEnvironment: Self.apnsEnvironment,
            reason: reason,
            battery: DeviceStatus.readBattery(),
            location: location.map(LocationPayload.init)
        )

        var request = URLRequest(url: base.appendingPathComponent("api/devices/\(settings.deviceID)/report"))
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(settings.apiKey)", forHTTPHeaderField: "Authorization")

        do {
            request.httpBody = try JSONEncoder().encode(payload)
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard status == 200 else {
                lastResult = status == 401 ? "Wrong API key" : "Server returned HTTP \(status)"
                return
            }
            let body = try JSONDecoder().decode(ReportResponse.self, from: data)
            lastSent = Date()
            lastResult = "Sent (\(reason))"
            body.commands.forEach(handle)
        } catch {
            lastResult = "Failed: \(error.localizedDescription)"
        }
    }

    /// Called for each new GPS fix.
    func locationChanged() {
        Task { await report(reason: "location") }
    }

    private func handle(_ command: ServerCommand) {
        switch command.type {
        case "ping":
            // A push already played this one, or it is too old to be useful.
            if command.requestedAt == Settings.shared.lastHandledPing { return }
            if let date = ISO8601DateFormatter.withFractions.date(from: command.requestedAt), date.timeIntervalSinceNow < -600 { return }
            Self.playPing(requestedAt: command.requestedAt)
        default:
            break // "refresh" needs nothing more: this report was the refresh.
        }
    }

    /// Plays the alarm directly when the app is on screen, otherwise posts a local notification with the ping sound.
    static func playPing(requestedAt: String?) {
        if let requestedAt { Settings.shared.lastHandledPing = requestedAt }
        if UIApplication.shared.applicationState == .active {
            AlarmPlayer.shared.start()
            return
        }
        let content = UNMutableNotificationContent()
        content.title = "Find My Device"
        content.body = "\(Settings.shared.deviceName) is being pinged."
        content.sound = UNNotificationSound(named: UNNotificationSoundName("ping.wav"))
        content.interruptionLevel = .timeSensitive
        content.userInfo = ["command": "ping", "local": true]
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "ping", content: content, trigger: nil))
    }

    static var apnsEnvironment: String {
        #if DEBUG
        return "sandbox"
        #else
        return "production"
        #endif
    }
}

struct ReportPayload: Encodable {
    let name: String
    let model: String
    let systemName: String
    let systemVersion: String
    let appVersion: String
    let pushToken: String?
    let apnsEnvironment: String
    let reason: String
    let battery: BatteryInfo
    let location: LocationPayload?
}

struct LocationPayload: Encodable {
    let latitude: Double
    let longitude: Double
    let accuracy: Double
    let altitude: Double
    let speed: Double
    let timestamp: String

    init(_ location: CLLocation) {
        latitude = location.coordinate.latitude
        longitude = location.coordinate.longitude
        accuracy = location.horizontalAccuracy
        altitude = location.altitude
        speed = location.speed
        timestamp = ISO8601DateFormatter.withFractions.string(from: location.timestamp)
    }
}

struct ReportResponse: Decodable {
    let commands: [ServerCommand]
}

struct ServerCommand: Decodable {
    let type: String
    let requestedAt: String
}

extension ISO8601DateFormatter {
    static let withFractions: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
}

/// Holds a UIKit background task open until `end()` is called or iOS runs out of patience.
@MainActor
final class BackgroundTask {
    private var id = UIBackgroundTaskIdentifier.invalid

    init(name: String) {
        // The expiration handler runs on the main thread and must end the task synchronously.
        id = UIApplication.shared.beginBackgroundTask(withName: name) { [weak self] in
            MainActor.assumeIsolated { self?.end() }
        }
    }

    func end() {
        guard id != .invalid else { return }
        UIApplication.shared.endBackgroundTask(id)
        id = .invalid
    }
}

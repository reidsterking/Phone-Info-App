import CoreLocation
import SwiftUI
import UserNotifications

struct ContentView: View {
    @ObservedObject private var settings = Settings.shared
    @ObservedObject private var status = DeviceStatus.shared
    @ObservedObject private var location = LocationService.shared
    @ObservedObject private var reporter = Reporter.shared
    @ObservedObject private var alarm = AlarmPlayer.shared
    @State private var notificationsAllowed: Bool?

    var body: some View {
        NavigationStack {
            Form {
                if alarm.isPlaying {
                    Section {
                        Button("Stop sound", role: .destructive) { alarm.stop() }
                            .font(.headline)
                    }
                }

                Section("This device") {
                    LabeledContent("Battery", value: status.battery.percentText)
                    LabeledContent("Charging", value: status.battery.stateText)
                    if status.battery.lowPowerMode {
                        LabeledContent("Low Power Mode", value: "On")
                    }
                    if let loc = location.lastLocation {
                        LabeledContent("Location", value: String(format: "%.5f, %.5f", loc.coordinate.latitude, loc.coordinate.longitude))
                        LabeledContent("Accuracy", value: "±\(Int(loc.horizontalAccuracy)) m")
                    } else {
                        LabeledContent("Location", value: "Unknown")
                    }
                }

                Section {
                    Button("Send report now") {
                        Task { await reporter.report(reason: "manual", force: true) }
                    }
                    Button("Test ping sound") { alarm.start(duration: 5) }
                    LabeledContent("Last report", value: reporter.lastResult)
                    if let sent = reporter.lastSent {
                        LabeledContent("Sent", value: sent.formatted(date: .omitted, time: .standard))
                    }
                }

                Section {
                    LabeledContent("Location", value: locationPermissionText)
                    LabeledContent("Notifications", value: notificationsText)
                    Button("Request permissions") { requestPermissions() }
                    Button("Open iOS Settings") {
                        if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                    }
                } header: {
                    Text("Permissions")
                } footer: {
                    Text("Location must be set to \"Always\" or the device can only report while this app is open.")
                }

                Section {
                    TextField("https://your-server.example.com", text: $settings.serverURL)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField("API key", text: $settings.apiKey)
                    TextField("Device name", text: $settings.deviceName)
                } header: {
                    Text("Server")
                }

                Section {
                    Toggle("Continuous tracking", isOn: $settings.continuousTracking)
                        .onChange(of: settings.continuousTracking) { _, _ in location.start() }
                } header: {
                    Text("Tracking")
                } footer: {
                    Text("Off: the device reports when it moves about 500 m, when charging changes while the app is running, when you request an update, and when iOS allows a background refresh. On: GPS stays active in the background for up to the minute locations, at a real battery cost.")
                }

                Section("Limits imposed by iOS") {
                    Text("Battery level is rounded to 5% for third-party apps. There is no public API for exact 1% readings.")
                    Text("Apps cannot lock the device. Use Find My (icloud.com/find) and \"Mark As Lost\" to lock it remotely.")
                    Text("If you swipe this app away in the app switcher, iOS stops delivering background updates until you open it again. Ping notifications still arrive.")
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
            }
            .navigationTitle("Device Tracker")
            .task { await refreshNotificationStatus() }
        }
    }

    private var notificationsText: String {
        switch notificationsAllowed {
        case .none: return "Checking"
        case .some(true): return "Allowed"
        case .some(false): return "Not allowed"
        }
    }

    private var locationPermissionText: String {
        switch location.authorization {
        case .authorizedAlways: return "Always"
        case .authorizedWhenInUse: return "While Using (needs Always)"
        case .denied: return "Denied"
        case .restricted: return "Restricted"
        case .notDetermined: return "Not asked yet"
        @unknown default: return "Unknown"
        }
    }

    private func requestPermissions() {
        location.requestPermission()
        Task {
            _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
            await refreshNotificationStatus()
            UIApplication.shared.registerForRemoteNotifications()
        }
    }

    private func refreshNotificationStatus() async {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        notificationsAllowed = settings.authorizationStatus == .authorized
    }
}

import BackgroundTasks
import UIKit
import UserNotifications

final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    static var refreshTaskID: String { (Bundle.main.bundleIdentifier ?? "devicetracker") + ".refresh" }

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self

        // Creating the location manager here matters: when iOS relaunches the app in the background
        // for a significant location change, the event is delivered to this delegate.
        LocationService.shared.onUpdate = { _ in
            Task { @MainActor in Reporter.shared.locationChanged() }
        }
        LocationService.shared.start()
        _ = DeviceStatus.shared

        BGTaskScheduler.shared.register(forTaskWithIdentifier: Self.refreshTaskID, using: nil) { task in
            Self.scheduleBackgroundRefresh()
            let work = Task { @MainActor in
                await Reporter.shared.report(reason: "background-refresh", force: true)
                task.setTaskCompleted(success: true)
            }
            task.expirationHandler = { work.cancel() }
        }

        application.registerForRemoteNotifications()
        return true
    }

    /// Asks iOS to wake the app periodically. iOS decides the actual timing based on usage; it may be hours.
    static func scheduleBackgroundRefresh() {
        let request = BGAppRefreshTaskRequest(identifier: refreshTaskID)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
        try? BGTaskScheduler.shared.submit(request)
    }

    // MARK: Push notifications

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        let token = deviceToken.map { String(format: "%02x", $0) }.joined()
        guard token != Settings.shared.pushToken else { return }
        Settings.shared.pushToken = token
        Task { await Reporter.shared.report(reason: "push-registered", force: true) }
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        // Expected when building with a free Apple ID: push needs a paid developer account.
        print("Push registration failed: \(error)")
    }

    /// Silent "refresh" pushes, and ping pushes (which also carry content-available) land here in the background.
    func application(_ application: UIApplication, didReceiveRemoteNotification userInfo: [AnyHashable: Any]) async -> UIBackgroundFetchResult {
        if userInfo["command"] as? String == "ping", let requestedAt = userInfo["requestedAt"] as? String {
            // The notification itself plays the sound; just remember we handled it.
            await MainActor.run { Settings.shared.lastHandledPing = requestedAt }
        }
        await Reporter.shared.report(reason: "push", force: true)
        return .newData
    }

    /// A notification arriving while the app is on screen. For pings, play the looping alarm instead of the one-shot sound.
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        let userInfo = notification.request.content.userInfo
        guard userInfo["command"] as? String == "ping" else { return [.banner, .list, .sound] }
        let requestedAt = userInfo["requestedAt"] as? String
        await MainActor.run {
            if let requestedAt { Settings.shared.lastHandledPing = requestedAt }
            AlarmPlayer.shared.start()
        }
        return [.banner, .list]
    }
}

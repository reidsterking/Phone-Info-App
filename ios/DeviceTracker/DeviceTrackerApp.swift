import SwiftUI

@main
struct DeviceTrackerApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                DeviceStatus.shared.update()
                Task { await Reporter.shared.report(reason: "app-opened", force: true) }
            case .background:
                AppDelegate.scheduleBackgroundRefresh()
            default:
                break
            }
        }
    }
}

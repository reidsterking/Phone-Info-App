import Foundation
import Security
import UIKit

/// User-editable configuration plus the stable identity this device reports under.
final class Settings: ObservableObject {
    static let shared = Settings()

    private let defaults = UserDefaults.standard

    @Published var serverURL: String {
        didSet { defaults.set(serverURL.trimmingCharacters(in: .whitespaces), forKey: Keys.serverURL) }
    }
    @Published var apiKey: String {
        didSet { Keychain.set(apiKey, for: Keys.apiKey) }
    }
    @Published var deviceName: String {
        didSet { defaults.set(deviceName, forKey: Keys.deviceName) }
    }
    /// Continuous GPS in the background. Much fresher location, noticeably worse battery life.
    @Published var continuousTracking: Bool {
        didSet { defaults.set(continuousTracking, forKey: Keys.continuousTracking) }
    }

    var pushToken: String? {
        get { defaults.string(forKey: Keys.pushToken) }
        set { defaults.set(newValue, forKey: Keys.pushToken) }
    }

    /// Timestamp of the last ping we already played, so a queued copy of it is not played again.
    var lastHandledPing: String? {
        get { defaults.string(forKey: Keys.lastHandledPing) }
        set { defaults.set(newValue, forKey: Keys.lastHandledPing) }
    }

    let deviceID: String

    var isConfigured: Bool {
        guard let url = URL(string: serverURL), url.scheme == "https" || url.scheme == "http", url.host != nil else { return false }
        return !apiKey.isEmpty
    }

    private init() {
        if let id = defaults.string(forKey: Keys.deviceID) {
            deviceID = id
        } else {
            deviceID = UUID().uuidString
            defaults.set(deviceID, forKey: Keys.deviceID)
        }
        serverURL = defaults.string(forKey: Keys.serverURL) ?? ""
        apiKey = Keychain.get(Keys.apiKey) ?? ""
        // iOS 16+ returns a generic "iPhone" for UIDevice.name, so let the user pick a name.
        deviceName = defaults.string(forKey: Keys.deviceName) ?? UIDevice.current.name
        continuousTracking = defaults.bool(forKey: Keys.continuousTracking)
    }

    private enum Keys {
        static let deviceID = "deviceID"
        static let serverURL = "serverURL"
        static let apiKey = "apiKey"
        static let deviceName = "deviceName"
        static let continuousTracking = "continuousTracking"
        static let pushToken = "pushToken"
        static let lastHandledPing = "lastHandledPing"
    }
}

enum Keychain {
    static func get(_ account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func set(_ value: String, for account: String) {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(base as CFDictionary)
        guard !value.isEmpty else { return }
        var item = base
        item[kSecValueData as String] = Data(value.utf8)
        // Readable while the phone is locked, which background reports need.
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(item as CFDictionary, nil)
    }
}

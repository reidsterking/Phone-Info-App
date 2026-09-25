# Device Tracker

A self-hosted "find my device" for your own iPhones and iPads:

- **`ios/`**: a SwiftUI app you install on each device. It reports battery level, charging state, Low Power Mode and GPS location, and plays a loud alarm when pinged.
- **`server/`**: a small Node.js server (no npm dependencies) that stores the reports, sends pings through Apple Push Notifications, and serves a web dashboard with a map.

## What works and what iOS does not allow

| Feature | Status |
| --- | --- |
| Battery percentage | Works, but **iOS rounds it to 5% steps** for all third-party apps (e.g. 85%, 90%). There is no public API for exact 1% readings on iPhone/iPad. |
| Charging / full / unplugged | Works. |
| Location | Works. Needs "Always" location permission for background updates. |
| Ping (play a sound) | Works via push notification. Needs a **paid Apple Developer account** ($99/yr). The notification sound respects the silent switch; the in-app alarm (when the app is open) does not. |
| Remote lock | **Not possible for any App Store style app.** Only Apple's Find My ("Mark As Lost" at icloud.com/find) or an MDM server can lock a device. The dashboard links to Find My for this. |

How fresh the data is depends on what iOS lets the app do in the background:

- Moves of roughly 500 m wake the app (significant location change monitoring).
- Plugging in or unplugging is reported right away, but only while the app is open or kept running by continuous tracking. Otherwise it shows up with the next report.
- "Request update" on the dashboard sends a silent push. iOS throttles these, so it is best effort.
- iOS runs a background refresh every so often, at times it chooses.
- "Continuous tracking" in the app keeps GPS on for near real time location, at a real battery cost.
- If you swipe the app away in the app switcher, iOS stops waking it until you open it again. Ping notifications still show up.

## 1. Run the server

Requires Node.js 20 or newer.

```sh
cd server
API_KEY="$(openssl rand -hex 24)" npm start
```

Keep that API key: the app and the dashboard both need it. Open `http://localhost:3000` for the dashboard.

Your phones need to reach the server from anywhere, so host it somewhere with **HTTPS** (for example Render, Railway, Fly.io, a VPS behind Caddy, or Tailscale Funnel). The data is stored in `data/devices.json` by default, so the host needs a persistent disk. Environment variables:

| Variable | Required | Meaning |
| --- | --- | --- |
| `API_KEY` | yes | Shared secret, at least 16 characters. |
| `PORT` | no | Defaults to 3000. |
| `DATA_FILE` | no | Where to store device data. Defaults to `./data/devices.json`. |
| `APNS_KEY_PATH` or `APNS_KEY` | for ping | Path to (or contents of) your `.p8` APNs key. |
| `APNS_KEY_ID` | for ping | The key's ID. |
| `APNS_TEAM_ID` | for ping | Your Apple Developer Team ID. |
| `APNS_BUNDLE_ID` | for ping | The app's bundle identifier, as set in Xcode (Signing & Capabilities). |

Without the APNs variables, "Play sound" is queued and only plays the next time the app reports in.

To create the APNs key: [developer.apple.com](https://developer.apple.com/account/resources/authkeys/list) > Certificates, Identifiers & Profiles > Keys > "+" > enable Apple Push Notifications service (APNs). Download the `.p8` file (you can only download it once).

Run the server tests with `npm test`.

## 2. Build and install the app

Requires a Mac with Xcode 15 or newer. No other tools needed.

1. Open `ios/DeviceTracker.xcodeproj` in Xcode.
2. Click the blue **DeviceTracker** project at the top of the file list, then the **Signing & Capabilities** tab.
3. Pick your Apple ID under **Team** (add it in Xcode > Settings > Accounts if it is not listed).
4. Change **Bundle Identifier** from `com.example.devicetracker` to something unique, such as `com.yourname.devicetracker`. Use the same value for `APNS_BUNDLE_ID` on the server.
5. Plug in your iPhone or iPad, select it at the top of the Xcode window, and press Run (the play button). Repeat for each device.

The first time, the device may block the app. Go to Settings > General > VPN & Device Management, trust your developer certificate, and turn on Developer Mode if asked (Settings > Privacy & Security > Developer Mode).

**Free Apple ID vs. paid developer account:** the project is set up for a free Apple ID (Personal Team) by default, so push notifications are off. Battery, charging and location reporting work, but ping only plays the next time the app reports in, and iOS makes you reinstall the app every 7 days.

**Turning on push (paid account only):** in Build Settings, set **Code Signing Entitlements** to `DeviceTracker/DeviceTracker.entitlements`, then build again. That enables Push Notifications and Time Sensitive Notifications, which instant ping needs.

## 3. Set up each device

1. Open Device Tracker.
2. Enter the server URL and API key, and give the device a name.
3. Tap **Request permissions**. Allow notifications, and choose **Always** for location (iOS may ask for "Always" later; you can also set it in Settings > Device Tracker > Location).
4. Tap **Send report now**. The device should appear on the dashboard.

## Security notes

- Everything is protected by the single `API_KEY`. Anyone with it can see your devices' locations, so use a long random key and HTTPS only.
- The dashboard stores the key in your browser's local storage. Sign out on shared computers.
- The API key is stored in the iOS Keychain on each device.

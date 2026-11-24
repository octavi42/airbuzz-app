<p align="center">
  <img src="docs/images/icon.png" width="112" alt="AirBuzz icon">
</p>

<h1 align="center">AirBuzz</h1>

<p align="center">
  Your Fitbit Air buzzes when your iPhone does.<br>
  <a href="https://airbuzz.tavi.ceo">airbuzz.tavi.ceo</a> · free beta on TestFlight
</p>

<p align="center">
  <img src="docs/images/app.jpg" width="240" alt="AirBuzz main screen">
  &nbsp;&nbsp;
  <img src="docs/images/setup.jpg" width="240" alt="Notification setup guide">
</p>

The Fitbit Air has no screen and never buzzes for your messages. AirBuzz makes it pulse for any iPhone notification you pick: Messages, WhatsApp, Slack, even WhatsApp and Telegram calls.

## How it works

There is no API to vibrate the band, so AirBuzz speaks its protocol directly:

```
Bluetooth LE  →  Gattlink  →  DTLS 1.2 (PSK)  →  CoAP /settings
```

It briefly changes the band's haptic intensity setting, which makes the motor pulse, then restores it. After each buzz it hands the link back so the Google Health app keeps syncing. An iOS 27 Shortcuts Notification automation runs the **Buzz My Air** App Intent, so AirBuzz never reads your notifications.

- **Single** taps once. **Double** holds the alternate setting for 800 ms.
- Requests that arrive together run in order. Each one is capped at 25 seconds.

## Privacy

AirBuzz sends anonymous usage events to PostHog: a random install ID, app and iOS version, device model, and for each buzz whether it worked, how long it took and whether the app or an automation asked for it. It never sends notification content, app names, band identifiers or anything about you. Turn it off in the app under **... → Share anonymous usage**. If you build from source, clear `POSTHOG_KEY` in `App/project.yml` to send nothing.

## Requirements

- iPhone on iOS 27
- A Fitbit Air paired with that iPhone (Google Health keeps working alongside AirBuzz)

## Set up notifications

In the app, tap **Buzz on notifications**, pick an app, and tap **Copy prompt and open Shortcuts**. Paste the prompt into *Describe a shortcut*. Do this once per app.

Or by hand: in Shortcuts go to **Automation → New → Notification**, choose the app, set it to run immediately, and add the **Buzz My Air** action.

## Build from source

Needs macOS, Xcode with the iOS 27 SDK, CMake, Ninja and XcodeGen. Everything else is vendored.

```sh
bash scripts/check.sh
```

That builds the C core for macOS and iOS, runs the fake-band loopback tests under AddressSanitizer and UBSan, generates the Xcode project and compiles the app. Then open `App/AirBuzz.xcodeproj`, set your signing team and run it on your iPhone.

| Path | What's there |
| --- | --- |
| `App/` | SwiftUI app, CoreBluetooth transport, the App Intent |
| `Core/` | C11 session wrapper over the Golden Gate stack, plus a fake band for tests |
| `Vendor/golden-gate/` | Pinned Golden Gate core with mbedTLS 2.28 (Apache 2.0) |
| `scripts/` | `check.sh` (the full gate) and `build-core.sh` |

## Disclaimer

AirBuzz is an independent project. It is not affiliated with or endorsed by Google or Fitbit. Golden Gate is Apache 2.0; see `Vendor/golden-gate/LICENSE` and `NOTICE`.

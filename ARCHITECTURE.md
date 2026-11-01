# Cindrix AirLink architecture

This document describes how Cindrix AirLink is put together, how devices find and link to each other with no
internet, and what is planned next. It is meant for whoever works on the code next (human or AI). Read
`AGENTS.md` for repository layout and build commands; this file explains the *design*.

Status legend used below: **built** = code exists in the repo, **tested** = confirmed working on real devices,
**planned** = designed but not written. At the time of writing nothing new is *tested* yet; the first
real-device test (two Android phones, one Windows PC) is the next milestone.

---

## 1. What AirLink is

A Windows + Android app for sending files, folders and text between nearby devices with **no internet and no
servers**. It is a rebranded fork of [LocalSend](https://github.com/localsend/localsend) (Apache 2.0) with:

- the Cindrix brand (name, logo, charcoal/blue theme, callsign device names),
- a **pairing + direct link layer** so two Android phones can connect with no router at all,
- the donation, store-purchase and tracking pieces removed.

Design rule: **keep LocalSend's wire protocol unchanged**. AirLink devices and stock LocalSend devices can see and
send to each other on a shared network. Everything new is layered *around* the protocol, not inside it.

## 2. Layers

```
┌──────────────────────────────────────────────────────────────┐
│ Flutter UI (app/lib/pages, widget)                           │  Dart
│   Home/Receive tab, Send tab, Settings, Pair page            │
├──────────────────────────────────────────────────────────────┤
│ App state (app/lib/provider)  — Refena providers             │  Dart
│   settings, favorites, server, send sessions, device info    │
├──────────────────────────────────────────────────────────────┤
│ Link layer (NEW)                                             │  Dart + Kotlin
│   direct_link.dart ⇄ MethodChannel ⇄ DirectLink.kt/LocalHotspot.kt │
├──────────────────────────────────────────────────────────────┤
│ Isolates (packages/localsend_isolates)                       │  Dart
│   discovery, upload and HTTP server run off the main isolate │
├──────────────────────────────────────────────────────────────┤
│ Rust core (packages/core, via flutter_rust_bridge)           │  Rust
│   HTTP(S) server/client, TLS + certs, multicast, crypto      │
└──────────────────────────────────────────────────────────────┘
```

Everything below "Link layer" is inherited from LocalSend and is unchanged in behaviour. The link layer's only job is
to **make two devices reachable over IP**; once they are, the unchanged LocalSend stack does discovery, the
encrypted handshake and the transfer.

## 3. Inherited from LocalSend (do not break)

- **Protocol v2** on port `53317`: `/api/localsend/v2/register`, `prepare-upload`, `upload`, `cancel`, …
- **Discovery**: UDP multicast `224.0.0.167` announce-only; replies go back as an HTTP `register` request. Also
  direct HTTP `register` to a known IP (used by favorites and by our pairing).
- **Identity**: each device makes a self-signed RSA-2048 certificate; the device's identity is the SHA-256
  **fingerprint** of that certificate.
- **Encryption**: HTTPS with mutual TLS by default (setting `https`, default on). A peer can be *pinned* to an
  expected fingerprint (`httpProvider.pinnedTo(fingerprint)`), so the TLS handshake fails if a different device answers.
- **Web share** ("Receive via link"): a plain-http page a browser can open to download or upload files; this is how
  a person with no app receives something.
- **Favorites** (`favoritesProvider`, `FavoriteDevice`): saved devices (fingerprint, ip, port, alias). AirLink's
  "paired devices" are just favorites plus stored link credentials.

## 4. What AirLink adds

### 4.1 Link methods

`LinkMethod` (`app/lib/model/pairing_payload.dart`), in order of preference:

| Method | What it is | Needs | Credentials |
|---|---|---|---|
| `direct` | **Wi-Fi Direct** group: private device-to-device Wi-Fi, no router/hotspot/internet | Android 10+ on both phones, Wi-Fi on (not connected) | Fixed name + passphrase, created once and reused |
| `hotspot` | Android **local-only hotspot** (no internet) | Android 10+ | New random name/password each time |
| `lan` | Both devices already on the same Wi-Fi/hotspot | Shared network | none |

Why Wi-Fi Direct first: its group name and passphrase can be chosen and **kept**, so a paired pair can rejoin with no
new QR. The hotspot's credentials are chosen by Android and change every time, so it always needs a fresh scan.

Windows can show a pairing code and use `lan`, but **cannot** start or join Wi-Fi Direct or the hotspot yet.

### 4.2 Android native code (`app/android/app/src/main/kotlin/com/cindrix/airlink/`)

- `DirectLink.kt` — Wi-Fi Direct.
  - `startGroup`: `WifiP2pManager.createGroup` with a config (`DIRECT-AL-xxxx` name, 12-char passphrase, 2.4 GHz).
    The name/passphrase are generated once and stored in `SharedPreferences("airlink_direct")`, then reused.
    Reads the group back (`requestGroupInfo`) and reports `{ssid, passphrase, ip}`; the group owner is normally
    `192.168.49.1`.
  - `join(ssid, passphrase)`: `discoverPeers` (improves reliability), then `connect` by network name + passphrase
    (API 29+). Completes when `WIFI_P2P_CONNECTION_CHANGED_ACTION` reports a formed group and a non-null owner
    address; 35 s timeout.
  - `stop`: `cancelConnect`, `stopPeerDiscovery`, `removeGroup`, closes the channel, unregisters the receiver.
- `LocalHotspot.kt` — fallback hotspot.
  - `start`: `WifiManager.startLocalOnlyHotspot`; reads SSID/passphrase (`softApConfiguration` on API 30+,
    `wifiConfiguration` before).
  - `join`: `WifiNetworkSpecifier` + `ConnectivityManager.requestNetwork`, then `bindProcessToNetwork` (the network has
    no internet, so Android would not route this app's traffic there on its own). The host address is the gateway of
    the joined network.
- `MainActivity.kt` — method-channel `com.cindrix.airlink/airlink` exposes:
  `directLinkSupported/Start/Join/Stop` and `hotspotSupported/Start/Join/Stop`. Every start/join call returns a map
  `{ok, error?, ssid?, passphrase?, ip?}`; error codes include `unsupported`, `permission`, `wifi_off`, `timeout`,
  `create_failed_N`, `connect_failed_N`.
- Android version handling: everything is API 29+ (Android 10). Permission is `NEARBY_WIFI_DEVICES` on API 33+ and
  `ACCESS_FINE_LOCATION` on 29–32. Receivers use `RECEIVER_NOT_EXPORTED` on API 33+. Older phones fall back to `lan`.

### 4.3 Dart link layer (`app/lib/util/native/direct_link.dart`)

- `isLinkSupported`, `ensureLinkPermissions` (permission_handler; picks the right permission by SDK),
  `startLinkHost`, `joinLink`, and a private `_stopNative`.
- `LinkResult` wraps the native map and turns error codes into user-readable `message`s.
- `LinkWatcher` — keeps the link open only as long as needed. It polls every 3 s: while any receive or send session is
  `waiting`/`sending` the link stays up; **10 s after the last transfer ends** it calls `end()`, and if no transfer
  ever starts it closes after **10 min**. `LinkWatcher.active` (a `ValueNotifier<LinkMethod?>`) drives the UI.
- `LinkStore` — remembers `fingerprint → (ssid, passphrase)` for Wi-Fi Direct peers in `shared_preferences`
  (key `airlink_direct_links`). Only `direct` credentials are stable enough to store.

### 4.4 Pairing (`app/lib/pages/pair_page.dart`, `app/lib/model/pairing_payload.dart`)

The pairing QR carries a `PairingPayload`: `CINDRIX-AIRLINK:1:` + JSON
`{a: alias, f: fingerprint, i: ip, p: port, s: https, m: method, n: ssid?, k: passphrase?}`.

**Host** ("Start link and show code"): tries the chosen method (or *Auto*: `direct` → `hotspot` → `lan`), then shows the
QR (black on white so scanners read it in dark mode) and starts `LinkWatcher`.

**Joiner** ("Scan a code", `mobile_scanner`): parses the payload → joins the link (`joinLink`) → sends a v2 `register`
request to the host (pinned to the host's fingerprint when `https`), so the host also sees the joiner → saves the host
as a favorite (updating ip/port if known) → for `direct`, stores the credentials in `LinkStore`.

**Reconnect** (paired devices list): rebuilds a payload from the favorite plus `LinkStore` credentials and runs the same
join path — no QR. This is the "pair once" behaviour.

Entry points: Send tab (QR icon), Receive/Home tab (primary "Pair a device" button), Settings → Other.

### 4.5 Security notes

- The QR contains the Wi-Fi Direct passphrase. Anyone who scans it can join that Wi-Fi group, but **cannot read or
  inject transfers**: AirLink↔AirLink traffic is mutual-TLS and the joiner pins the host's fingerprint (from the QR).
  Treat the QR as sensitive anyway; show it only to the person you are pairing with.
- The Wi-Fi Direct passphrase is stored in app-private `SharedPreferences` and never leaves the device except in the QR.
- Android signing: the old key that lived in `signing/` was exposed while the repo was public, so it was **retired and
  removed**. The real release key is a new one stored only in the repository secrets `ANDROID_KEYSTORE_BASE64` and
  `ANDROID_KEY_PASSWORD` (alias `airlink`), plus an offline backup kept by the owner. Never commit a key to the repo.
  Without those secrets the Android build stops with an error.
- The app contains no update checks, analytics, or calls to LocalSend/Cindrix servers. Web share is plain http by
  default (browsers will not accept our self-signed certificate); keep it to trusted networks.

### 4.6 UI / branding

- Theme: dark charcoal (`#1F2226`) surfaces, blue accent (`#3B9BFF` seed, `#67B4FF` primary in dark), bone text
  (`#ECE6D8`). Default theme mode is dark; default color mode ignores Android dynamic colors (`config/theme.dart`,
  `provider/persistence_provider.dart`).
- Heading font: TeX Gyre Heros Condensed Bold (`assets/fonts`, GUST Font License, credited in `NOTICE`), family
  `AirLinkHeading`. Applied to display/headline/titleLarge text and the home-screen callsign.
- Device names: `util/alias_generator.dart` generates callsigns like `Falcon-27`; the Settings name field and its
  generate button use the same generator.
- Home screen: still logo (no rotation), large callsign, status line `ONLINE · READY TO RECEIVE`.
- Buttons stay rounded by design (owner's choice).
- Logo sources live in `design/logo/`; `apply_icons.sh` (kept outside the repo, in the build scratchpad) regenerated the
  Android/Windows/MSIX/web icons from the SVGs. Launcher icons need a solid charcoal background (Android requirement);
  the wordmark and glyph PNGs are transparent.

### 4.7 Share with anyone (friend has no app) — built, tested once on two phones

For people with neither AirLink nor LocalSend. Lives in `app/lib/widget/private_network_card.dart`, shown at the top of
the web share page (`web_share_page.dart`, both "send via link" and "receive via link", Android only).

1. "Create private network": starts the stored Wi-Fi Direct group (fallback: local-only hotspot) via the link layer.
   The host address is the group owner IP (`192.168.49.1`) or, for the hotspot, the new IPv4 address that appears after start.
2. **Step 1 QR** is a standard Wi-Fi code (`WIFI:T:WPA;S:<ssid>;P:<pass>;;`). Any phone camera offers "Connect".
3. **Step 2 QR** (revealed automatically when `requestGroupInfo` reports a client in the Wi-Fi Direct group, polled every 2 s;
   a button is the fallback, e.g. for the hotspot) is `https://<host>:<port>` (encryption is off by default, a checkbox turns it on; then the browser shows a
   "not private" warning that the step text explains) (plus `?pin=` if a PIN
   is set); the same address is printed large for typing. The page is the existing web share server (binds `0.0.0.0`).
   Downloads are auto-accepted for this flow (a friend with no app cannot be approved on the sender's phone by hand).
   Entry points: Home tab and Send tab buttons ("Share with anyone") plus the old "Share via link" menu.
4. The link is opened with `LinkWatcher.begin(..., keepOpen: true)` (no automatic timeout, because web transfers are not
   visible to the watcher). It is closed by the "Done" button or when the share page is left.
5. The friend-facing HTML (`packages/core/assets/web/*.html`) is rebranded and dark charcoal/blue.

Why two QR codes: a camera can join a Wi-Fi network or open an address, never both in one scan, and a captive-portal
auto-popup would need a DNS server on port 53 / web server on port 80, which Android apps cannot bind.
Open questions: does a stock phone camera join a `DIRECT-` network (Android/Samsung/iPhone)? Does the "no internet,
stay connected?" prompt appear and can it be answered easily? Is a transfer-complete signal available to auto-close?

## 5. Build and release

- Cloud builds only (the owner does not run Flutter locally): `.github/workflows/build_cindrix_airlink.yml`.
  Triggers: manual *Run workflow* (choose Windows and/or Android) and any push to the branch `build`.
  Artifacts: Windows = one zip with the app files at its root; Android = the arm64 APK (single ABI, to stay within
  the runner's disk space).
- The Android build frees runner disk first and builds `android-arm64` only.
- Android signing: the build requires the repository secrets and **fails if they are missing** (no throwaway fallback), so
  every APK is signed with the one permanent key and installs over the previous one.
- Pushing to `main` alone does not build anything.
- Known upstream leftovers: the Linux/macOS/iOS projects, `cli/`, `server/` and the Rust crate/Dart package names
  (`localsend_app`, `localsend_isolates`) are intentionally unchanged to keep the protocol and merges simple.

## 5.5 Two products, one codebase: AirLink and AirLink Pro

Plain AirLink (file transfer only) and AirLink Pro (adds Comms, once built) are built from this one repository
as two Android product flavors (`app/android/app/build.gradle`, `flavorDimensions = ["tier"]`):

- `free` — applicationId `com.cindrix.airlink` (unchanged from every build so far).
- `pro` — applicationId `com.cindrix.airlink.pro`, app name "Cindrix AirLink Pro".

The Dart side reads a matching `--dart-define=TIER=pro|free` (`lib/config/tier.dart`, `isPro` / `productName`);
undefined defaults to `free`, so an unflavored build behaves exactly as every build before this one did.
`lib/pages/home_page.dart`'s `visibleHomeTabs` hides the Comms tab (`lib/pages/tabs/comms_tab.dart`, currently a
placeholder) unless `isPro`. CI (`build_cindrix_airlink.yml`) builds both flavors from the same Android job and
uploads them as separate artifacts (`CindrixAirLink-*-android`, `CindrixAirLinkPro-*-android`); both are signed
with the same key, so they can install side by side on one phone for testing. This doubles the Android build's
CI minutes — free while the repo is public, worth remembering if it goes private again.

Everything except Comms (pairing, Wi-Fi Direct, Ready mode, Share with anyone, the UI) stays one shared
codebase, so a fix made once applies to both products and they can never drift out of protocol compatibility
with each other.

## 6. One-tap "Ready" mode (Android ↔ Android) — phase 1 built, untested

Phase 1 (built): `util/native/ready_mode.dart` starts the stored Wi-Fi Direct group when there is no real network (addresses in
192.168.49.x do not count) while the app is on screen, and stops it in the background; Home shows `READY · DIRECT LINK`;
the Send tab lists paired phones that are not nearby ("PAIRED · tap to connect and send") and `util/native/quick_connect.dart`
releases our own group, joins the other phone's by stored credentials, registers, and starts the normal send. Settings has a
"Ready mode" toggle. Phase 2 (not built): foreground service so Ready survives screen-off and a closed app.

Goal (owner's request): *"between Android phones, least steps; Wi-Fi Direct starts in the background and shows
Ready; send, then it turns itself off."* Windows may keep using a shared network. **Do not start until the base
build has been tested on real devices.**

### 6.1 Behaviour

1. **Ready (receiver side).** With AirLink open, "Ready mode" enabled, and *no usable shared network* (no local IPs),
   AirLink starts its stored Wi-Fi Direct group in the background and shows a status such as `READY · DIRECT LINK`
   on the home screen. If a shared network exists, nothing starts and normal LAN discovery is used.
2. **One-tap send (sender side).** In the Send tab, tapping a *paired* device that is not reachable on the LAN
   reconnects automatically (`LinkStore` credentials → `joinLink` → `register`), then continues the normal send flow.
   No QR, no pairing screen, no hotspot.
3. **Auto off.** `LinkWatcher` already closes the link ~10 s after the transfer. The receiver then returns to idle and
   (if still offline) can show Ready again or stay off to save battery — a setting.

### 6.2 Design points to settle

- **Who hosts.** A Wi-Fi Direct link needs exactly one group owner. Rule: the *receiver in Ready mode* hosts; a sender
  that is about to join must first stop any group of its own. If two phones are both Ready, the sender (the one that
  tapped Send) stops its group and joins the other's — tie-break by "whoever initiates sends joins".
- **Background operation.** Android stops background network work. Keeping a group alive with the screen off needs a
  **foreground service** (`FOREGROUND_SERVICE_CONNECTED_DEVICE`, persistent notification). Phase 1 can require the app
  to be open; phase 2 adds the service. Battery impact must be measured.
- **Invitation prompts.** Some Android versions show a system "accept connection?" prompt on the host for first
  contact. Real-device testing on the Note10 (Android 12) and Note20 (current Android) decides whether prompts appear
  for a joiner using the stored group name/passphrase.
- **Single radio.** While Wi-Fi Direct is up, many phones cannot stay on another Wi-Fi network. Ready mode must not
  start when a usable network is present, and must tear down if one appears.
- **Reachability check.** "Not reachable on the LAN" = the favorite does not answer a pinned `register` within a short
  timeout (≈1–2 s). Use that before falling back to the link.
- **Discovery over the p2p interface.** After joining, the joiner already knows the host IP (group owner) and registers
  to it, which also makes the host learn the joiner's IP. Multicast over the p2p interface is not relied on.
- **Settings.** Add a toggle "Ready mode (Android)" and "Return to Ready after sending". Defaults to be chosen after tests.

### 6.3 Code touch points (when built)

- `provider`/service: a new `ReadyModeService` that watches `localIpProvider`, settings and `LinkWatcher`.
- `direct_link.dart`: expose `ensureHostReady()` (idempotent start of the stored group) and a "keep-alive" state.
- `send_tab_vm.dart` / favorite tap path: call a new `ensureReachable(favorite)` before sending.
- Native: optional foreground service in Kotlin plus manifest entries; no change to the wire protocol.

## 6.5 Comms (AirLink Pro only) — text working, built, untested on real devices

Scope locked in with the owner: text + push-to-talk (PTT not built yet), mailbox/store-and-forward,
**direct-only** (a message only delivers once the two specific phones are linked again — no relay through a
third paired phone; that would be real mesh routing, a different, much bigger project). Group chat is out of
scope for v1. Location sharing (check-in, start point, breadcrumbs, writing into the shared GPX file the map
viewer reads) is planned but not yet built, sequenced after text + PTT are proven.

Deliberately **not** built on the Rust/FRB file-transfer protocol — a second, pure-Dart channel instead
(`lib/comms/comms_server.dart`, port 53318, one endpoint), so Comms can be built and changed without ever
touching the FRB-generated bridge or Rust core. Its security model is weaker than pairing's (it trusts the
`from` fingerprint a message claims, rather than binding to a TLS client cert); the real protection today is
the same one "Share with anyone" relies on — only someone who has the Wi-Fi Direct password can reach the
port at all. Worth hardening (pin the sender's cert) before treating this as safe against anyone deliberately
hostile already on the link.

- `lib/comms/message.dart` — `CommsMessage` (text/audio/location, pending/delivered, read flag).
- `lib/comms/message_store.dart` — `CommsMessageStore`, a singleton `ChangeNotifier` backed by one
  newline-delimited-JSON file in app-private storage (`getApplicationSupportDirectory()`), loaded once.
- `lib/comms/comms_server.dart` — the Dart `HttpServer` listener (`/comms/deliver`), started/stopped in
  `home_page.dart`'s `initState`/`dispose` when `isPro`.
- `lib/comms/comms_sync.dart` — `deliverPendingTo(...)`, POSTs a contact's queued outbox to their IP.
  Called (a) from `quick_connect.dart`'s `quickConnect` right after a successful register, so a deliberate
  connect always flushes mail, and (b) every 5s from `pages/tabs/comms_tab.dart` while that tab is open,
  against whatever `nearbyDevicesProvider` already sees, so delivery also happens ambiently on ordinary LAN
  discovery, not only via quickConnect.
- `lib/pages/tabs/comms_tab.dart` / `lib/comms/chat_thread_page.dart` — contact list (favorites, sorted by
  last message, unread badges) and the thread itself (text input, bubbles, pending/delivered ticks).

Not yet built: push-to-talk, location/check-in/start-point/breadcrumbs, the background service that would let
messages arrive without AirLink open on both ends (same unsolved piece as Ready mode phase 2), the SOS
screen/quick-tile/widget, the home-screen tile redesign, and hardening the comms channel's sender identity.

### 6.6 Background service (AirLink Pro)

`util/native/background_mode.dart` + `ForegroundService.startPersistent` (packages/localsend_isolates). While the
"Stay ready in background" setting is on (default), Pro runs an Android foreground service (type `connectedDevice`,
no Android 15 time limit) with a standby notification. It is started whenever the app is visible (Android 12+ forbids
starting one from the background) and then keeps running with the screen off. While it runs, `ReadyMode` no longer
stops in the background, and a 5 s timer flushes queued Comms mail to paired contacts discovery can see. A finished
file transfer restores the standby notification instead of stopping the service. Settings also offers the
battery-optimisation exemption (needed on Samsung). Limits: swiping the app out of recents kills the process (and
the service); starting the app from the background after a reboot is not done yet. Not verified on-device yet.

## 7. Known limitations and open questions

- Nothing in sections 4.2–4.4 has run on a real device yet; expect model-specific fixes (Samsung Wi-Fi Direct
  behaviour in particular).
- Windows cannot scan a code, and cannot create or join Wi-Fi Direct or the hotspot. Windows API options to evaluate:
  `Windows.Devices.WiFiDirect`, and `NetworkOperatorTetheringManager` (needs an existing connection profile).
- Sending to a friend with no app: see 4.7 ("Share with anyone"); it needs real-device testing on several phone brands.
- Only the new pairing/link screens are hard-coded English; the rest of the UI keeps LocalSend's translations (a few
  changed English strings were edited by hand in `assets/i18n/en.json` and `lib/gen/strings_en.g.dart`).
- Android build is arm64 only; add `armeabi-v7a`/`x86_64` back only if needed (watch runner disk space).

## 8. Real-device test checklist (base build)

1. Install the Windows zip and the Android APK; confirm name, logo, dark charcoal/blue theme, callsign name, still logo.
2. Phone ↔ PC on the same Wi-Fi: send a file each way, plus text and a folder.
3. Phone ↔ plain LocalSend (if available): both directions.
4. Android ↔ Android with **no router**, Wi-Fi on but not connected: Pair → *Auto* → scan → send a file. Note which
   method was used and any prompts shown.
5. Close the app on both, reopen, use **Reconnect** on the paired device: no QR needed? Link closes itself ~10 s after?
6. Repeat step 4 with the method forced to *Phone hotspot*, then *Same Wi-Fi*.
7. Record per phone model: Android version, which methods worked, error text shown.

Report results with exact error messages; fixes are batched into one build per round.

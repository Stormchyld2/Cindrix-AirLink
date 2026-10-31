# Cindrix AirLink

Cindrix AirLink shares files and messages between nearby devices over your local network or a phone hotspot,
with no internet connection and no third-party servers. It is part of the Cindrix line of offline tools.

AirLink is a rebranded fork of [LocalSend](https://github.com/localsend/localsend) (Apache License 2.0).
It deliberately keeps LocalSend's network protocol, so **AirLink devices and regular LocalSend devices can see
and send to each other**. Because of that, AirLink and LocalSend cannot run at the same time on the same device
(they use the same port).

Targets: **Windows** and **Android**. The code base also contains macOS, iOS and Linux projects inherited from
upstream; they only received the new app ID and are not maintained here.

## Building without installing Flutter

1. Open the repository on GitHub, go to **Actions** > **Build Cindrix AirLink (Windows + Android)**.
2. Click **Run workflow**.
3. When it finishes, download the zip (Windows) and APKs (Android) from **Artifacts** on the run page.

Android: install `app-arm64-v8a-release.apk` (the build is 64-bit ARM only, which covers nearly all phones from the last several years).
Builds are signed with a throwaway key unless you add the repository secrets `ANDROID_KEYSTORE_BASE64` and
`ANDROID_KEY_PASSWORD` (key alias `airlink`); with a throwaway key, uninstall the previous version before updating.

Windows: the zip is unsigned, so SmartScreen shows a warning on first run (More info > Run anyway). Unzip it into its own
folder and run `cindrix_airlink.exe`. When Windows Firewall asks, allow **Private networks**, otherwise other devices cannot find you.

## Pairing devices (no router needed)

Open **Pair a device** (QR button on the Send tab, button on the Receive tab, or Settings). One device taps
*Start link and show code*, the other taps *Scan a code*. Connection methods, in order of preference:

1. **Wi-Fi Direct**: a private device-to-device link, no router, hotspot or internet (Android 10+). Paired devices
   rejoin later without scanning again, and the link closes itself shortly after the transfer ends.
2. **Phone hotspot**: the phone's local-only hotspot (no internet needed); needs a fresh scan each time.
3. **Same Wi-Fi**: both devices are already on the same network.

Windows can show a code and use shared Wi-Fi, but cannot start or join Wi-Fi Direct yet.

## Building locally

The project pins its Flutter version in `.fvmrc` (use [fvm](https://fvm.app)):

```bash
cd app
fvm flutter pub get
fvm dart run build_runner build
fvm flutter run          # or: fvm flutter build windows / fvm flutter build apk
```

A Rust toolchain is required (version in `rust-toolchain.toml`). See `AGENTS.md` for the repository layout.

## License and attribution

Apache License 2.0, see [LICENSE](LICENSE) and [NOTICE](NOTICE).
Original work Copyright (C) 2022-2026 Tien Do Nam (LocalSend). Modifications Copyright (C) 2026 Cindrix.
The unmodified upstream snapshot is the first commit of this repository; later commits are the modifications.

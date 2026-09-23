# AirCard Lite 🎴

> **Apple Wallet Card Skinner for iOS 18+ (No Jailbreak Required)**
> **Tested on iOS 27 release.**
> Powered by the `airlift` AirTraffic sync exploit.

<p align="left">
  <a href="https://www.paypal.com/donate/?hosted_button_id=98QRTC2HFRA4Y"><img src="https://img.shields.io/badge/Donate-PayPal-00457C?style=flat-square&logo=paypal" alt="Donate with PayPal" /></a>
</p>

---

## Features
- 🎨 **Custom Card Skins:** Assign custom artwork, textures, or bank logos to Apple Pay and Wallet cards.
- ⚡ **Per-Card Customization:** Set and flash unique artwork for each card individually.
- 📱 **Card Detection:** Select a card in your iPhone's Wallet app to identify its card identifier from Wallet resource paths.
- 🚀 **100% Standalone (Universal):** Native support for both **Apple Silicon** and **Intel (x86)** Macs. All required device-communication utilities and image engines are pre-bundled inside the app.
- 📦 **Zero Prerequisites:** No Homebrew, Python packages, or terminal setup required for macOS users.

---

## Installation

### Windows / macOS (new desktop test client)

The new `desktop/` application uses Tauri 2, React, TypeScript and a bundled
Python backend. It includes bilingual UI, image cropping, per-device backups,
transaction recovery and Windows NSIS packaging. A real Suica completed the
Windows backup → replace → restore cycle; the user confirmed both artwork
changes in Wallet. The macOS arm64 app and DMG have been built and launched;
card operations on macOS and Intel builds are still pending validation.
Windows users need **Windows 11 x64**, **WebView2 Runtime**, and the verified
**Microsoft Store version of iTunes** for USB device communication. Python,
Node.js, Rust and Visual Studio are not required to run the installer. Apple DLLs
are not redistributed; Apple Devices-only and legacy desktop iTunes setups have
not been validated.

See [Windows dependencies and local build instructions for both platforms](docs/desktop-build.md),
[desktop usage](desktop/README.md), and
[validation results and remaining checks](docs/desktop-validation.md).

### Windows diagnostic prototype

A Windows diagnostic prototype is available. USB pairing, unified logs, AFC
test-file operations, StreamingZip staging, Grappa authentication, and AirTraffic
sync readiness have been tested. A disposable file outside Media completed the
write, readback, restore, second readback, and cleanup cycle on a real iPhone.
The isolated prototype remains available for diagnostics; card operations are
implemented in the new desktop client.
See [setup, commands, and device-test results](docs/windows-prototype.md).

### macOS (Universal DMG)
1. Build this fork from source using the instructions below.
2. Open **`build/AirCard.dmg`** and drag **`AirCard.app`** into your **Applications** folder.
3. Fully compatible with both **Apple Silicon** and **Intel (x86)** Macs.

> [!NOTE]
> **First Launch on macOS (Gatekeeper):**
> If macOS displays an unidentified developer prompt on first launch:
> - **Method 1 (UI):** Right-click (or Control-click) `AirCard.app` in Applications ➔ click **Open** ➔ click **Open**.
> - **Method 2 (Terminal):**
>   ```sh
>   sudo xattr -cr /Applications/AirCard.app
>   ```

---

## How to Customize Apple Wallet Cards
1. Connect your iPhone to your Mac via USB cable and ensure it is unlocked and trusted.
2. In AirCard, click **Scan Cards**.
3. On your iPhone:
   - **Double-click the Side (Power) button** to open Apple Pay.
   - Complete any unlock prompt on your iPhone.
   - **Tap your card** (or tap it once more) to trigger detection.
4. Click **更换卡面** below a card and choose an image, or drag & drop an image onto it. AirCard Lite flashes that card automatically.
5. Force-close the **Wallet** app on your iPhone from the App Switcher (or reboot) to see your new custom card design!

The scanner verifies each detected pass by reading its `pass.json`. It adds
payment cards and Secure Element transit cards with `paymentCard` or
`transitCard` metadata, and skips ordinary store cards, coupons, tickets, and
other barcode passes. If the type cannot be verified, it is not added. Saved
cards from older versions are checked and ordinary passes are removed when you
start a scan. Verification takes longer than log detection because each file is
backed up and restored on the device.

### Read & export card artwork

Connect the iPhone and click **读取卡面** below a card to copy and cache all of
its current artwork files. The preview appears on the card and remains available
after restarting AirCard. Click the card to inspect the full-size image. A
skin selected for flashing is displayed separately from the cached artwork.

Once a card has been read, the **export** button (arrow-up icon) becomes
available: it saves a ZIP of every cached artwork file straight from the local
cache, without contacting the device again. AirCard first reads the pass
`manifest.json` to find its actual image files. It supports Apple's documented
PNG resources (`artwork`, `strip`, `background`, `thumbnail`, `logo`,
`primaryLogo`, `secondaryLogo`, `footer`, and `icon`), plus other safely named PNG
resources listed in the manifest, including 1x/2x/3x and localized `.lproj`
variants. If no usable manifest is available, it falls back
to the existing combined artwork files: `cardBackgroundCombined@3x.png`,
`cardBackgroundCombined@2x.png`, and `cardBackgroundCombined.pdf`. It puts every
successfully read image in the ZIP with its relative path preserved. A component
image is shown as a source image, not a reconstruction of the complete Wallet
pass. The result lists files that were unavailable.
An export fails if none can be read, or if writeback or recovery checks fail.
File signatures are reported as a warning rather than blocking byte-for-byte
exports.
These are the files currently on the iPhone; if a skin was already applied,
they may no longer be the card's factory artwork. Export before applying a skin
to save the earlier design.

AirTraffic moves each original file temporarily during reading. AirCard saves a
checked copy in `~/Library/Application Support/AirCard/Recovery/` and writes a
copy back to the card. Depending on the device, an extra original may remain
in the iPhone's Media recovery area. The recovery record reports whether it
was retained and records SHA-256 for each Mac backup. Keep the Mac recovery
folder, and any retained iPhone copies, until you have checked the card in
Wallet. AirTraffic can report a successful operation even when a device file
did not move; a successful export cannot guarantee Wallet will display the
same artwork without checking it on the iPhone.

The UI cache is stored under `~/Library/Application Support/AirCard/ArtworkCache/`.
Its files are checked against their saved SHA-256 hashes before display; the
separate Recovery folder keeps the copies used to restore card resources.

### If scanning finds no cards

The scanner uses the iPhone's unified log service, including Info/Debug events,
to identify Wallet card-artwork resource paths.
On iOS 18.6.2, the legacy log service can show Wallet activity while omitting the
resource lookup messages that contain card identifiers.

Open **Log** and check for `Connected to the unified device log stream`, then
double-click the side button, authenticate, and tap or switch cards. If the log
reader stops, reconnect and unlock the iPhone, then start another scan. Values
that iOS replaces with `<private>` cannot be recovered by the scanner.

If your device previously connected but scanning found zero cards, please try
this build and report whether it helps. Include your iPhone model, iOS version,
macOS version, and the AirCard version or commit tested. Avoid posting full
device logs or card identifiers. See [scanner validation](docs/wallet-card-detection.md)
for the verified environment and remaining coverage.

---

## Building from Source

### Tauri desktop client — Windows and macOS

Follow the [local build guide / Windows 依赖与双端构建指南](docs/desktop-build.md)
for complete PowerShell and macOS shell commands. Build Windows NSIS packages on
Windows 11 x64 and macOS app / DMG packages on native arm64 or Intel Macs.
Builds and validation run locally; this project does not use GitHub Actions / CI.

The desktop client uses Node.js 22, pnpm 11.7.0, Rust 1.98.1 and Python 3.12.
Windows additionally needs the VS 2022 C++ Build Tools and WebView2; macOS needs
Xcode Command Line Tools and the native helper built with `make all`.
After dependency installation and tests, run `pnpm package:backend`, then
`pnpm bundle` from `desktop/`; on macOS add
`--config src-tauri/tauri.macos.conf.json`. The full guide covers interpreter
selection, architecture matching, output paths and installed-app validation.

### Original SwiftUI app — macOS only

The following builds the original app. Its script cleans the entire `build/`
directory first; use a separate checkout or preserve existing desktop artifacts.

```sh
git clone https://github.com/Amethystos325/AirCard.git
cd AirCard
chmod +x build.sh
./build.sh
```
This builds universal binaries (`arm64` + `x86_64`), bundles dependencies into `build/AirCard.app`, and outputs `build/AirCard.dmg`.

---

## Contributors
- **[@mak5er](https://github.com/mak5er)** (Developer) — [GitHub](https://github.com/mak5er) · [Twitter / X](https://x.com/mak5er)
- **[@Lumid-Off](https://github.com/Lumid-Off)** (Contributor & Developer) — [GitHub](https://github.com/Lumid-Off) · [Twitter / X](https://x.com/LumidOff)
- **[AirLift](https://github.com/0xjohnnydev/airlift)** by **[0xjohnny (@0xjohnnydev)](https://github.com/0xjohnnydev)**: Original AirTraffic/ATAirlock sandbox escape and proof of concept underlying `AirliftFFI`.

## Credits
- Core exploit based on `airlift` (AirTraffic sync escape).

---

## Support

If you find AirCard useful, you can support future development:

- **PayPal**: [Donate via PayPal](https://www.paypal.com/donate/?hosted_button_id=98QRTC2HFRA4Y)
- **TON**: `UQBm9KPhtMw-XVVjirUoa09wzrlyWsbeZhKfefl1Uw-qNZ-r`
- **USDT (TRC20)**: `TDkDMCyjYxgvkWUnQiF5Erk2RyPQMT6G1n`
- **USDT / BNB (BEP20)**: `0x0954dc491c502849d04956ef74634aa5931a08e8`

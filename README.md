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
- 🚀 **Standalone macOS bundles:** Build on Apple Silicon or Intel; the matching device tools and image engine are bundled. A universal SwiftUI bundle can be made with both architecture-specific Python environments.
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

### macOS DMG
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
4. Click **更换卡面** below a card, or drag an image onto it. Adjust the crop, generate a preview, then click **应用卡面** to write it to the iPhone.
5. Force-close the **Wallet** app on your iPhone from the App Switcher (or reboot) to see your new custom card design!

The scanner verifies each detected pass by reading its `pass.json`. It adds
payment cards and Secure Element transit cards with `paymentCard` or
`transitCard` metadata, and skips ordinary store cards, coupons, tickets, and
other barcode passes. If the type cannot be verified, it is not added. Legacy
card identifiers are retained as unassigned candidates; scan again with the
connected iPhone to associate them with a device. Verification takes longer
than log detection because each file is backed up and restored on the device.

### Read, back up, and restore card artwork

Click **读取卡面** to read the current card artwork. The first successful read
(or the backup taken before the first change) is kept as a verified, immutable
backup for that device and card. The detail sheet can export this first backup
as a ZIP or restore it to the iPhone. A later read updates the displayed current
artwork without replacing the first backup. The transaction engine tracks
whether each of the three combined artwork files originally existed:
`cardBackgroundCombined@3x.png`, `cardBackgroundCombined@2x.png`, and
`cardBackgroundCombined.pdf`.

Before any write, AirCard saves and verifies a snapshot. If a device operation
fails, it attempts to roll back the card and temporary Books files. If it
cannot finish safely, reconnect the same iPhone and use **继续恢复**. Card changes
remain unavailable for that device until recovery completes. The card records,
first backups, and transaction state are under
`~/Library/Application Support/AirCardDesktop/`. The earlier Swift backend's
manifest-wide resource export code remains in the repository but is not exposed
by the new SwiftUI transaction interface.

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

### SwiftUI app — macOS only

The SwiftUI app keeps its original native layout and now uses the same
recoverable card-operation backend as the Windows/macOS desktop client. It has
crop preview before applying, a verified first backup with restore, pending
transaction recovery, device-bound cards, and language and appearance controls.
The two macOS apps share `~/Library/Application Support/AirCardDesktop/` card
records. Legacy Swift card identifiers are copied as unassigned candidates;
rescan them with the connected iPhone to establish device ownership.

Install Python 3.12 and the locked desktop dependencies before building:

```sh
git clone https://github.com/Amethystos325/AirCard.git
cd AirCard
python3.12 -m venv .venv
.venv/bin/python -m pip install -r requirements-desktop.lock
chmod +x build.sh
./build.sh
```
This builds for the current Mac architecture and produces `build/AirCard.app`
and `build/AirCard.dmg`. For a universal SwiftUI app, provide an arm64 and an
x86_64 Python 3.12 environment with the locked dependencies on an Apple Silicon
Mac with Rosetta, then set
`AIRCARD_PYTHON_ARM64`, `AIRCARD_PYTHON_X86_64`, and
`AIRCARD_SWIFT_ARCHES="arm64 x86_64"` when running `build.sh`. The app bundle
includes one frozen backend per architecture. macOS card read, apply, restore,
and recovery operations still require real-device validation on the target
Mac/iOS build; a successful build does not establish device compatibility.

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

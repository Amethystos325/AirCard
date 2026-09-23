# AirCard 🎴

> **Apple Wallet Card Skinner for iOS 18+ (No Jailbreak Required)**
> **Tested on iOS 27 release.**
> Powered by the `airlift` AirTraffic sync exploit.

<p align="left">
  <a href="https://www.paypal.com/donate/?hosted_button_id=98QRTC2HFRA4Y"><img src="https://img.shields.io/badge/Donate-PayPal-00457C?style=flat-square&logo=paypal" alt="Donate with PayPal" /></a>
</p>

---

## Features
- 🎨 **Custom Card Skins:** Assign custom artwork, textures, or bank logos to Apple Pay and Wallet cards.
- ⚡ **Per-Card & Bulk Customization:** Set unique artwork for each card or apply one design across all cards with a single click.
- 📱 **Card Detection:** Select a card in your iPhone's Wallet app to identify its card identifier from Wallet resource paths.
- 🚀 **100% Standalone (Universal):** Native support for both **Apple Silicon** and **Intel (x86)** Macs. All required device-communication utilities and image engines are pre-bundled inside the app.
- 📦 **Zero Prerequisites:** No Homebrew, Python packages, or terminal setup required for macOS users.

---

## Installation

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
4. Click on any card mockup or drag & drop an image directly onto the card.
5. Click **Flash Skins**.
6. Force-close the **Wallet** app on your iPhone from the App Switcher (or reboot) to see your new custom card design!

### Export card artwork

Connect the iPhone and click **读取卡面** below a card to copy and cache its
current artwork files. The preview appears on the card and remains available
after restarting AirCard. Click **查看大图** to inspect the full-size cached image. A
skin selected for flashing is displayed separately from the cached artwork.

Click **提取卡面** to save a ZIP of card artwork. This also updates the cache and
refreshes the preview. AirCard tries the card's three fixed artwork assets:
`cardBackgroundCombined@3x.png`, `cardBackgroundCombined@2x.png`, and
`cardBackgroundCombined.pdf`. It tries each file independently and puts every
successfully read file in the ZIP. The result lists files that were unavailable.
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

#!/usr/bin/env bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$SCRIPT_DIR"

echo "==> [1/6] Building universal helper binaries (device_helper & airtraffic_host)..."
make -C frontend/swift all

APP_NAME="DittoCard"
APP_DIR="build/${APP_NAME}.app"
CONTENTS_DIR="${APP_DIR}/Contents"
MACOS_DIR="${CONTENTS_DIR}/MacOS"
RESOURCES_DIR="${CONTENTS_DIR}/Resources"
BIN_DIR="${RESOURCES_DIR}/bin"
LIB_DIR="${RESOURCES_DIR}/lib"

echo "==> [2/6] Scaffolding ${APP_NAME}.app bundle structure..."
rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR" "$BIN_DIR" "$LIB_DIR" "${RESOURCES_DIR}/zh-Hans.lproj"

# Write Info.plist
cat << 'EOF' > "${CONTENTS_DIR}/Info.plist"
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleExecutable</key>
    <string>DittoCard</string>
    <key>CFBundleIdentifier</key>
    <string>com.mak5er.aircard</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>DittoCard</string>
    <key>CFBundleDisplayName</key>
    <string>DittoCard</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>0.2</string>
    <key>CFBundleVersion</key>
    <string>8</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
</dict>
</plist>
EOF

cat << 'EOF' > "${RESOURCES_DIR}/zh-Hans.lproj/InfoPlist.strings"
"CFBundleDisplayName" = "DittoCard";
"CFBundleName" = "DittoCard";
EOF

echo "==> [3/6] Bundling universal tools & libraries..."
# Generate the macOS icon from the same PNG used in the Swift header.
ICONSET_DIR="$SCRIPT_DIR/build/BrandIcon.iconset"
rm -rf "$ICONSET_DIR"
mkdir -p "$ICONSET_DIR"
for point in 16 32 128 256 512; do
    sips -z "$point" "$point" "frontend/swift/assets/BrandIcon.png" --out "$ICONSET_DIR/icon_${point}x${point}.png" >/dev/null
    doubled=$((point * 2))
    sips -z "$doubled" "$doubled" "frontend/swift/assets/BrandIcon.png" --out "$ICONSET_DIR/icon_${point}x${point}@2x.png" >/dev/null
done
iconutil --convert icns --output "${RESOURCES_DIR}/AppIcon.icns" "$ICONSET_DIR"
cp "frontend/swift/assets/BrandIcon.png" "${RESOURCES_DIR}/BrandIcon.png"

# Copy universal device_helper and airtraffic_host. Device discovery and log
# streaming both run through device_helper, which talks to MobileDevice.framework
# directly, so the bundle needs no libimobiledevice tooling.
cp build/device_helper "$BIN_DIR/"
cp build/airtraffic_host "$BIN_DIR/"

# Package the recoverable transaction engine for each requested architecture.
# A native build is the default. Supply AIRCARD_PYTHON_ARM64 and
# AIRCARD_PYTHON_X86_64 plus AIRCARD_SWIFT_ARCHES="arm64 x86_64" for a
# universal app; each interpreter must have the locked desktop dependencies.
SWIFT_ARCHES="${AIRCARD_SWIFT_ARCHES:-$(uname -m)}"
for arch in $SWIFT_ARCHES; do
    case "$arch" in arm64|x86_64) ;; *) echo "Unsupported architecture: $arch" >&2; exit 1 ;; esac
    if [ "$arch" = "arm64" ]; then variable="AIRCARD_PYTHON_ARM64"; else variable="AIRCARD_PYTHON_X86_64"; fi
    python="${!variable:-}"
    if [ -z "$python" ] && [ "$arch" = "$(uname -m)" ]; then python="${AIRCARD_PYTHON:-$SCRIPT_DIR/.venv/bin/python}"; fi
    if [ -z "$python" ] || [ ! -x "$python" ]; then
        echo "Set $variable to a Python 3.12 interpreter with desktop dependencies." >&2
        exit 1
    fi
    echo "Packaging $arch transaction backend with $python..."
    arch -"$arch" "$python" -m PyInstaller --noconfirm --clean \
        --distpath "$SCRIPT_DIR/build/swift-backend-$arch" \
        --workpath "$SCRIPT_DIR/build/swift-pyinstaller-$arch" \
        backend/aircard-backend.macos.spec
    package="$SCRIPT_DIR/build/swift-backend-$arch/aircard-backend"
    mkdir -p "$package/_internal/bin" "$RESOURCES_DIR/backend/$arch"
    # Restore the signed helper after PyInstaller modifies bundled Mach-O files.
    cp "$SCRIPT_DIR/build/airtraffic_host" "$package/_internal/bin/airtraffic_host"
    cp -R "$package/." "$RESOURCES_DIR/backend/$arch/"
done

# A bundle without these cannot talk to a device at all, so fail here instead
# of shipping an app that reports "No iPhone found" for every user.
for tool in device_helper airtraffic_host; do
    if [ ! -x "${BIN_DIR}/${tool}" ]; then
        echo "ERROR: ${BIN_DIR}/${tool} is missing from the bundle." >&2
        exit 1
    fi
done

echo "==> [4/6] Compiling Swift binary ($SWIFT_ARCHES)..."
if [ -z "${SWIFT_SDK:-}" ]; then
    SWIFT_SDK="$(xcrun --sdk macosx --show-sdk-path)"
    CLT_SWIFTUI_SDK="/Library/Developer/CommandLineTools/SDKs/MacOSX26.sdk"
    if [ "$(xcode-select -p)" = "/Library/Developer/CommandLineTools" ] && [ -d "$CLT_SWIFTUI_SDK" ]; then
        SWIFT_SDK="$CLT_SWIFTUI_SDK"
    fi
fi
outputs=()
for arch in $SWIFT_ARCHES; do
    swiftc -sdk "$SWIFT_SDK" -O -parse-as-library -target "$arch-apple-macosx14.0" \
        frontend/swift/swiftui/AirCardApp.swift frontend/swift/swiftui/SwiftCardModel.swift \
        frontend/swift/swiftui/SwiftDesktopBridge.swift frontend/swift/swiftui/SwiftAppLifecycle.swift \
        -o "build/${APP_NAME}_$arch"
    outputs+=("build/${APP_NAME}_$arch")
done
if [ "${#outputs[@]}" -eq 1 ]; then
    cp "${outputs[0]}" "${MACOS_DIR}/${APP_NAME}"
else
    lipo -create -output "${MACOS_DIR}/${APP_NAME}" "${outputs[@]}"
fi
chmod +x "${MACOS_DIR}/${APP_NAME}"

echo "==> [5/6] Setting permissions and signing ${APP_NAME}.app bundle..."
chmod -R 755 "$APP_DIR"
xattr -cr "$APP_DIR" 2>/dev/null || true
codesign --force --deep --sign - "$APP_DIR"

echo "==> [6/6] Generating styled DMG (${APP_NAME}.dmg)..."
DMG_STAGING="/tmp/dittocard_dmg_staging"
rm -rf "$DMG_STAGING"
mkdir -p "$DMG_STAGING"
cp -R "$APP_DIR" "$DMG_STAGING/"

rm -f "build/${APP_NAME}.dmg"

if command -v create-dmg >/dev/null 2>&1; then
    create-dmg \
        --volname "$APP_NAME" \
        --background "frontend/swift/assets/background_700.png" \
        --window-pos 200 120 \
        --window-size 700 460 \
        --icon-size 110 \
        --icon "${APP_NAME}.app" 175 220 \
        --hide-extension "${APP_NAME}.app" \
        --app-drop-link 525 220 \
        --add-file "README.md" "frontend/swift/assets/README.md" 350 360 \
        --filesystem APFS \
        --overwrite \
        "build/${APP_NAME}.dmg" \
        "$DMG_STAGING"
else
    ln -s /Applications "$DMG_STAGING/Applications"
    cp "frontend/swift/assets/README.md" "$DMG_STAGING/README.md"
    hdiutil create -volname "$APP_NAME" -srcfolder "$DMG_STAGING" -ov -format UDZO "build/${APP_NAME}.dmg"
fi

echo "============================================================"
echo "🎉 SUCCESS: build/${APP_NAME}.dmg is ready!"
echo "============================================================"

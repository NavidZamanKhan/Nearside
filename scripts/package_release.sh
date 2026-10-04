#!/bin/bash
set -e

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$DIR"

echo "=================================================="
echo "  Nearside: Production Release Packaging Pipeline"
echo "=================================================="

# 1. Build macOS Host App and Share Extension
echo "[1/4] Building and signing macOS application..."
./scripts/build_macos.sh > /dev/null

# 2. Package macOS DMG
echo "[2/4] Packaging macOS Drag-and-Drop Disk Image (DMG)..."
RELEASE_DIR="build/release"
DMG_STAGING="$RELEASE_DIR/dmg_staging"
rm -rf "$RELEASE_DIR"
mkdir -p "$DMG_STAGING"

cp -R "build/macos/Nearside.app" "$DMG_STAGING/"
ln -s /Applications "$DMG_STAGING/Applications"

if command -v diskutil >/dev/null && diskutil image create from --help >/dev/null 2>&1; then
    diskutil image create from --volumeName "Nearside" --format UDZO "$DMG_STAGING" "$RELEASE_DIR/Nearside.dmg" > /dev/null
else
    hdiutil create -volname "Nearside" -srcfolder "$DMG_STAGING" -ov -format UDZO "$RELEASE_DIR/Nearside.dmg" > /dev/null
fi
rm -rf "$DMG_STAGING"

# 3. Build Android Release APK
echo "[3/4] Building optimized Android release APK..."
(cd apps/android && ./gradlew assembleRelease --no-daemon > /dev/null)
(cd apps/android && ./gradlew --stop > /dev/null 2>&1 || true)

ANDROID_RELEASE_APK="apps/android/app/build/outputs/apk/release/app-release-unsigned.apk"
if [ -f "$ANDROID_RELEASE_APK" ]; then
    cp "$ANDROID_RELEASE_APK" "$RELEASE_DIR/Nearside-release.apk"
else
    echo "ERROR: Android release APK was not found at $ANDROID_RELEASE_APK"
    exit 1
fi

# 4. Generate Authoritative SHA-256 Checksums
echo "[4/4] Generating SHA-256 checksum manifest..."
(cd "$RELEASE_DIR" && shasum -a 256 Nearside.dmg Nearside-release.apk > checksums.txt)

echo "=================================================="
echo "  Release Artifacts Generated in $RELEASE_DIR/:"
ls -lh "$RELEASE_DIR"
echo "=================================================="

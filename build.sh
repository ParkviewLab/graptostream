#!/bin/sh
# SPDX-FileCopyrightText: 2026 Gary Frattarola <garyf@parkviewlab.ai>
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Builds Graptostream.app (Apple silicon) from the Swift package and signs it.
# The version is read from VERSION.txt.
#
# Signing identity, in this order:
#   SIGN_IDENTITY set           that identity, with the hardened runtime and a timestamp
#                               (CI sets it to the Developer ID Application identity)
#   an "Apple Development" one  in the login keychain, for local builds, so that the
#                               microphone permission survives rebuilds
#   otherwise                   ad hoc ("-"), as on a CI runner without the secrets
set -e
cd "$(dirname "$0")"
VERSION=$(tr -d '[:space:]' < VERSION.txt)
APP=Graptostream.app
swift build -c release --arch arm64
BIN=$(swift build -c release --arch arm64 --show-bin-path)/Graptostream
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Graptostream"
cp brand/app-icon/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cat > "$APP/Contents/Info.plist" <<P
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleName</key><string>graptostream</string>
<key>CFBundleDisplayName</key><string>graptostream</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundleExecutable</key><string>Graptostream</string>
<key>CFBundleIdentifier</key><string>ai.parkviewlab.graptostream</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>$VERSION</string>
<key>CFBundleVersion</key><string>$VERSION</string>
<key>LSMinimumSystemVersion</key><string>26.0</string>
<key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSMicrophoneUsageDescription</key><string>graptostream listens to the microphones you select and turns what is said into text for other apps.</string>
<key>NSLocalNetworkUsageDescription</key><string>graptostream serves its text stream to apps on other machines on your network, when you switch that on.</string>
<key>NSBonjourServices</key><array><string>_graptostream._tcp</string></array>
<key>NSHumanReadableCopyright</key><string>© 2026 Gary Frattarola · AGPL-3.0-or-later</string>
</dict></plist>
P

IDENTITY="$SIGN_IDENTITY"
if [ -z "$IDENTITY" ]; then
  IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null | sed -n 's/.*"\(Apple Development: [^"]*\)".*/\1/p' | head -n 1)
fi
if [ -n "$SIGN_IDENTITY" ]; then
  codesign --force --options runtime --timestamp --entitlements Graptostream.entitlements --sign "$IDENTITY" "$APP"
elif [ -n "$IDENTITY" ]; then
  codesign --force --options runtime --entitlements Graptostream.entitlements --sign "$IDENTITY" "$APP"
else
  codesign --force --options runtime --entitlements Graptostream.entitlements --sign - "$APP"
  IDENTITY="ad hoc"
fi
codesign --verify --strict "$APP"
echo "built $APP $VERSION, signed by $IDENTITY"

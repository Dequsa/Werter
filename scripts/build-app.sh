#!/bin/zsh
# Builds build/File Converter.app from the Swift package.
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${1:-release}"
APP="build/File Converter.app"

swift build -c "$CONFIG"
BIN="$(swift build -c "$CONFIG" --show-bin-path)/FileConverter"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/FileConverter"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>File Converter</string>
    <key>CFBundleDisplayName</key><string>File Converter</string>
    <key>CFBundleIdentifier</key><string>com.kacper.FileConverter</string>
    <key>CFBundleExecutable</key><string>FileConverter</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
    <key>CFBundleDocumentTypes</key>
    <array>
        <dict>
            <key>CFBundleTypeName</key><string>Image</string>
            <key>CFBundleTypeRole</key><string>Viewer</string>
            <key>LSHandlerRank</key><string>Alternate</string>
            <key>LSItemContentTypes</key>
            <array>
                <string>public.image</string>
            </array>
        </dict>
    </array>
</dict>
</plist>
PLIST

# macOS remembers privacy permissions (Desktop, Documents…) by the app's code signature.
# An Apple Development certificate keeps that stable across rebuilds. Without one, sign
# ad-hoc but pin the requirement to the bundle ID so each rebuild isn't a "new" app.
IDENTITY="$(security find-identity -v -p codesigning | awk -F'"' '/Apple Development/ { print $2; exit }')"
if [[ -n "$IDENTITY" ]]; then
    codesign --force --options runtime --sign "$IDENTITY" "$APP" >/dev/null
    echo "Signed with $IDENTITY"
else
    codesign --force --sign - -r='designated => identifier "com.kacper.FileConverter"' "$APP" >/dev/null
    echo "Signed ad-hoc (no Apple Development certificate found)"
fi
echo "Built $APP"

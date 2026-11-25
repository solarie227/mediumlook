#!/bin/bash
# 中判ルック.app を作る（Xcode もしくは Command Line Tools が必要）
set -euo pipefail
cd "$(dirname "$0")"

# Command Line Tools が選ばれていても、Xcode があればそちらでビルドする
# （新しいSDKの SwiftUI マクロ（@State など）の実装は Xcode にしか入っていないため）
if [ -z "${DEVELOPER_DIR:-}" ] && [[ "$(xcode-select -p 2>/dev/null)" == *CommandLineTools* ]]; then
    XCODE=$(ls -d /Applications/Xcode*.app 2>/dev/null | sort | tail -n 1 || true)
    if [ -n "$XCODE" ]; then
        export DEVELOPER_DIR="$XCODE/Contents/Developer"
        echo "Xcode を使ってビルドします: $XCODE"
    fi
fi

swift build -c release
BIN_DIR=$(swift build -c release --show-bin-path)

APP="build/MediumLook.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/MediumLook" "$APP/Contents/MacOS/MediumLook"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>MediumLook</string>
    <key>CFBundleIdentifier</key><string>local.mediumlook.app</string>
    <key>CFBundleName</key><string>MediumLook</string>
    <key>CFBundleDisplayName</key><string>中判ルック</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.2</string>
    <key>CFBundleVersion</key><string>2</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.photography</string>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

# 自分のMacで使うためのアドホック署名
codesign --force --deep --sign - "$APP"
echo "できあがり: $(pwd)/$APP"

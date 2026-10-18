#!/bin/bash
# Builds build/LiveSky.app (menu bar app + embedded WeatherUI renderer) and dist/LiveSky.zip.
# Needs Xcode (for the Mac Catalyst SDK); the result is ad-hoc signed and Apple silicon only.
set -euo pipefail
cd "$(dirname "$0")"
root="$PWD"

if [[ -z "${DEVELOPER_DIR:-}" && -d /Applications/Xcode.app/Contents/Developer ]]; then
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi
sdk="$(xcrun --sdk macosx --show-sdk-path)"
catalyst_frameworks="$sdk/System/iOSSupport/System/Library/Frameworks"
if [[ ! -d "$catalyst_frameworks/UIKit.framework" ]]; then
  echo "error: the Mac Catalyst SDK was not found. Install Xcode or set DEVELOPER_DIR." >&2
  exit 1
fi

build="$root/build"
objects="$build/obj"
app="$build/LiveSky.app"
renderer="$app/Contents/Helpers/LiveSkyRenderer.app"
rm -rf "$app" "$objects"
mkdir -p "$objects/modules-catalyst" "$objects/modules-macos" \
  "$app/Contents/MacOS" "$app/Contents/Resources" "$renderer/Contents/MacOS"

echo "==> renderer (Mac Catalyst)"
# Built the same way as the verified research renderer: arm64 Catalyst, no optimisation.
xcrun clang -fobjc-arc -target arm64-apple-ios16.0-macabi -isysroot "$sdk" \
  -F "$catalyst_frameworks" -c Sources/Renderer/bridge.m -o "$objects/bridge.o"
xcrun swiftc -target arm64-apple-ios16.0-macabi -sdk "$sdk" \
  -Fsystem "$catalyst_frameworks" -I "$sdk/System/iOSSupport/usr/lib/swift" \
  -module-cache-path "$objects/modules-catalyst" \
  -import-objc-header Sources/Renderer/bridge.h Sources/Renderer/main.swift \
  "$objects/bridge.o" -o "$renderer/Contents/MacOS/LiveSkyRenderer"
cp Resources/Renderer-Info.plist "$renderer/Contents/Info.plist"
printf 'APPL????' > "$renderer/Contents/PkgInfo"

echo "==> LiveSky app"
xcrun swiftc -O -swift-version 5 -target arm64-apple-macos13.0 -sdk "$sdk" \
  -module-name LiveSky -module-cache-path "$objects/modules-macos" \
  Sources/LiveSky/*.swift -o "$app/Contents/MacOS/LiveSky"
cp Resources/Info.plist "$app/Contents/Info.plist"
printf 'APPL????' > "$app/Contents/PkgInfo"
for language in en zh-Hans; do
  mkdir -p "$app/Contents/Resources/$language.lproj"
  for strings in Resources/"$language".lproj/*.strings; do
    plutil -convert binary1 -o "$app/Contents/Resources/$language.lproj/$(basename "$strings")" "$strings"
  done
done
if [[ -f Resources/AppIcon.icns ]]; then
  cp Resources/AppIcon.icns "$app/Contents/Resources/AppIcon.icns"
fi

echo "==> ad-hoc signing"
# Sign the nested helper first; the app's signature then seals it.
codesign --force --sign - --timestamp=none "$renderer"
codesign --force --sign - --timestamp=none "$app"
codesign --verify --deep --strict "$app"

echo "==> dist/LiveSky.zip"
# The zip holds only LiveSky.app, so unzipping it (Safari does this by itself) gives the app.
mkdir -p dist
rm -f dist/LiveSky.zip
# No extended attributes: they only carry this Mac's com.apple.provenance and would add a
# __MACOSX folder for other unzip tools. The code signature does not depend on them.
ditto -c -k --norsrc --noextattr --keepParent "$app" dist/LiveSky.zip

echo "built $app"
echo "packed $root/dist/LiveSky.zip ($(du -h dist/LiveSky.zip | cut -f1 | tr -d ' '))"

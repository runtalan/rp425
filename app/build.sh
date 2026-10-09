#!/bin/sh
# Builds build/Ember.app: the native SwiftUI settings app (universal arm64 + x86_64).
# The bundle carries its own copy of the PPD and the rp425 tool: apps launched from Finder can't read
# an external volume, so nothing is looked up from the source tree at run time.
#   sh app/build.sh          (run `make` first so build/rp425 exists)
set -e
ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"
APP=build/Ember.app
SWIFTFLAGS="-swift-version 5 -enable-bare-slash-regex -parse-as-library -O"
[ -x build/rp425 ] || { echo "build/rp425 missing — run make first"; exit 1; }

mkdir -p build/ember
for arch in arm64 x86_64; do
  swiftc $SWIFTFLAGS -target $arch-apple-macos13 -o build/ember/Ember-$arch app/Sources/*.swift
done
swiftc -O -o build/makeicon app/tools/makeicon.swift
build/makeicon build/Ember.icns

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
lipo -create -output "$APP/Contents/MacOS/Ember" build/ember/Ember-arm64 build/ember/Ember-x86_64
cp build/Ember.icns "$APP/Contents/Resources/Ember.icns"
cp ppd/RP425.ppd "$APP/Contents/Resources/RP425.ppd"
cp build/rp425 "$APP/Contents/Resources/rp425"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>Ember</string>
  <key>CFBundleDisplayName</key><string>Ember</string>
  <key>CFBundleIdentifier</key><string>local.rp425.ember</string>
  <key>CFBundleExecutable</key><string>Ember</string>
  <key>CFBundleIconFile</key><string>Ember</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
</dict></plist>
PLIST
codesign --force --deep -s - "$APP" 2>/dev/null
echo "Built $APP"

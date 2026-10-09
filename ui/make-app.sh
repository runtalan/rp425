#!/bin/sh
# Builds "RP425 Settings.app" (default: ~/Applications). Opening it starts the settings
# server if it isn't running and opens the page in your browser.
# The app carries its own copy of the script, PPD and test-label tool: macOS won't let
# apps launched from Finder/Spotlight read an external volume. Re-run after changing them.
#   sh ui/make-app.sh [destination-dir]
set -e
ROOT=$(cd "$(dirname "$0")/.." && pwd)
DEST=${1:-$HOME/Applications}
APP="$DEST/RP425 Settings.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/ui" "$APP/Contents/Resources/ppd" "$APP/Contents/Resources/build"
cp "$ROOT/ui/rp425-ui.py" "$APP/Contents/Resources/ui/"
cp "$ROOT/ppd/RP425.ppd" "$APP/Contents/Resources/ppd/"
[ -x "$ROOT/build/mkpdf" ] && cp "$ROOT/build/mkpdf" "$APP/Contents/Resources/build/" || true
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>RP425 Settings</string>
  <key>CFBundleIdentifier</key><string>local.rp425.settings</string>
  <key>CFBundleExecutable</key><string>launch</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>LSUIElement</key><true/>
</dict></plist>
PLIST
cat > "$APP/Contents/MacOS/launch" <<LAUNCH
#!/bin/sh
URL=http://127.0.0.1:8425/
if ! /usr/bin/curl -s -o /dev/null "\$URL"; then
  nohup /usr/bin/python3 "\$(dirname "\$0")/../Resources/ui/rp425-ui.py" --no-open >/tmp/rp425-ui.log 2>&1 &
  for i in 1 2 3 4 5 6 7 8 9 10; do /usr/bin/curl -s -o /dev/null "\$URL" && break; sleep 0.3; done
fi
exec /usr/bin/open "\$URL"
LAUNCH
chmod +x "$APP/Contents/MacOS/launch"
echo "Built $APP"

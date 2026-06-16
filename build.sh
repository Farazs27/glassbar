#!/bin/bash
# Build GlassBar, assemble the .app bundle, install to ~/Applications,
# and (re)install + start the login LaunchAgent.
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"
cd "$HERE"

APPNAME="GlassBar"
BUNDLE_ID="com.faraz.glassbar"
INSTALL_DIR="$HOME/Applications"
APP="$INSTALL_DIR/$APPNAME.app"

echo "▶ Building $APPNAME (release)…"
swift build -c release
BIN=".build/release/$APPNAME"
[ -f "$BIN" ] || { echo "✗ build failed: $BIN missing"; exit 1; }

echo "▶ Assembling app bundle…"
mkdir -p "$INSTALL_DIR"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/$APPNAME"
cp "packaging/Info.plist" "$APP/Contents/Info.plist"
cp "Resources/glassbar-usage.sh" "$APP/Contents/Resources/"
chmod +x "$APP/Contents/Resources/glassbar-usage.sh"
codesign --force --deep --sign - "$APP" 2>/dev/null || true   # ad-hoc identity for TCC

echo "▶ Installing LaunchAgent (auto-start at login)…"
LA="$HOME/Library/LaunchAgents/$BUNDLE_ID.plist"
cat > "$LA" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>$BUNDLE_ID</string>
  <key>ProgramArguments</key><array>
    <string>$APP/Contents/MacOS/$APPNAME</string>
  </array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><false/>
  <key>ProcessType</key><string>Interactive</string>
  <key>LimitLoadToSessionType</key><string>Aqua</string>
</dict></plist>
PLIST

launchctl bootout "gui/$(id -u)/$BUNDLE_ID" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$LA" 2>/dev/null || true

echo "▶ Launching…"
launchctl kickstart -k "gui/$(id -u)/$BUNDLE_ID" 2>/dev/null || open "$APP"
echo "✓ Done → $APP"

#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

DISPLAY_NAME="路由切换器"
echo "→ Building ${DISPLAY_NAME} (release)…"
swift build -c release --disable-sandbox

APP="$ROOT/.build/${DISPLAY_NAME}.app"
CONTENTS="$APP/Contents"
MACOS="$CONTENTS/MacOS"
RESOURCES="$CONTENTS/Resources"

rm -rf "$APP"
# 清理旧名
rm -rf "$ROOT/.build/ProcessRoute.app" "$ROOT/.build/进程路由.app" 2>/dev/null || true

mkdir -p "$MACOS" "$RESOURCES"

cp "$ROOT/.build/release/ProcessRoute" "$MACOS/ProcessRoute"

# 图标
if [ -f "$ROOT/Resources/AppIcon.icns" ]; then
  cp "$ROOT/Resources/AppIcon.icns" "$RESOURCES/AppIcon.icns"
elif [ -d "$ROOT/Resources/AppIcon.iconset" ] && command -v iconutil >/dev/null 2>&1; then
  iconutil -c icns "$ROOT/Resources/AppIcon.iconset" -o "$RESOURCES/AppIcon.icns"
fi

cat > "$CONTENTS/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key>
  <string>ProcessRoute</string>
  <key>CFBundleIdentifier</key>
  <string>local.processroute</string>
  <key>CFBundleName</key>
  <string>${DISPLAY_NAME}</string>
  <key>CFBundleDisplayName</key>
  <string>${DISPLAY_NAME}</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleIconFile</key>
  <string>AppIcon</string>
  <key>CFBundleShortVersionString</key>
  <string>1.3.0</string>
  <key>CFBundleVersion</key>
  <string>3</string>
  <key>LSMinimumSystemVersion</key>
  <string>14.0</string>
  <key>NSHighResolutionCapable</key>
  <true/>
  <key>LSApplicationCategoryType</key>
  <string>public.app-category.utilities</string>
  <key>NSPrincipalClass</key>
  <string>NSApplication</string>
  <key>LSUIElement</key>
  <false/>
</dict>
</plist>
PLIST

# 让 Finder/Dock 显示自定义图标
if [ -f "$RESOURCES/AppIcon.icns" ]; then
  # 触达图标缓存
  touch "$APP"
fi

if command -v codesign >/dev/null 2>&1; then
  codesign --force --deep --sign - "$APP" 2>/dev/null || true
fi

echo "✓ App: $APP"
echo "  打开: open \"$APP\""

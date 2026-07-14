#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

DISPLAY_NAME="路由切换器"
# 版本号：年-月日-时分秒（月日合并），例如 2026-0714-153045
VERSION="${APP_VERSION:-$(date +%Y-%m%d-%H%M%S)}"
BUILD_NUMBER="$(date +%Y%m%d%H%M%S)"

echo "→ Building ${DISPLAY_NAME} (release) version ${VERSION}…"

# 写入源码回退版本，保证无 Info.plist 时也能读到
VERSION_SWIFT="$ROOT/Sources/AppVersion.swift"
if [[ -f "$VERSION_SWIFT" ]]; then
  # 只替换 buildDateFallback 常量
  if grep -q 'static let buildDateFallback' "$VERSION_SWIFT"; then
    sed -i '' -E "s/static let buildDateFallback = \"[^\"]*\"/static let buildDateFallback = \"${VERSION}\"/" "$VERSION_SWIFT"
  fi
fi

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
  <string>${VERSION}</string>
  <key>CFBundleVersion</key>
  <string>${BUILD_NUMBER}</string>
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
  touch "$APP"
fi

if command -v codesign >/dev/null 2>&1; then
  codesign --force --deep --sign - "$APP" 2>/dev/null || true
fi

echo "✓ App: $APP"
echo "  版本: ${VERSION}"
echo "  打开: open \"$APP\""

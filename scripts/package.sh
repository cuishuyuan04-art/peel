#!/bin/bash
# 打包成可以发给朋友的 DMG：通用版（Apple 芯片 + Intel），带安装说明
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/env.sh

VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" Resources/Info.plist)
mkdir -p Build
DMG="Build/Peel-$VERSION.dmg"

echo "→ 编译通用版（Apple 芯片 + Intel）"
assemble_app universal

# 临时文件夹以 .noindex 结尾：系统不会去登记里面的 App 副本（否则启动器里会多出一个个 Peel）
STAGE="$(mktemp -d)/stage.noindex"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/应用程序 Applications"
cp "Docs/安装说明.txt" "$STAGE/安装说明 How to Install.txt"

rm -f "$DMG"
hdiutil create -volname "Peel" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$(dirname "$STAGE")"

echo "✓ 已生成 ${DMG}（$(du -h "$DMG" | cut -f1)）"

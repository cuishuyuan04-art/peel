#!/bin/bash
# 由 AppIcon.swift 渲染图标，生成 Resources/AppIcon.icns（改了图标设计后运行一次）
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/env.sh

swift build -c release --scratch-path "$SCRATCH"
TMP="$(mktemp -d)"
SET="$TMP/AppIcon.iconset"
mkdir -p "$SET"
"$(swift build -c release --scratch-path "$SCRATCH" --show-bin-path)/Peel" --icon "$TMP/icon-1024.png" 1024

for s in 16 32 128 256 512; do
    sips -z $s $s "$TMP/icon-1024.png" --out "$SET/icon_${s}x${s}.png" >/dev/null
    d=$((s * 2))
    sips -z $d $d "$TMP/icon-1024.png" --out "$SET/icon_${s}x${s}@2x.png" >/dev/null
done

iconutil -c icns "$SET" -o Resources/AppIcon.icns
cp "$TMP/icon-1024.png" Resources/AppIcon.png
rm -rf "$TMP"
echo "✓ 已生成 Resources/AppIcon.icns"

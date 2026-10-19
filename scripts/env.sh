# 构建脚本共用的环境设置（被其他脚本 source）
# 只装了命令行工具时，macOS 27 SDK 的 SwiftUI 需要宏插件（只随完整版 Xcode 提供），
# 这种情况下改用 macOS 26 SDK 编译；编出来的 App 在新系统上照样能运行。
CLT=/Library/Developer/CommandLineTools
if [ -z "${SDKROOT:-}" ] && [ "$(xcode-select -p 2>/dev/null)" = "$CLT" ] \
   && ! ls "$CLT/usr/lib/swift/host/plugins" 2>/dev/null | grep -q SwiftUIMacros \
   && [ -d "$CLT/SDKs/MacOSX26.sdk" ]; then
    export SDKROOT="$CLT/SDKs/MacOSX26.sdk"
fi

# 签名：有 Peel 专用证书（scripts/setup_signing.sh 生成）就用它，系统“辅助功能”授权在重新编译后保持有效；
# 没有就用临时签名（每次编译后需要重新授权）
sign_app() {
    local app="$1"
    local kc="$HOME/Library/Application Support/Peel/signing/peel-signing.keychain-db"
    xattr -cr "$app"
    if [ -f "$kc" ]; then
        security unlock-keychain -p peel-local "$kc"
        local id
        id=$(security find-identity -p codesigning "$kc" | awk '/Peel Local Signing/ {print $2; exit}')
        if [ -n "$id" ]; then
            codesign --force --sign "$id" --keychain "$kc" "$app"
            return
        fi
    fi
    codesign --force --sign - "$app"
}

# “文稿”文件夹开启了 iCloud 同步：编译中间文件和 App 都不放在里面
# （iCloud 会给 App 加访达附加属性导致签名失败，也会同步大量编译文件）
SCRATCH="$HOME/Library/Caches/Peel-build"
APP="$HOME/Applications/Peel.app"

# 编译并组装 ~/Applications/Peel.app。参数 universal：同时编 Apple 芯片和 Intel（打包发给别人用）
# 会检查编出来的程序确实比所有源代码都新，避免把旧程序装进 App。
assemble_app() {
    local archs=()
    [ "${1:-}" = "universal" ] && archs=(--arch arm64 --arch x86_64)
    swift build -c release --scratch-path "$SCRATCH" ${archs[@]+"${archs[@]}"}
    local bin
    bin="$(swift build -c release --scratch-path "$SCRATCH" ${archs[@]+"${archs[@]}"} --show-bin-path)/Peel"
    if [ ! -f "$bin" ] || [ -n "$(find Sources Package.swift -newer "$bin" -type f | head -1)" ]; then
        echo "✗ 编译结果不是最新的：$bin" >&2
        return 1
    fi

    local app="$APP"
    mkdir -p "$(dirname "$app")"
    rm -rf "$app"
    mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
    cp "$bin" "$app/Contents/MacOS/Peel"
    cp Resources/Info.plist "$app/Contents/Info.plist"
    [ -f Resources/AppIcon.icns ] && cp Resources/AppIcon.icns "$app/Contents/Resources/AppIcon.icns"
    # 引导动图、中英文本地化（右键服务名称、权限弹窗说明）
    cp -R Resources/Onboarding "$app/Contents/Resources/"
    cp -R Resources/*.lproj "$app/Contents/Resources/"
    # 构建号 = 编译时间，菜单和“关于 Peel”里能看到，一眼区分是哪一次编译
    /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $(date +%Y%m%d.%H%M)" "$app/Contents/Info.plist"
    sign_app "$app"
    echo "  版本 $(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist")" \
         "（构建 $(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$app/Contents/Info.plist")），" \
         "架构：$(lipo -archs "$app/Contents/MacOS/Peel")"
}

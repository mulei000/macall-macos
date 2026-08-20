#!/bin/bash
# 构建 macall：用 swiftc 直接编译（无需完整 Xcode，也避开 SwiftPM 的沙箱限制），
# 组装 .app，固定证书签名，打包 .dmg 到桌面。
set -euo pipefail

cd "$(dirname "$0")"

APP_NAME="macall"
APP_PATH="build/$APP_NAME.app"
BIN="$APP_PATH/Contents/MacOS/$APP_NAME"
RESOURCES="$APP_PATH/Contents/Resources"
DESKTOP="$HOME/Desktop"

APP_VERSION_NUM="0.5.0"
APP_BUILD=138

# 优先使用 WorkBuddy 管理的 Swift 工具链，否则回退到系统 swiftc。
SWIFT_BIN="swiftc"
if [ -x "/Users/mulei/.workbuddy/binaries/swift/versions/current/usr/bin/swiftc" ]; then
    SWIFT_BIN="/Users/mulei/.workbuddy/binaries/swift/versions/current/usr/bin/swiftc"
fi

echo "==> 组装 .app 结构…"
mkdir -p "$APP_PATH/Contents/MacOS" "$RESOURCES"

echo "==> 编译 ObjC 异常桥 (clang)…"
clang -target arm64-apple-macosx15.0 -c Sources/macall/SMC/ExceptionCatcher.m \
    -o build/ExceptionCatcher.o -framework Foundation

echo "==> 编译主程序源文件 (swiftc)…"
"$SWIFT_BIN" -Osize -wmo -Xlinker -dead_strip \
    -target arm64-apple-macosx15.0 \
    -framework AppKit -framework SwiftUI -framework IOKit \
    -framework ApplicationServices -framework Carbon -framework CoreGraphics \
    -framework Combine -framework UserNotifications -framework ServiceManagement \
    -framework ScreenCaptureKit -framework AVFoundation -framework CoreMedia \
    -framework CoreAudio -framework ImageIO -framework UniformTypeIdentifiers \
    -framework Vision -framework CryptoKit \
    -I Sources/macall/SMC \
    -import-objc-header Sources/macall/SMC/smc_bridge.h \
    -o "$BIN" \
    $(find Sources/Defaults -name '*.swift') \
    $(find Sources/macall -name '*.swift') \
    $(find Sources/macall/SMC -name '*.c') \
    build/ExceptionCatcher.o
cp -f "Resources/Info.plist" "$APP_PATH/Contents/Info.plist"

# 把版本号注入主程序 Info.plist（单一事实来源在脚本顶部的变量）。
inject_version() {
    local PLIST="$1"
    if [ -x /usr/libexec/PlistBuddy ]; then
        local PB=/usr/libexec/PlistBuddy
        for kv in "CFBundleShortVersionString:$APP_VERSION_NUM" "CFBundleVersion:$APP_BUILD"; do
            local key="${kv%%:*}"; local val="${kv##*:}"
            if "$PB" -c "Print :$key" "$PLIST" >/dev/null 2>&1; then
                "$PB" -c "Set :$key $val" "$PLIST"
            else
                "$PB" -c "Add :$key string $val" "$PLIST"
            fi
        done
    fi
}
inject_version "$APP_PATH/Contents/Info.plist"
echo "    ✅ 主程序 Info.plist 版本: $APP_VERSION_NUM (build $APP_BUILD)"

# 拷贝 App 图标（若存在）。
if [ -f "Resources/AppIcon.icns" ]; then
    cp -f "Resources/AppIcon.icns" "$RESOURCES/AppIcon.icns"
fi

# 拷贝开源许可证（关于页「查看开源许可证」按钮需要）。
if [ -f "LICENSE" ]; then
    cp -f "LICENSE" "$RESOURCES/LICENSE.txt"
fi

# 主程序签名：优先用固定自签名证书（见 setup-cert.sh），使辅助功能/屏幕录制等
# TCC 授权在每次重装/更新后自动保留；ad-hoc 签名每次改 hash 会静默作废授权。
# 自签名证书在本地签名可用（首次打开 Gatekeeper 会提示，右键打开或 xattr -cr 即可），
# 但身份稳定，TCC 授权得以保留——这正是与 ad-hoc 的关键区别。
SIGN_IDENTITY="macall Code Signing"
KC_NAME="macall-signing.keychain"
KC_PW="macall"
# Hardened Runtime（--options runtime）下必须显式声明 entitlement，否则：
#  · 「输入监听」读麦克风会被系统直接拒绝，哪怕用户已在系统设置里授权；
#  · 锁屏 / 深色模式切换所依赖的私有框架可能被库校验拦下。
ENTITLEMENTS="Resources/macall.entitlements"
HAS_CERT=0
if security find-identity -p codesigning 2>/dev/null | grep -q "$SIGN_IDENTITY"; then
    HAS_CERT=1
    security unlock-keychain -p "$KC_PW" "$HOME/Library/Keychains/$KC_NAME-db" 2>/dev/null || true
fi

# 签名主程序。
echo "==> 签名主程序…"
# 关键：只用固定自签名证书签名，不要手动加 -r 指定要求。
# 自签名证书的【默认】指定要求（DR）就是
#   identifier "com.macall.app" and certificate leaf = H"4c71ebc34fe9d7cb3fcd7394842da1bd53094d2f"
# 已经把代码身份锚定到证书（而非 cdhash）。setup-cert.sh 已把该证书加入用户级信任，
# TCC 才能锚定到证书身份，从而「每次重建后辅助功能 / 屏幕录制等授权依旧有效」。
# 一旦手写成 -r "<要求串>"，codesign 会解析失败并静默回退 ad-hoc 签名，
# 身份每次都变 → TCC 授权全部失效（这正是此前 build 把权限弄丢的根因）。
MAIN_SIGN_OPTS=(--options runtime)
if [ -f "$ENTITLEMENTS" ]; then
    MAIN_SIGN_OPTS+=(--entitlements "$ENTITLEMENTS")
    echo "    ℹ️  使用 entitlements: $ENTITLEMENTS"
fi
if [ "$HAS_CERT" = "1" ]; then
    if codesign --force --sign "$SIGN_IDENTITY" "${MAIN_SIGN_OPTS[@]}" "$APP_PATH" 2>/dev/null; then
        echo "    ✅ 已用固定证书签名 — 更新后权限自动保留，无需重新授权"
    else
        echo "    ⚠️ 证书签名失败，回退 ad-hoc"
        codesign --force --sign - "$APP_PATH" 2>/dev/null || true
    fi
else
    echo "    ⚠️ 未找到证书，使用 ad-hoc 签名（建议先运行 ./setup-cert.sh 保住 TCC 权限）"
    codesign --force --sign - "$APP_PATH" 2>/dev/null || true
fi

# 默认把 .app 复制到桌面（dmg 仍按需生成）。
echo "==> 复制 .app 到桌面…"
DST_APP="$DESKTOP/$APP_NAME.app"
rm -rf "$DST_APP"
cp -R "$APP_PATH" "$DST_APP"
echo "已复制到: $DST_APP"

# 清理历史上可能残留的旧 Quick Action（macall-Move / macall-Copy workflow），
# 避免它们在右键菜单里作为重复项出现。
echo "==> 清理旧的 Quick Action（若有残留）…"
for wf in macall-Move macall-Copy; do
    if [ -d "$HOME/Library/Services/$wf.workflow" ]; then
        rm -rf "$HOME/Library/Services/$wf.workflow"
        echo "    🗑 已删除 $HOME/Library/Services/$wf.workflow"
    fi
done

echo "==> 处理 .dmg（拖拽安装版：app + Applications 软链）…"
if [ "${MAKE_DMG:-0}" = "1" ]; then
    DMG="$DESKTOP/$APP_NAME-$APP_VERSION_NUM.dmg"
    rm -f "$DMG"
    if command -v hdiutil >/dev/null 2>&1; then
        # 舞台目录：macall.app + 指向 /Applications 的软链，
        # 用户把 macall.app 拖到「Applications」上即安装到 /Applications。
        STAGING="$(mktemp -d)"
        cp -R "$APP_PATH" "$STAGING/$APP_NAME.app"
        ln -s /Applications "$STAGING/Applications"
        hdiutil create -volname "$APP_NAME" -srcfolder "$STAGING" -ov "$DMG" -format UDZO >/dev/null 2>&1
        rm -rf "$STAGING"
        echo "已生成: $DMG"
    else
        echo "未找到 hdiutil，跳过 dmg。可直接使用 $APP_PATH"
    fi
else
    echo "跳过 dmg（仅生成 .app）。需要安装包时运行: MAKE_DMG=1 bash build.sh"
fi

echo "==> 完成。将 $APP_PATH 拖到 /Applications 即可运行。"

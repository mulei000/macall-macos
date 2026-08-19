#!/bin/bash
# macall 权限诊断 / 修复
#
# 用途：当「所有快捷键都没反应、窗口分屏无效」时运行本脚本。
# 根因几乎总是「辅助功能」权限失效 —— 全局快捷键靠 CGEventTap(.defaultTap)，
# 它需要辅助功能授权；窗口分屏/移动/置顶靠 AX API，同样需要辅助功能。
# 一旦这一项没了，20 个功能里绝大多数会**同时静默失效**。
#
#   诊断： bash fix-permissions.sh
#   重置： bash fix-permissions.sh --reset      （清掉 TCC 记录，重新触发授权）

set -uo pipefail

BUNDLE_ID="com.macall.app"
APP_PATHS=("/Applications/macall.app" "$HOME/Desktop/macall.app")

echo "=========================================="
echo " macall 权限诊断"
echo "=========================================="
echo

# --- 1. 找到 app 与版本 ------------------------------------------------------
for p in "${APP_PATHS[@]}"; do
    if [ -d "$p" ]; then
        ver=$(defaults read "$p/Contents/Info" CFBundleShortVersionString 2>/dev/null || echo "?")
        bld=$(defaults read "$p/Contents/Info" CFBundleVersion 2>/dev/null || echo "?")
        mt=$(stat -f "%Sm" "$p/Contents/MacOS/macall" 2>/dev/null || echo "?")
        echo "📦 $p"
        echo "   版本 $ver (build $bld)   二进制时间 $mt"
    fi
done
echo

# --- 2. 签名身份是否稳定（TCC 靠它认人） ------------------------------------
echo "🔏 签名身份"
for p in "${APP_PATHS[@]}"; do
    [ -d "$p" ] || continue
    auth=$(codesign -dv --verbose=2 "$p" 2>&1 | grep "^Authority=" | head -1)
    dr=$(codesign -d -r- "$p" 2>&1 | grep "^designated" | head -1)
    echo "   $p"
    echo "     ${auth:-未签名}"
    echo "     ${dr:-无 designated requirement}"
done
echo "   （若两个 app 的 certificate leaf 不一致，TCC 会把它们当成两个不同的应用）"
echo

# --- 3. 运行状态 -------------------------------------------------------------
echo "🏃 运行中的实例"
pgrep -lf "macall.app/Contents/MacOS/macall" || echo "   （未运行）"
echo

# --- 4. 从应用日志读最近一次权限自检结果 -------------------------------------
LOG="$HOME/Library/Logs/macall/macall.log"
# 注意：变量后面紧跟中文全角括号时必须写 ${LOG}，
# 否则 bash 会把多字节字符并进变量名，在 set -u 下报 unbound variable。
echo "📋 最近的权限自检（来自 ${LOG}）"
if [ -f "$LOG" ]; then
    grep "\[permission\]" "$LOG" | tail -3 | sed 's/^/   /'
    echo
    echo "   最近的失败记录："
    grep -E "无法创建键盘监听|无法创建鼠标监听|权限" "$LOG" | tail -5 | sed 's/^/   /'
else
    echo "   （还没有日志，先运行一次 macall）"
fi
echo

# --- 5. 重置 -----------------------------------------------------------------
if [ "${1:-}" = "--reset" ]; then
    echo "=========================================="
    echo " 重置 TCC 授权记录"
    echo "=========================================="
    echo "将清除 macall 的辅助功能 / 输入监控 / 屏幕录制 / 麦克风授权记录，"
    echo "之后重新打开 macall，系统会重新询问（或需要你手动在列表里勾选）。"
    echo
    read -r -p "确认继续？(y/N) " ans
    if [ "$ans" != "y" ] && [ "$ans" != "Y" ]; then
        echo "已取消。"
        exit 0
    fi

    pkill -f "macall.app/Contents/MacOS/macall" 2>/dev/null && echo "   已退出运行中的 macall"
    sleep 1

    for svc in Accessibility ListenEvent ScreenCapture Microphone; do
        if tccutil reset "$svc" "$BUNDLE_ID" >/dev/null 2>&1; then
            echo "   ✅ 已重置 $svc"
        else
            echo "   ⚠️  $svc 重置失败（可能本就没有记录，可忽略）"
        fi
    done

    echo
    echo "接下来："
    echo "  1. 打开「系统设置 › 隐私与安全性 › 辅助功能」"
    echo "  2. 如果里面还残留 macall，选中后点「−」删除"
    echo "  3. 打开 macall，按提示授权；或点「+」手动添加 /Applications/macall.app"
    echo "  4. 授权后**必须重启 macall**（macOS 不会给已运行的进程补发权限）"
    exit 0
fi

# --- 6. 引导 -----------------------------------------------------------------
echo "=========================================="
echo " 修复建议"
echo "=========================================="
echo "若上面显示「辅助功能=false」，按以下顺序处理："
echo
echo "  ① 打开系统设置："
echo "     open 'x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility'"
echo
echo "  ② 在列表里找到 macall："
echo "     · 开关是关的  → 打开它"
echo "     · 开关已经是开的 → 先关掉再打开（TCC 记录常见的「假开启」）"
echo "     · 列表里没有  → 点「+」选择 /Applications/macall.app"
echo
echo "  ③ 无论哪种，最后都要**完全退出 macall 再重新打开**。"
echo
echo "  ④ 上面都试过还不行，跑彻底重置："
echo "     bash fix-permissions.sh --reset"
echo
echo "同时建议只保留一份 macall.app（别让 /Applications 和桌面各放一份同时运行），"
echo "TCC 是按路径 + 签名记账的，两份会互相顶掉授权。"

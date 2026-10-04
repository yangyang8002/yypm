#!/system/bin/sh
# =========================================================
# yypm 安装脚本：自动安装本体（KernelSU 安装时静默执行）
# 剩余模块请用 KernelSU 管理器里的「Action」按钮下载安装
# =========================================================
MODDIR="${0%/*}"
UPDATE_DIR="/data/adb/modules_update/yypm"

d="$MODDIR"
[ -d "$UPDATE_DIR" ] && d="$UPDATE_DIR"

chmod 755 "$d/service.sh" "$d/webui.sh" "$d/common.sh" "$d/action.sh" "$d/verify_tool" 2>/dev/null
# appinfo.dex 是给 app_process 当 classpath 读的，不需要 +x，但必须可读
chmod 644 "$d/appinfo.dex" 2>/dev/null
mkdir -p /data/adb/yypm/packages /data/adb/yypm/tmp 2>/dev/null

# ---- 安装阶段反挂检查 ----
# 这是最干净的拦截点：此刻还没有任何副作用（没注入、没改系统属性）。
# 只对【block 级】拦截；关键字命中（warn 级）不拦，因为误报率高。
# 白名单在 ac_is_allowed 里强制，tricky_store / playintegrityfix 这类
# 伪装类模块不会被误伤。
mkdir -p /data/adb/yypm/tmp 2>/dev/null
AC_OUT="/data/adb/yypm/tmp/ac-install.txt"
if [ -f "$d/common.sh" ]; then
    ( . "$d/common.sh"; ac_scan ) > "$AC_OUT" 2>/dev/null
    AC_BLOCK=$(sed -n 's/^AC_BLOCK=//p' "$AC_OUT" 2>/dev/null | head -1)
    if [ -n "$AC_BLOCK" ] && [ "$AC_BLOCK" != "0" ]; then
        echo ""
        echo "  [✗] 检测到 $AC_BLOCK 个游戏挂模块，已停止安装。"
        echo ""
        sed -n '/^AC-BEGIN$/,/^AC-END$/p' "$AC_OUT" 2>/dev/null | sed '1d;$d' | \
            while IFS="	" read -r _id _lvl _nm _why; do
                [ "$_lvl" = "block" ] || continue
                echo "      · $_id（$_nm）— $_why"
            done
        echo ""
        echo "  yypm 会修改 keybox 与设备认证状态，和游戏挂共存会互相拖累："
        echo "  游戏反作弊一旦标记本机，依赖硬件认证的应用会跟着一起失效。"
        echo ""
        echo "  请先卸载上面这些模块，再重新安装 yypm。"
        echo "  如果你确认其中某个是误判，把它从 /data/adb/modules 里改名后重试。"
        echo ""
        abort "安装已中止：检测到游戏挂模块"
    fi
fi

# ---- Android 版本适配提示 ----
# 适配 Android 13-17（API 33-37）。只提示、不拦截：低版本多数功能仍可用，
# 硬拦会误伤那些其实跑得动的设备。
SDK=$(getprop ro.build.version.sdk 2>/dev/null | tr -d ' \r')
if [ -n "$SDK" ]; then
    REL=$(getprop ro.build.version.release 2>/dev/null | tr -d ' \r')
    if [ "$SDK" -lt 33 ] 2>/dev/null; then
        echo "  [!] 本模块适配 Android 13-17（API 33-37），当前是 Android $REL (API $SDK)"
        echo "      低版本缺少 app_process / resetprop 的现代行为，部分功能可能不可用。"
    elif [ "$SDK" -gt 37 ] 2>/dev/null; then
        echo "  [!] 当前是 Android $REL (API $SDK)，高于已验证的 Android 17（API 37）"
        echo "      可能有兼容问题，遇到异常请反馈。"
    else
        echo "  [✓] 系统版本 Android $REL (API $SDK)，在适配范围内（Android 13-17）"
    fi
fi

echo "  [✓] yypm 本体已安装"
echo "  下载安装剩余模块：请在 KernelSU 管理器中点击本模块的 Action 按钮"
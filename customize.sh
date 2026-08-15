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
mkdir -p /data/adb/yypm/packages /data/adb/yypm/tmp 2>/dev/null

echo "  [✓] yypm 本体已安装"
echo "  下载安装剩余模块：请在 KernelSU 管理器中点击本模块的 Action 按钮"
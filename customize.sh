#!/system/bin/sh
# yypm 安装脚本：设置脚本执行权限
MODDIR="${0%/*}"
MODULE_UPDATE_DIR="/data/adb/modules_update/yypm"

DIR="$MODDIR"
[ -d "$MODULE_UPDATE_DIR" ] && DIR="$MODULE_UPDATE_DIR"

chmod 755 "$DIR/service.sh" "$DIR/webui.sh" "$DIR/common.sh" 2>/dev/null
chmod 755 "$DIR/verify_tool" 2>/dev/null

mkdir -p /data/adb/yypm/packages /data/adb/yypm/tmp 2>/dev/null

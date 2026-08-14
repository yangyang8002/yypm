#!/system/bin/sh
# =========================================================
# yypm 主服务 (KernelSU)
#   - 定时自动获取 keybox 并挂载到 TEESimulator
#   - 自动隐藏 BL / 自动关闭调试（独立开关）
# 各开关由 WebUI 控制（config.prop），默认：fetch on，bl/debug off。
# =========================================================
MODDIR="${0%/*}"
. "$MODDIR/common.sh"

log "========== 服务启动 =========="
log "fetch=$(get_auto) bl=$(cfg_get auto_bl off) debug=$(cfg_get auto_debug off)"

# 启动时执行一次
if [ "$(get_auto)" = "on" ]; then
    fetch_keybox
    download_packages
    check_module_update
else
    log "自动获取已关闭，跳过启动拉取"
fi
[ "$(cfg_get auto_bl off)" = "on" ] && hide_bl
[ "$(cfg_get auto_debug off)" = "on" ] && close_debug

while true; do
    sleep "$UPDATE_INTERVAL"
    if [ "$(get_auto)" = "on" ]; then
        fetch_keybox
        download_packages
        check_module_update
        [ "$(cfg_get auto_bl off)" = "on" ] && hide_bl
        [ "$(cfg_get auto_debug off)" = "on" ] && close_debug
    else
        log "自动获取已关闭，跳过本轮"
        [ "$(cfg_get auto_bl off)" = "on" ] && hide_bl
        [ "$(cfg_get auto_debug off)" = "on" ] && close_debug
    fi
done

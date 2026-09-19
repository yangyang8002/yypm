#!/system/bin/sh
# =========================================================
# yypm 主服务 (KernelSU)
#   - 定时自动获取 keybox 并挂载到 TEESimulator
#   - 自动隐藏 BL / 自动关闭调试（独立开关）
# 各开关由 WebUI 控制（config.prop），默认：fetch on，bl/debug off。
#
# 检查间隔可由 WebUI 配置（config.prop 的 check_interval，单位秒，
# 可选 1h/6h/12h/24h）。若某一轮拉取失败，则不再干等一个完整周期，
# 而是按 common.sh 里的 RETRY_STEPS 退避后提前重试。
# =========================================================
MODDIR="${0%/*}"
. "$MODDIR/common.sh"

# 每轮要做的事。整轮里只有 keybox 拉取算"关键失败"（失败才触发提前重试）；
# 附属模块包下载失败不算致命，不打断正常周期。
run_cycle() {
    CYCLE_FAILED=0
    if allow_auto_fetch; then
        fetch_keybox_safe || CYCLE_FAILED=1
        download_packages
        check_module_update
    else
        log "本轮跳过拉取（自动获取已关闭，或非 WiFi 且开启了仅 WiFi 更新）"
    fi
    [ "$(cfg_get auto_bl off)" = "on" ] && hide_bl
    [ "$(cfg_get auto_debug off)" = "on" ] && close_debug
    return 0
}

log "========== 服务启动 =========="
log "fetch=$(get_auto) wifi_only=$(cfg_get wifi_only off) bl=$(cfg_get auto_bl off) debug=$(cfg_get auto_debug off) 间隔=$(($(get_interval) / 3600))h"

# 启动时执行一次（网络可能尚未就绪，失败会自动进入短期重试）
run_cycle

while true; do
    if [ "$CYCLE_FAILED" = "1" ]; then
        # 失败后提前重试：retry_note_fail 已经排好了下次时间
        LEFT=$(retry_due_in)
        case "$LEFT" in
            ''|*[!0-9-]*) SLEEP_FOR=$(( $(get_interval) )) ;;
            *)
                if [ "$LEFT" -le 0 ] 2>/dev/null; then
                    SLEEP_FOR=60
                else
                    SLEEP_FOR=$LEFT
                fi
                ;;
        esac
        # 重试间隔不超过正常周期
        [ "$SLEEP_FOR" -gt "$(get_interval)" ] 2>/dev/null && SLEEP_FOR=$(get_interval)
        [ "$SLEEP_FOR" -lt 60 ] && SLEEP_FOR=60
        log "[·] 上轮失败，${SLEEP_FOR}s 后重试"
    else
        SLEEP_FOR=$(get_interval)
    fi
    sleep "$SLEEP_FOR"
    run_cycle
done

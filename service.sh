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
    dbg "== 巡检开始（debug=on）=="
    dbg "配置: auto_fetch=$(cfg_get auto_fetch on) wifi_only=$(cfg_get wifi_only off) interval=$(cfg_get check_interval 3600) anti_cheat=$(cfg_get anti_cheat on) sp=$(cfg_get security_patch auto) risk=$(cfg_get risk_autohide on) abnormal=$(cfg_get abnormal_auto on) mirror=$(cfg_get mirror_urls on)"
    # 反挂先跑：它可能锁定自身，后面所有功能都要看它的结果
    ac_apply >/dev/null 2>&1
    if ac_locked; then
        log "[✗] 反挂锁定中，本轮跳过全部功能：$(ac_lock_reason)"
        return 0
    fi
    if allow_auto_fetch; then
        fetch_keybox_safe || CYCLE_FAILED=1
        download_packages
        auto_install_packages
        check_module_update
    else
        log "本轮跳过拉取（自动获取已关闭，或非 WiFi 且开启了仅 WiFi 更新）"
    fi
    [ "$(cfg_get auto_bl off)" = "on" ] && hide_bl
    [ "$(cfg_get auto_debug off)" = "on" ] && close_debug
    # 环境对抗：深度伪装启动状态（需要 SUSFS/Shamiko 支撑，否则只记日志不动手）
    [ "$(cfg_get deep_bl off)" = "on" ] && hide_bl_deep
    # 环境对抗：风险应用自动并入隐藏列表（春秋检测整改），再把列表同步到系统
    risk_apps_autohide
    hide_apps_sync
    # 环境对抗：自动清理 MT2 等落地目录（春秋检测「异常文件」整改；abnormal_auto=off 关闭）
    [ "$(cfg_get abnormal_auto on)" = "on" ] && clean_abnormal >/dev/null 2>&1
    # 安全补丁级别对齐（春秋检测整改；与是否自动拉取无关，TrickyStore 不在时自动跳过）
    ensure_security_patch
    # 把春秋等检测类应用并入 TrickyStore 目标清单（检测项 26：检测方自己的密钥认证也要走模拟）。
    # 放在巡检末尾：fetch_keybox 已跑完，TrickyStore 目录与 keybox 都已就绪；
    # 与是否自动拉取无关（拉取关了清单也要维护），函数内部会自行判断目录是否存在。
    auto_target_known_apps
    # HMA-OSS 自动配置（装完即用，不用打开管理 App 手配；名单变化自动跟进）
    hma_oss_autocfg
    # 清退被 HMA-OSS 取代的旧组件（hma-uidfake：打了 remove 标记，重启后由 KernelSU 清理）
    cleanup_replaced_mods
    return 0
}

# 自动安装的组件重启后已生效（modules_update 被 KernelSU 接管清空）-> 撤下「待重启」提示
if [ -f "$DATA_DIR/auto_install.pending" ] && ! ls /data/adb/modules_update/*/module.prop >/dev/null 2>&1; then
    rm -f "$DATA_DIR/auto_install.pending" 2>/dev/null
fi

log "========== 服务启动 =========="

# 反挂锁定：开机不加载任何功能（fail-closed，断网同样保持锁定）
if ac_locked; then
    log "[✗] 反挂锁定中，本次启动不加载任何功能：$(ac_lock_reason)"
    log "[✗] 解除方法：在 WebUI「反挂检查」里处理掉可疑模块后点「解除锁定」"
    exit 0
fi
log "fetch=$(get_auto) wifi_only=$(cfg_get wifi_only off) bl=$(cfg_get auto_bl off) debug=$(cfg_get auto_debug off) deep_bl=$(cfg_get deep_bl off) hide_apps=$(cfg_get hide_apps_enable off) 间隔=$(($(get_interval) / 3600))h"

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

#!/system/bin/sh
# =========================================================
# yypm WebUI 后端 —— 由 webroot/index.html 通过 ksu.exec 调用
#
# 用法:
#   webui.sh fetch       手动获取并挂载 keybox
#   webui.sh auto <on|off> 切换自动获取
#   webui.sh status      输出状态(key=value)
#   webui.sh mount       把缓存的 keybox 挂载到 tricky_store
#   webui.sh check-packages  检查附属模块（TEESimulator / PIF 等）是否有更新
# =========================================================
MODDIR="$(cd "$(dirname "$0")" && pwd)"
. "$MODDIR/common.sh"

case "${1:-status}" in
    fetch)
        echo "正在获取 keybox ..."
        if fetch_keybox; then
            echo "KEYBOX=OK"
        else
            echo "KEYBOX=FAIL"
        fi
        echo "---STATUS-BEGIN---"
        echo_status
        echo "---STATUS-END---"
        ;;
    auto)
        [ "$2" = "on" ] || [ "$2" = "off" ] || { echo "用法: auto on|off"; exit 1; }
        set_auto "$2"
        echo "AUTO_FETCH=$2"
        ;;
    bl)
        if hide_bl; then echo "BL=OK"; else echo "BL=FAIL"; fi
        echo_status | grep -E 'BL_HIDDEN'
        ;;
    auto-bl)
        [ "$2" = "on" ] || [ "$2" = "off" ] || { echo "用法: auto-bl on|off"; exit 1; }
        cfg_set auto_bl "$2"
        echo "AUTO_BL=$2"
        ;;
    debug)
        if close_debug; then echo "DEBUG=OK"; else echo "DEBUG=FAIL"; fi
        echo_status | grep -E 'DEBUG_CLOSED'
        ;;
    auto-debug)
        [ "$2" = "on" ] || [ "$2" = "off" ] || { echo "用法: auto-debug on|off"; exit 1; }
        cfg_set auto_debug "$2"
        echo "AUTO_DEBUG=$2"
        ;;
    mount)
        mkdir -p "$TRICKY_DIR"
        if [ -f "$KEYBOX_CACHE" ]; then
            cp "$KEYBOX_CACHE" "$KEYBOX_DEST"
            chmod 644 "$KEYBOX_DEST"
            echo "MOUNT=OK"
            echo "KEYBOX_SIZE=$(wc -c < "$KEYBOX_DEST" 2>/dev/null | tr -d ' ')"
        elif [ -f "$KEYBOX_DEST" ]; then
            echo "MOUNT=OK(already)"
            echo "KEYBOX_SIZE=$(wc -c < "$KEYBOX_DEST" 2>/dev/null | tr -d ' ')"
        else
            echo "MOUNT=FAIL(no keybox cached)"
        fi
        ;;
    check-packages)
        echo "正在检查附属模块更新 ..."
        check_updates
        # 结构化结果放最后：每行 6 段 NC|文件名|模块id|本地版本|云端版本|说明
        # （NC = OK/UPD/NEW/MISMATCH/ERR），WebUI 按段数解析
        if [ -f "$TMP/check_out.txt" ]; then
            while IFS='|' read -r tag fn mid lvc rvc st msg; do
                echo "$st|$fn|$mid|$lvc|$rvc|$msg"
            done < "$TMP/check_out.txt"
        fi
        echo "UPDATE_CHECKED=$(update_state_field checked_at 未检查)"
        echo "UPDATE_NEED=$(update_state_field need 0)"
        echo "UPDATE_SUMMARY=$(update_state_field summary -)"
        ;;
    update)
        check_github_release
        ;;
    status|*)
        echo_status
        ;;
esac

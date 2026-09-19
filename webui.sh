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
#   webui.sh update      检查模块自身是否有新版本（GitHub Release）
#   webui.sh download-self <url>  下载新版模块包到 /data/adb/yypm/update.zip
#   webui.sh install-self        把已下载的 update.zip 交给 ksud 自动安装
#   webui.sh update-self <url>   下载 + 校验版本 + 自动安装（WebUI 一键更新用）
# =========================================================
MODDIR="$(cd "$(dirname "$0")" && pwd)"
. "$MODDIR/common.sh"

# 下载新版模块包（先自建服务器，再退回传入的 GitHub 地址），成功返回 0
download_self() { # $1 = 备用 url
    [ -n "${1:-}" ] || { echo "DOWNLOAD=FAIL(no url)"; return 1; }
    mkdir -p "$DATA_DIR"
    for u in "$BASE_URL?action=module" "$1"; do
        [ -n "$u" ] || continue
        rm -f "$DATA_DIR/update.zip"
        if download_retry "$u" "$DATA_DIR/update.zip"; then
            echo "DOWNLOAD=OK"
            echo "SOURCE=$u"
            echo "SAVED=$DATA_DIR/update.zip"
            echo "SIZE=$(wc -c < "$DATA_DIR/update.zip" 2>/dev/null | tr -d ' ')"
            return 0
        fi
        echo "源失败，尝试下一个: $u"
    done
    rm -f "$DATA_DIR/update.zip"
    echo "DOWNLOAD=FAIL"
    return 1
}

# 把已装到暂存区的模块文件同步到生效目录，让更新立刻可用（不必等重启）。
# KernelSU 的 ksud install 只写 modules_update，重启时才接管；这里补上
# "立即生效"这一步，否则用户更新完会发现版本号变了、界面却还是旧的。
# 注意用独立副本（不用 cp -a 硬链接），避免覆盖源文件时连带污染。
sync_live() {
    S=/data/adb/modules_update/yypm
    L=/data/adb/modules/yypm
    [ -d "$S" ] || return 0
    mkdir -p "$L" "$L/webroot" 2>/dev/null
    for f in module.prop action.sh service.sh webui.sh common.sh pubkey.b64 verify_tool; do
        [ -f "$S/$f" ] && cat "$S/$f" > "$L/$f" 2>/dev/null
    done
    [ -f "$S/webroot/index.html" ] && cat "$S/webroot/index.html" > "$L/webroot/index.html" 2>/dev/null
    # customize.sh 是安装期脚本，不参与运行，故意不同步
    chmod 755 "$L"/*.sh "$L/verify_tool" 2>/dev/null
    chmod 644 "$L/module.prop" "$L/pubkey.b64" "$L/webroot/index.html" 2>/dev/null
    rm -f "$L/update" 2>/dev/null
    return 0
}

# 用 ksud 把 update.zip 装进 modules_update（重启后生效）
install_self() {
    KS=/data/adb/ksud
    Z="$DATA_DIR/update.zip"
    [ -s "$Z" ] || { echo "INSTALL=FAIL(没有已下载的包)"; return 1; }
    # 版本防回退：包内 versionCode 不高于当前就丢弃，避免误降级
    pkg_vc=$(zip_version "$Z" 2>/dev/null)
    cur_vc=$(vc_of "$MODDIR")
    if [ -n "$pkg_vc" ] && [ -n "$cur_vc" ] && [ "$pkg_vc" -le "$cur_vc" ] 2>/dev/null; then
        echo "INSTALL=SKIP"
        echo "PKG_VCODE=$pkg_vc"
        echo "CUR_VCODE=$cur_vc"
        rm -f "$Z"
        return 0
    fi
    [ -x "$KS" ] || { echo "INSTALL=FAIL(未找到 ksud)"; echo "SAVED=$Z"; return 1; }
    lsout=$("$KS" module install "$Z" 2>&1)
    rc=$?
    echo "$lsout"
    if [ "$rc" -ne 0 ]; then
        echo "INSTALL=FAIL"
        echo "SAVED=$Z"
        return 1
    fi
    rm -f "$Z"
    echo "INSTALL=OK"
    echo "PKG_VCODE=${pkg_vc:-?}"
    echo "CUR_VCODE=${cur_vc:-?}"
    # 同步到生效目录，让新版本立刻可用
    if sync_live; then
        echo "LIVE=SYNCED"
    else
        echo "LIVE=SYNC_FAIL"
    fi
    return 0
}

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
    download-self)
        # 供 WebUI 调用：先试自建服务器（实测最稳），再退回传入的 GitHub 地址。
        # 设备上不一定有 curl，网页端直接调 curl 会失败。
        download_self "${2:-}" || exit 1
        ;;
    install-self)
        install_self
        ;;
    update-self)
        # 一键更新：下载 -> 版本防回退 -> ksud 自动安装，装完提示重启
        echo "正在下载新版本 ..."
        download_self "${2:-}" || exit 1
        echo "正在自动安装 ..."
        install_self
        ;;
    status|*)
        echo_status
        ;;
esac

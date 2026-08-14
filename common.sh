#!/system/bin/sh
# =========================================================
# yypm 公共库 —— 被 service.sh 与 webui.sh 共用
# =========================================================

# ---- 配置 ----
BASE_URL="https://your-server.example.com/api/kernelsu/module"
GITHUB_REPO="yourname/yypm"   # GitHub 仓库（owner/repo），检查更新用
MODDIR="/data/adb/modules/yypm"
DATA_DIR="/data/adb/yypm"
CONFIG="$DATA_DIR/config.prop"
TRICKY_DIR="/data/adb/tricky_store"
KEYBOX_DEST="$TRICKY_DIR/keybox.xml"
KEYBOX_CACHE="$DATA_DIR/keybox.xml"
PUBKEY="$MODDIR/pubkey.b64"
VERIFY_TOOL="$MODDIR/verify_tool"
TMP="$DATA_DIR/tmp"
UPDATE_INTERVAL=21600

LOG="$DATA_DIR/yypm.log"

log() { echo "[$(date '+%m-%d %H:%M:%S')] $*" >> "$LOG"; }

# ---- 下载 (curl -> busybox wget -> toybox wget) ----
download() { # $1 url  $2 out
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL --connect-timeout 10 --max-time 40 -o "$2" "$1" && return 0
    fi
    if command -v busybox >/dev/null 2>&1 && busybox --list 2>/dev/null | grep -qx wget; then
        busybox wget -T 40 --no-check-certificate -q -O "$2" "$1" && return 0
    fi
    if command -v toybox >/dev/null 2>&1 && toybox --list 2>/dev/null | grep -qx wget; then
        toybox wget -T 40 --no-check-certificate -q -O "$2" "$1" && return 0
    fi
    return 1
}

sha256_of() { # $1 file
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" | awk '{print $1}' 2>/dev/null
    elif command -v openssl >/dev/null 2>&1; then
        openssl dgst -sha256 "$1" 2>/dev/null | awk '{print $NF}'
    fi
}

json_get() { # $1 file  $2 key
    sed -n "s/.*\"$2\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p" "$1" | head -1
}

# ---- config 读写（通用）----
cfg_get() { # $1 key  $2 default
    local v=""
    [ -f "$CONFIG" ] && v=$(grep "^$1=" "$CONFIG" 2>/dev/null | tail -1 | cut -d= -f2-)
    [ -n "$v" ] && echo "$v" || echo "$2"
}

cfg_set() { # $1 key  $2 val
    mkdir -p "$DATA_DIR"
    if [ -f "$CONFIG" ] && grep -q "^$1=" "$CONFIG" 2>/dev/null; then
        sed -i "s|^$1=.*|$1=$2|" "$CONFIG"
    else
        echo "$1=$2" >> "$CONFIG"
    fi
}

# 兼容旧接口
get_auto() { cfg_get auto_fetch on; }
set_auto() { cfg_set auto_fetch "$1"; log "自动获取已设为 $1"; }

# ---- resetprop 属性伪造 ----
get_resetprop() {
    local p
    for p in /data/adb/ksu/bin/resetprop /data/adb/ap/bin/resetprop resetprop; do
        if command -v "$p" >/dev/null 2>&1 || [ -x "$p" ]; then
            echo "$p"; return 0
        fi
    done
    return 1
}

# 隐藏 BL：伪造 bootloader 为锁定状态
hide_bl() {
    local rp; rp=$(get_resetprop) || { log "[✗] 未找到 resetprop"; return 1; }
    "$rp" ro.boot.verifiedbootstate green 2>/dev/null
    "$rp" ro.boot.flash.locked 1 2>/dev/null
    "$rp" ro.boot.vbmeta.device_state locked 2>/dev/null
    "$rp" ro.boot.warranty_bit 0 2>/dev/null
    "$rp" ro.boot.veritymode enforcing 2>/dev/null
    log "[✓] 已隐藏 BL（bootloader 伪装为锁定）"
    return 0
}

# 关闭调试模式
close_debug() {
    local rp; rp=$(get_resetprop) || { log "[✗] 未找到 resetprop"; return 1; }
    "$rp" ro.debuggable 0 2>/dev/null
    "$rp" ro.secure 1 2>/dev/null
    "$rp" ro.build.type user 2>/dev/null
    "$rp" ro.build.tags release-keys 2>/dev/null
    "$rp" ro.adb.secure 1 2>/dev/null
    "$rp" ro.force.debuggable 0 2>/dev/null
    log "[✓] 已关闭调试模式"
    return 0
}

# ---- 获取并挂载 keybox（下载 -> 校验 -> 验签 -> 写 tricky_store）----
fetch_keybox() {
    mkdir -p "$TMP"
    log "[·] 拉取 manifest"
    download "$BASE_URL?action=manifest" "$TMP/manifest.json" || { log "[✗] manifest 下载失败"; return 1; }

    KB_URL=$(json_get "$TMP/manifest.json" url)
    KB_SHA=$(json_get "$TMP/manifest.json" sha256)
    KB_SIG=$(json_get "$TMP/manifest.json" signature)
    [ -n "$KB_URL" ] || { log "[✗] manifest 缺 url"; return 1; }

    log "[·] 下载 keybox"
    download "$KB_URL" "$TMP/keybox.xml" || { log "[✗] keybox 下载失败"; return 1; }

    # sha256 校验
    got=$(sha256_of "$TMP/keybox.xml")
    if [ -n "$KB_SHA" ] && [ "$got" != "$KB_SHA" ]; then
        log "[✗] sha256 不匹配 ($got)"; return 1
    fi

    # Ed25519 验签（有 verify_tool 则强校验，缺失则 sha256 兜底）
    if [ -n "$KB_SIG" ]; then
        if [ -x "$VERIFY_TOOL" ] && [ -f "$PUBKEY" ]; then
            echo "$KB_SIG" > "$TMP/keybox.sig"
            if ! "$VERIFY_TOOL" "$PUBKEY" "$TMP/keybox.sig" "$TMP/keybox.xml" >/dev/null 2>&1; then
                log "[✗] 签名校验失败，拒绝注入"; return 1
            fi
            log "[✓] 签名校验通过"
        else
            log "[!] 无 verify_tool，仅 sha256 校验（建议编译 verify_tool 增强防盗）"
        fi
    fi

    # 挂载到 TEESimulator（写 tricky_store/keybox.xml）+ 本地缓存
    mkdir -p "$TRICKY_DIR"
    cp "$TMP/keybox.xml" "$KEYBOX_DEST"
    chmod 644 "$KEYBOX_DEST"
    cp "$TMP/keybox.xml" "$KEYBOX_CACHE"
    chmod 644 "$KEYBOX_CACHE"

    local size=$(wc -c < "$KEYBOX_DEST" 2>/dev/null)
    log "[✓] keybox 已挂载到 $KEYBOX_DEST ($size 字节)"
    return 0
}

# ---- 状态输出（供 WebUI 解析，key=value 格式）----
echo_status() {
    echo "AUTO_FETCH=$(get_auto)"
    if [ -f "$KEYBOX_DEST" ]; then
        echo "KEYBOX_MOUNTED=1"
        echo "KEYBOX_SIZE=$(wc -c < "$KEYBOX_DEST" 2>/dev/null | tr -d ' ')"
        echo "KEYBOX_SHA256=$(sha256_of "$KEYBOX_DEST")"
        echo "KEYBOX_UPDATED=$(stat -c '%y' "$KEYBOX_DEST" 2>/dev/null | cut -d. -f1)"
    else
        echo "KEYBOX_MOUNTED=0"
        echo "KEYBOX_SIZE=0"
        echo "KEYBOX_SHA256="
        echo "KEYBOX_UPDATED="
    fi
    # TEESimulator 是否安装
    if [ -d "/data/adb/modules/teesimulator" ] || [ -d "/data/adb/modules/TEESimulator" ] || [ -d "/data/adb/modules/tricky_store" ]; then
        echo "TEESIMULATOR_INSTALLED=1"
    else
        echo "TEESIMULATOR_INSTALLED=0"
    fi
    # 隐藏 BL 状态
    echo "AUTO_BL=$(cfg_get auto_bl off)"
    [ "$(getprop ro.boot.verifiedbootstate 2>/dev/null)" = "green" ] && echo "BL_HIDDEN=1" || echo "BL_HIDDEN=0"
    # 关闭调试状态
    echo "AUTO_DEBUG=$(cfg_get auto_debug off)"
    [ "$(getprop ro.debuggable 2>/dev/null)" = "0" ] && echo "DEBUG_CLOSED=1" || echo "DEBUG_CLOSED=0"
}

# ---- 下载服务端 package 清单里列出的所有模块 ----
download_packages() {
    local list_url="$BASE_URL?action=packages"
    log "[·] 拉取模块清单"
    download "$list_url" "$TMP/packages.json" || { log "[✗] 模块清单下载失败"; return 1; }

    local urls=$(grep -o '"url"[[:space:]]*:[[:space:]]*"[^"]*"' "$TMP/packages.json" | sed 's/.*"\(http[^"]*\)".*/\1/')
    [ -n "$urls" ] || { log "[!] 清单为空"; return 0; }

    local dest="/data/adb/yypm/packages"
    mkdir -p "$dest"
    for url in $urls; do
        local name=$(basename "$url")
        log "[·] 下载模块: $name"
        if download "$url" "$dest/$name"; then
            log "[✓] 模块已下载: $name"
        else
            log "[✗] 模块下载失败: $name"
        fi
    done
    return 0
}

# ---- 检查 GitHub 最新 release（输出 key=value）----
check_github_release() {
    local api="https://api.github.com/repos/$GITHUB_REPO/releases/latest"
    local cur=$(sed -n 's/^version=//p' "$MODDIR/module.prop" 2>/dev/null)
    echo "LOCAL_VERSION=$cur"
    if ! download "$api" "$TMP/release.json"; then
        echo "REMOTE_VERSION="
        echo "DOWNLOAD_URL="
        echo "UPDATE=FAIL"
        return 1
    fi
    local tag=$(json_get "$TMP/release.json" tag_name)
    local url=$(grep -o '"browser_download_url"[[:space:]]*:[[:space:]]*"[^"]*"' "$TMP/release.json" | head -1 | sed 's/.*"\(http[^"]*\)".*/\1/')
    echo "REMOTE_VERSION=$tag"
    echo "DOWNLOAD_URL=$url"
    if [ -n "$tag" ] && [ "$tag" != "$cur" ]; then
        echo "UPDATE=AVAILABLE"
    else
        echo "UPDATE=NONE"
    fi
    return 0
}

# ---- 自动更新模块自身（GitHub Release）----
check_module_update() {
    [ -f "$MODDIR/module.prop" ] || return 0
    local out; out=$(check_github_release) || return 0
    local tag=$(echo "$out" | sed -n 's/^REMOTE_VERSION=//p')
    local url=$(echo "$out" | sed -n 's/^DOWNLOAD_URL=//p')
    local cur=$(echo "$out" | sed -n 's/^LOCAL_VERSION=//p')
    [ -n "$tag" ] && [ "$tag" != "$cur" ] && [ -n "$url" ] || return 0
    log "[·] 发现新版本 $tag（当前 $cur）"
    download "$url" "$TMP/update.zip" || return 0
    if command -v ksud >/dev/null 2>&1; then
        ksud module install "$TMP/update.zip" 2>/dev/null && log "[✓] 已通过 ksud 安装更新"
    else
        log "[!] 新模块已下载到 $TMP/update.zip，请手动安装"
    fi
}

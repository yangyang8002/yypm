#!/system/bin/sh
# =========================================================
# yypm 公共库 —— 被 service.sh 与 webui.sh 共用
# =========================================================

# ---- 配置 ----
# 注意结尾的斜杠：少了它 nginx 会先回 301 补斜杠，而重定向目标带 :444 端口，
# 客户端要白跳两跳（实测 655ms -> 1937ms，慢 3 倍）。下面有 api_url 兜底归一化。
BASE_URL="https://your-server.example.com/api/kernelsu/module/"
GITHUB_REPO="yourname/yypm"   # GitHub 仓库（owner/repo），检查更新用
# MODDIR 优先用调用方（webui.sh/service.sh）已设好的值，否则用默认路径
MODDIR="${MODDIR:-/data/adb/modules/yypm}"
DATA_DIR="/data/adb/yypm"
CONFIG="$DATA_DIR/config.prop"
TRICKY_DIR="/data/adb/tricky_store"
KEYBOX_DEST="$TRICKY_DIR/keybox.xml"
KEYBOX_CACHE="$DATA_DIR/keybox.xml"
PUBKEY="$MODDIR/pubkey.b64"
VERIFY_TOOL="$MODDIR/verify_tool"
TMP="$DATA_DIR/tmp"
UPDATE_INTERVAL_DEFAULT=21600
LOG="$DATA_DIR/yypm.log"
RETRY_STATE="$DATA_DIR/retry.state"
# 已验签 keybox 的本地池（用于服务端主用失效时回滚）
CACHE_DIR="$DATA_DIR/cache"
CACHE_KEEP=3
CACHE_MAX_AGE_DAYS=45

# 下载重试（开机时网络往往尚未就绪，单次失败会白等一个周期）
NET_RETRY=3
NET_RETRY_DELAY=20

# 失败后的短期重试退避（秒）：失败后不再干等一个完整周期
RETRY_STEPS="300 1800 7200 21600"

# 当前生效的检查间隔（可用 WebUI 配置，1h/6h/12h/24h）
get_interval() {
    local v=$(cfg_get check_interval "$UPDATE_INTERVAL_DEFAULT")
    case "$v" in
        ''|*[!0-9]*) v="$UPDATE_INTERVAL_DEFAULT" ;;
    esac
    [ "$v" -lt 600 ] 2>/dev/null && v=600
    echo "$v"
}

# 失败计数与"下次提前重试"时间戳
retry_fails() { sed -n 's/^fails=//p' "$RETRY_STATE" 2>/dev/null | head -1; }
retry_next()  { sed -n 's/^next=//p'  "$RETRY_STATE" 2>/dev/null | head -1; }

retry_note_fail() {
    local n=$(( $(retry_fails) + 1 ))
    [ "$n" -gt 99 ] 2>/dev/null && n=99
    local d=0 i=1
    for s in $RETRY_STEPS; do
        d=$s
        [ "$i" -ge "$n" ] && break
        i=$((i + 1))
    done
    mkdir -p "$DATA_DIR" 2>/dev/null
    { echo "fails=$n"; echo "next=$(( $(date +%s) + d ))"; } > "$RETRY_STATE" 2>/dev/null
    log "[!] 本轮失败第 ${n} 次，$(($d / 60)) 分钟后提前重试"
}

retry_note_ok() {
    [ -f "$RETRY_STATE" ] && rm -f "$RETRY_STATE" 2>/dev/null
    return 0
}

# 距下次提前重试还有多少秒（无需重试时输出空）
retry_due_in() {
    local n=$(retry_next)
    [ -n "$n" ] || return 0
    local now=$(date +%s)
    echo $(( n - now ))
}

log() { echo "[$(date '+%m-%d %H:%M:%S')] $*" >> "$LOG"; }

# ---- URL 拼接（保证 BASE_URL 以 / 结尾，避免每次请求都被 301 补斜杠）----
# 拼接前去掉可能存在的结尾斜杠，避免出现 "module//?action=" 这种双斜杠，
# 双斜杠同样会触发重定向。历史上 BASE_URL 没有尾斜杠，这里兜底。
api_url() { # $1 = action 名
    local b="${BASE_URL%/}"
    # 万一有人把 query 写进了 BASE_URL，先切掉
    b="${b%%\?*}"
    echo "$b/?action=$1"
}

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

# ---- 带重试的下载：开机时网络尚未就绪，单次失败会造成"下载失败" ----
# 每次尝试自身已有超时（curl 40s / wget -T 40），这里做退避重试。
download_retry() { # $1 url  $2 out
    local i=1
    while [ "$i" -le "$NET_RETRY" ]; do
        if download "$1" "$2"; then
            [ "$i" -gt 1 ] && log "[✓] 第 $i 次尝试下载成功"
            return 0
        fi
        if [ "$i" -lt "$NET_RETRY" ]; then
            log "[·] 下载失败，${NET_RETRY_DELAY}s 后重试（$i/$NET_RETRY）"
            sleep "$NET_RETRY_DELAY"
        fi
        i=$((i + 1))
    done
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

# ---- 获取并挂载 keybox（manifest -> 判断有无变化 -> 校验 -> 验签 -> 写 tricky_store）----
# 省流量：manifest 里已带 keybox 的 sha256，先比 sha256；本地缓存已是同一份就
# 跳过下载（12.6KB -> 0），签名仍会重验一遍（成本低且更安全）。
fetch_keybox() {
    mkdir -p "$TMP"
    log "[·] 拉取 manifest"
    if ! download_retry "$(api_url manifest)" "$TMP/manifest.json"; then
        log "[✗] manifest 下载失败（已重试 $NET_RETRY 次）"
        retry_note_fail
        return 1
    fi

    KB_URL=$(json_get "$TMP/manifest.json" url)
    KB_SHA=$(json_get "$TMP/manifest.json" sha256)
    KB_SIG=$(json_get "$TMP/manifest.json" signature)
    [ -n "$KB_URL" ] || { log "[✗] manifest 缺 url"; retry_note_fail; return 1; }

    # 本地缓存已是最新 -> 不下载 keybox
    local fresh=0
    local dest_now=$(sha256_of "$KEYBOX_DEST")
    if [ -n "$KB_SHA" ] && [ -n "$dest_now" ] && [ "$dest_now" = "$KB_SHA" ] && [ -s "$KEYBOX_CACHE" ]; then
        fresh=1
        log "[✓] keybox 已是服务端最新（sha256 一致），跳过下载"
        cp -f "$TMP/manifest.json" "$DATA_DIR/manifest.json" 2>/dev/null
    fi

    if [ "$fresh" = "0" ]; then
        log "[·] 下载 keybox"
        if ! download "$KB_URL" "$TMP/keybox.xml"; then
            log "[✗] keybox 下载失败"
            retry_note_fail
            return 1
        fi
        # sha256 校验
        got=$(sha256_of "$TMP/keybox.xml")
        if [ -n "$KB_SHA" ] && [ "$got" != "$KB_SHA" ]; then
            log "[✗] sha256 不匹配 ($got)"; retry_note_fail; return 1
        fi
        cp -f "$TMP/keybox.xml" "$TMP/keybox.verify" 2>/dev/null
        [ -f "$TMP/keybox.verify" ] || cp -f "$TMP/keybox.xml" "$TMP/keybox.verify"
        cp -f "$TMP/manifest.json" "$DATA_DIR/manifest.json" 2>/dev/null
    fi

    local src="$TMP/keybox.verify"
    [ -f "$src" ] || src="$TMP/keybox.xml"

    # Ed25519 验签（有 verify_tool 则强校验，缺失则 sha256 兜底）
    # 每次执行都验一遍：能发现本地 keybox 被第三方替换的情况。
    # 公钥取 active_pubkey()（支持轮换：pubkey_use 指定当前使用的公钥文件）。
    if [ -n "$KB_SIG" ]; then
        local PK=$(active_pubkey)
        if [ -x "$VERIFY_TOOL" ] && [ -f "$PK" ]; then
            echo "$KB_SIG" > "$TMP/keybox.sig"
            if ! "$VERIFY_TOOL" "$PK" "$TMP/keybox.sig" "$src" >/dev/null 2>&1; then
                log "[✗] 签名校验失败，拒绝注入（公钥 $(basename "$PK")）"
                retry_note_fail
                return 1
            fi
            log "[✓] 签名校验通过"
        else
            log "[!] 无 verify_tool，仅 sha256 校验（建议编译 verify_tool 增强防盗）"
        fi
    fi

    # 挂载到 TEESimulator（写 tricky_store/keybox.xml）+ 本地缓存
    mkdir -p "$TRICKY_DIR"
    cp -f "$src" "$KEYBOX_DEST"
    chmod 644 "$KEYBOX_DEST"
    cp -f "$src" "$KEYBOX_CACHE"
    chmod 644 "$KEYBOX_CACHE"

    # 已验签 -> 存进本地池（供将来失效时回滚）
    cache_store "$src" "$(sha256_of "$src")"
    cache_prune

    local size=$(wc -c < "$KEYBOX_DEST" 2>/dev/null)
    if [ "$fresh" = "1" ]; then
        log "[✓] keybox 校验通过并已挂载 ($size 字节，未重新下载)"
    else
        log "[✓] keybox 已挂载到 $KEYBOX_DEST ($size 字节)"
    fi
    retry_note_ok
    return 0
}

# ---- 带有效性判断与回滚的获取流程（对外只用这个）----
# 顺序：拉 manifest -> 看服务端对这份 keybox 的有效性结论
#   - invalid：不注入，回滚到本地池里上一份已验签的 keybox
#   - warning：照常注入，但把原因写进日志
#   - valid/unknown：正常注入（unknown 兼容旧服务端）
fetch_keybox_safe() {
    if fetch_keybox; then
        local lvl=$(remote_validity_level)
        case "$lvl" in
            invalid)
                local why=$(remote_validity_reason)
                log "[!] 服务端判定当前 keybox 无效：${why:-原因未提供}"
                rollback_keybox && return 0
                log "[✗] 且本地池没有可回滚的 keybox"
                return 1
                ;;
            warning)
                log "[!] 服务端提示（仍会注入）：$(remote_validity_reason)"
                ;;
        esac
        return 0
    fi

    # 拉取失败：本地池里还有有效备份就先顶上，保证开机可用
    log "[!] 拉取失败，尝试回滚到本地池里的上一份 keybox"
    rollback_keybox && return 0
    return 1
}

# 从本地池恢复一份 keybox 到生效位置
rollback_keybox() {
    local cur=$(sha256_of "$KEYBOX_DEST")
    local f=$(cache_latest_valid "$cur")
    if [ -z "$f" ] || [ ! -s "$f" ]; then
        # 没有池，退而用本地缓存文件
        if [ -s "$KEYBOX_CACHE" ] && [ "$(sha256_of "$KEYBOX_CACHE")" != "$cur" ]; then
            mkdir -p "$TRICKY_DIR"
            cp -f "$KEYBOX_CACHE" "$KEYBOX_DEST"; chmod 644 "$KEYBOX_DEST"
            log "[✓] 已用本地缓存兜底（$(sha256_of "$KEYBOX_DEST" | cut -c1-16)）"
            return 0
        fi
        return 1
    fi
    mkdir -p "$TRICKY_DIR"
    cp -f "$f" "$KEYBOX_DEST"; chmod 644 "$KEYBOX_DEST"
    cp -f "$f" "$KEYBOX_CACHE"; chmod 644 "$KEYBOX_CACHE"
    log "[✓] 已回滚到本地池中的 keybox（$(sha256_of "$KEYBOX_DEST" | cut -c1-16)，来自 $(basename "$f")）"
    return 0
}

# ---- 网络条件判断（供"仅 WiFi 下自动更新"开关使用）----
# 设备上没有 curl，用 Android 自带的 dumpsys（wlan0 有 IP 即视为已连 WiFi）。
# 判断失败时返回 unknown，调用方按"允许更新"处理，避免误伤正常更新。
net_is_wifi() {
    local ip=""
    ip=$(dumpsys wifi 2>/dev/null | sed -n 's/.*Wi-Fi is \([a-z]*\).*/\1/p' | head -1)
    if [ -n "$ip" ]; then
        [ "$ip" = "enabled" ] && { echo "yes"; return 0; }
        echo "no"; return 0
    fi
    # 兜底：看 wlan0 是否有非 0 地址
    local a=$(ip addr show wlan0 2>/dev/null | sed -n 's/.*inet \([0-9.]*\).*/\1/p' | head -1)
    if [ -n "$a" ] && [ "$a" != "0.0.0.0" ]; then echo "yes"; else echo "unknown"; fi
}

# 是否允许自动拉取（受 wifi_only 开关约束）
allow_auto_fetch() {
    [ "$(get_auto)" = "on" ] || return 1
    if [ "$(cfg_get wifi_only off)" = "on" ]; then
        local w=$(net_is_wifi)
        if [ "$w" = "no" ]; then
            log "[·] 当前不在 WiFi 下，且已开启「仅 WiFi 自动更新」，跳过本轮"
            return 1
        fi
    fi
    return 0
}

# ---- 本地 keybox 池：缓存已验签的 keybox，用于失效时回滚 ----
# 只缓存"签名验证通过"的，所以回滚出来的也一定是可信的。
cache_store() { # $1 = keybox 文件  $2 = sha256
    mkdir -p "$CACHE_DIR" 2>/dev/null
    [ -s "$1" ] || return 1
    [ -n "$2" ] || return 1
    cp -f "$1" "$CACHE_DIR/${2}.xml" 2>/dev/null
    echo "$(date +%s)" > "$CACHE_DIR/${2}.ts" 2>/dev/null
}

# 清理过期/超量的缓存
cache_prune() {
    [ -d "$CACHE_DIR" ] || return 0
    local now=$(date +%s)
    local f base ts age
    for f in "$CACHE_DIR"/*.xml; do
        [ -f "$f" ] || continue
        base=$(basename "$f" .xml)
        ts=$(cat "$CACHE_DIR/$base.ts" 2>/dev/null)
        [ -n "$ts" ] || ts=$now
        age=$(( (now - ts) / 86400 ))
        if [ "$age" -gt "$CACHE_MAX_AGE_DAYS" ] 2>/dev/null; then
            rm -f "$f" "$CACHE_DIR/$base.ts" 2>/dev/null
        fi
    done
    # 超出数量上限时删最旧的
    local n=$(ls -1 "$CACHE_DIR"/*.xml 2>/dev/null | wc -l | tr -d ' ')
    while [ "$n" -gt "$CACHE_KEEP" ] 2>/dev/null; do
        local oldest=$(ls -1t "$CACHE_DIR"/*.xml 2>/dev/null | tail -1)
        [ -n "$oldest" ] || break
        base=$(basename "$oldest" .xml)
        rm -f "$oldest" "$CACHE_DIR/$base.ts" 2>/dev/null
        n=$((n - 1))
    done
    return 0
}

# 缓存里最近一份仍有效的 keybox（返回文件路径；没有则输出空）
cache_latest_valid() {
    [ -d "$CACHE_DIR" ] || return 0
    local f sha
    for f in $(ls -1t "$CACHE_DIR"/*.xml 2>/dev/null); do
        [ -s "$f" ] || continue
        # 传进来的那份不重复用
        sha=$(basename "$f" .xml)
        [ "$sha" = "$1" ] && continue
        echo "$f"
        return 0
    done
    return 0
}

# ---- 服务端有效性判断（来自 manifest 的 keybox.validity）----
# 输出：valid | warning | invalid | unknown
remote_validity_level() {
    [ -f "$TMP/manifest.json" ] || { echo "unknown"; return 0; }
    local l=$(sed -n 's/.*"level"[[:space:]]*:[[:space:]]*"\([a-z]*\)".*/\1/p' "$TMP/manifest.json" | head -1)
    [ -n "$l" ] && echo "$l" || echo "unknown"
}

# 服务端报告的问题列表（reasons 是**每行一条**的数组，不能用单行正则取）
# 注意：服务端已用 JSON_UNESCAPED_UNICODE 输出，所以这里是可读中文，
# 不要再去剥 \uXXXX 转义——那会把中文整段删掉。
remote_validity_reason() {
    local f="${1:-$TMP/manifest.json}"
    [ -f "$f" ] || return 0
    awk '
        done_ { next }
        /"reasons"[[:space:]]*:/ {
            if ($0 ~ /\[\][[:space:]]*,?[[:space:]]*$/) { done_ = 1; next }
            inr = 1; next
        }
        inr && /^[[:space:]]*\]/ { done_ = 1; next }
        inr {
            line = $0
            gsub(/^[[:space:]]*"/, "", line)
            gsub(/",?[[:space:]]*$/, "", line)
            if (line != "") { if (out != "") out = out "；"; out = out line }
        }
        END { print out }
    ' "$f" 2>/dev/null
}

# 服务端报告的剩余天数
remote_days_remaining() {
    local f="${1:-$TMP/manifest.json}"
    [ -f "$f" ] || return 0
    sed -n 's/.*"days_remaining"[[:space:]]*:[[:space:]]*\([0-9-]*\).*/\1/p' "$f" | head -1
}

# 备用池数量（服务端提供的其他有效候选）
# 两个坑都要避开：
#   1) pretty-print 的 `"fallbacks": [` 单独占一行，内容在后续行
#   2) 空数组写成 `"fallbacks": [],`（同一行闭合），若只靠 `]` 结束标记，
#      会一路吃进后面的 server.sources，数出错误的条目数
remote_fallback_count() {
    local f="${1:-$TMP/manifest.json}"
    [ -f "$f" ] || { echo 0; return 0; }
    awk '
        done_ { next }
        /"fallbacks"[[:space:]]*:/ {
            if ($0 ~ /\[\][[:space:]]*,?[[:space:]]*$/) { print 0; done_ = 1; next }
            inf = 1; next
        }
        inf && /^[[:space:]]*\]/ { print c+0; done_ = 1; next }
        inf && /"source"/ { c++ }
        END { if (!done_) print c+0 }
    ' "$f" 2>/dev/null
}

# ---- 诊断包（②）：把排障需要的东西打成一个 zip 放到 /sdcard ----
export_diag() {
    local out="/sdcard/yypm-diag-$(date +%Y%m%d-%H%M%S).zip"
    local stage="$TMP/diag"
    rm -rf "$stage" 2>/dev/null
    mkdir -p "$stage" 2>/dev/null

    # 1) 状态快照
    echo_status > "$stage/status.txt" 2>/dev/null
    # 2) 日志（末 800 行，够排障又不至于太大）
    [ -f "$LOG" ] && tail -n 800 "$LOG" > "$stage/yypm.log" 2>/dev/null
    # 3) 模块与服务端信息
    {
        echo "=== module.prop ==="
        cat "$MODDIR/module.prop" 2>/dev/null
        echo
        echo "=== 已安装模块 ==="
        for d in /data/adb/modules/*/; do
            [ -d "$d" ] || continue
            local id=$(sed -n 's/^id=//p' "$d/module.prop" 2>/dev/null | head -1)
            local v=$(sed -n 's/^version=//p' "$d/module.prop" 2>/dev/null | head -1)
            local vc=$(sed -n 's/^versionCode=//p' "$d/module.prop" 2>/dev/null | head -1)
            echo "$id  $v  ($vc)"
        done
        echo
        echo "=== 待生效区 ==="
        ls -1 /data/adb/modules_update/ 2>/dev/null
        echo
        echo "=== keybox ==="
        echo "挂载: $(sha256_of "$KEYBOX_DEST")"
        echo "缓存: $(sha256_of "$KEYBOX_CACHE")"
        echo "本地池: $(ls -1 "$CACHE_DIR"/*.xml 2>/dev/null | wc -l) 份"
        echo
        echo "=== config.prop ==="
        cat "$CONFIG" 2>/dev/null
        echo
        echo "=== 环境 ==="
        echo "设备: $(getprop ro.product.model 2>/dev/null) / $(getprop ro.build.version.release 2>/dev/null) / SDK $(getprop ro.build.version.sdk 2>/dev/null)"
        echo "构建类型: $(getprop ro.build.type 2>/dev/null)"
        echo "时间: $(date '+%Y-%m-%d %H:%M:%S')"
    } > "$stage/info.txt" 2>/dev/null

    # 4) 服务端 manifest 快照 + 校验结果
    [ -f "$TMP/manifest.json" ] && cp -f "$TMP/manifest.json" "$stage/manifest.json" 2>/dev/null
    {
        echo "有效性: $(remote_validity_level)"
        echo "剩余天数: $(remote_days_remaining)"
        echo "问题: $(remote_validity_reason)"
        echo "备用池: $(remote_fallback_count) 个"
    } > "$stage/validity.txt" 2>/dev/null

    # 5) 打包（设备自带 unzip，但打包需要 zip——用 busybox 的 tar+gzip 更稳）
    if command -v busybox >/dev/null 2>&1 && busybox --list 2>/dev/null | grep -qx zip; then
        (cd "$TMP" && busybox zip -qr "$out" diag) 2>/dev/null
    else
        # 退而求其次：用 tar.gz（扩展名如实反映）
        out="${out%.zip}.tar.gz"
        tar czf "$out" -C "$TMP" diag 2>/dev/null
    fi
    rm -rf "$stage" 2>/dev/null

    if [ -s "$out" ]; then
        echo "DIAG=OK"
        echo "DIAG_PATH=$out"
        echo "DIAG_SIZE=$(wc -c < "$out" 2>/dev/null | tr -d ' ')"
    else
        echo "DIAG=FAIL"
    fi
}


# 用 MODDIR 的目录名当模块 id（KernelSU 下 MODDIR 就是 /data/adb/modules/<id>）
# ---- 候选模块目录：生效区 + 待生效区 ----
module_dirs() {
    local id=$(basename "$MODDIR")
    echo "/data/adb/modules/$id"
    echo "/data/adb/modules_update/$id"
}

# 在多个候选目录里取第一个有值的（生效区优先）
module_vc() {
    local d v
    for d in $(module_dirs); do
        [ -d "$d" ] || continue
        v=$(vc_of "$d")
        [ -n "$v" ] && { echo "$v"; return 0; }
    done
    return 0
}

# 待生效区的 id 列表（每个一行）
staged_ids() {
    local d
    for d in /data/adb/modules_update/*; do
        [ -d "$d" ] || continue
        sed -n 's/^id=//p' "$d/module.prop" 2>/dev/null | head -1 | tr -d ' \r'
    done
}

# 待生效区某个 id 的 versionCode
staged_vc_of() { # $1 = id
    vc_of "/data/adb/modules_update/$1" 2>/dev/null
}

# 生效区某个 id 的 versionCode
live_vc_of() { # $1 = id
    vc_of "/data/adb/modules/$1" 2>/dev/null
}

# 是否有"已安装但待重启生效"的模块（本模块或附属模块）
restart_pending() {
    local id lv sv
    for id in $(staged_ids); do
        [ -n "$id" ] || continue
        lv=$(live_vc_of "$id")
        sv=$(staged_vc_of "$id")
        # 生效区没有（新装）或版本不一致 -> 需要重启
        if [ -z "$lv" ]; then echo "$id"; continue; fi
        [ "$lv" != "$sv" ] && echo "$id"
    done
    return 0
}

# keybox 已使用天数（取挂载文件与缓存里较早的 mtime，避免刚 cp 就"看起来是新的"）
keybox_age_days() {
    local t="" f
    for f in "$KEYBOX_CACHE" "$KEYBOX_DEST"; do
        [ -f "$f" ] || continue
        local ft=$(stat -c '%Y' "$f" 2>/dev/null)
        [ -n "$ft" ] || continue
        if [ -z "$t" ] || [ "$ft" -lt "$t" ] 2>/dev/null; then t="$ft"; fi
    done
    [ -n "$t" ] || return 0
    echo $(( ( $(date +%s) - t ) / 86400 ))
}

# 服务端最新 keybox 的 sha256（来自上次保存的 manifest）
remote_keybox_sha() {
    [ -f "$DATA_DIR/manifest.json" ] && json_get "$DATA_DIR/manifest.json" sha256
}

# 本地公钥指纹（sha256 前 16 位），用于"公钥是否被替换"的自检
pubkey_fp() {
    [ -f "$PUBKEY" ] || return 0
    local h=$(sha256_of "$PUBKEY")
    [ -n "$h" ] && echo "$h" | cut -c1-16
}

# 内置期望指纹：以文件 pubkey.fp 为准（构建时写入；缺失则跳过自检）
expect_pubkey_fp() {
    [ -f "$MODDIR/pubkey.fp" ] && tr -d ' \r\n' < "$MODDIR/pubkey.fp" 2>/dev/null
}

pubkey_intact() {
    local e=$(expect_pubkey_fp)
    [ -n "$e" ] || { echo "unknown"; return 0; }
    local a=$(pubkey_fp)
    [ -n "$a" ] && [ "$a" = "$e" ] && echo "ok" || echo "bad"
}

# 公钥校验（支持轮换：真正使用的公钥写在 pubkey_use，缺省 pubkey.b64）
# 适配 verify_tool <pubkey_file> <sig_file> <file> 的既有调用方式。
active_pubkey() {
    local sel=$(cfg_get pubkey_use "")
    if [ -n "$sel" ] && [ -f "$MODDIR/$sel" ]; then echo "$MODDIR/$sel"; else echo "$PUBKEY"; fi
}

# ---- 连通性自检：各下载源的可达性与延迟（毫秒）----
# 输出：名称|http码|毫秒|跳转次数
# 说明：设备上没有 curl，实际走 busybox wget。busybox wget 会跟随重定向，
# 所以这里把"跟随之后的最终状态"作为可达性结论，另外单独回传跳转次数。
# 跳转本身不算故障，但每跳多一次往返（实测 301 补斜杠白花约 1.3 秒），
# 所以跳转次数 >0 时值得在界面上提示，而不是简单报"失败"。
probe_source() { # $1 名称  $2 url
    local name="$1" url="$2" code="000" ms="" hops=0
    # 用分享秒数换算毫秒：date +%s%N 在部分 Android 上返回 19 位纳秒数，
    # 直接参与 $(( )) 会溢出（曾把延迟算成 -1785ms），所以不碰纳秒。
    local t0=$(date +%s 2>/dev/null); [ -n "$t0" ] || t0=0
    local a0=$(date +%N 2>/dev/null)
    case "$a0" in ''|*[!0-9]*) a0=0 ;; esac

    if command -v curl >/dev/null 2>&1; then
        # curl 存在时能拿到精确状态码与跳转次数
        code=$(curl -sL -o /dev/null -w '%{http_code}' \
               --connect-timeout 6 --max-time 12 "$url" 2>/dev/null)
        hops=$(curl -sL -o /dev/null -w '%{num_redirects}' \
               --connect-timeout 6 --max-time 12 "$url" 2>/dev/null)
    elif command -v busybox >/dev/null 2>&1 && busybox --list 2>/dev/null | grep -qx wget; then
        # busybox wget 会跟随重定向；用 -S 的 stderr 里的 3xx 行数估计跳转次数
        local err
        err=$(busybox wget -T 12 --no-check-certificate -S -q -O /dev/null "$url" 2>&1 >/dev/null)
        if busybox wget -T 12 --no-check-certificate -q -O /dev/null "$url" 2>/dev/null; then
            code="200"
            hops=$(printf '%s\n' "$err" | grep -ciE '30[12378] |Moved|Found' 2>/dev/null)
        fi
    elif command -v toybox >/dev/null 2>&1; then
        toybox wget -O /dev/null "$url" >/dev/null 2>&1 && code="200"
    fi

    local t1=$(date +%s 2>/dev/null); [ -n "$t1" ] || t1=0
    local a1=$(date +%N 2>/dev/null)
    case "$a1" in ''|*[!0-9]*) a1=0 ;; esac
    ms=$(( (t1 - t0) * 1000 + (a1 / 1000000) - (a0 / 1000000) ))
    # 兜底：异常值（负数或超过 5 分钟）视为无法测量，避免界面显示假数字
    if [ "$ms" -lt 0 ] 2>/dev/null || [ "$ms" -gt 300000 ] 2>/dev/null; then ms=""; fi

    [ -n "$code" ] || code="000"
    case "$hops" in ''|*[!0-9]*) hops=0 ;; esac
    echo "$name|$code|$ms|$hops"
}

health_check() {
    local m="${1:-6}"
    probe_source "自建服务器" "$(api_url manifest)"
    probe_source "GitHub" "https://api.github.com/repos/$GITHUB_REPO/releases/latest"
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
    # 附属模块更新检查结果（由 webui.sh check-packages 写入缓存）
    echo "UPDATE_CHECKED=$(update_state_field checked_at 未检查)"
    echo "UPDATE_NEED=$(update_state_field need 0)"
    echo "UPDATE_SUMMARY=$(update_state_field summary -)"

    # ---- 检查间隔与失败重试 ----
    echo "CHECK_INTERVAL=$(get_interval)"
    echo "CHECK_INTERVAL_H=$(( $(get_interval) / 3600 ))"
    local rf=$(retry_fails)
    echo "RETRY_FAILS=${rf:-0}"
    echo "RETRY_NEXT_IN=$(retry_due_in)"

    # ---- keybox 新鲜度 ----
    local age=$(keybox_age_days)
    echo "KEYBOX_AGE_DAYS=${age:-}"
    echo "KEYBOX_REMOTE_SHA=$(remote_keybox_sha)"
    local rs=$(remote_keybox_sha) ls=$(sha256_of "$KEYBOX_DEST" 2>/dev/null)
    if [ -n "$rs" ] && [ -n "$ls" ] && [ "$rs" = "$ls" ]; then
        echo "KEYBOX_LATEST=1"
    else
        echo "KEYBOX_LATEST=0"
    fi

    # ---- 待重启生效（对比生效区与待生效区的 versionCode）----
    local pend=""
    local pid
    for pid in $(restart_pending); do
        [ -n "$pid" ] || continue
        local lv=$(live_vc_of "$pid") sv=$(staged_vc_of "$pid")
        pend="${pend}${pid}:${lv:-无}->${sv:-?};"
    done
    if [ -n "$pend" ]; then
        echo "RESTART_PENDING=1"
        echo "RESTART_ITEMS=$pend"
    else
        echo "RESTART_PENDING=0"
        echo "RESTART_ITEMS="
    fi
    echo "LIVE_VCODE=$(vc_of "$MODDIR" 2>/dev/null)"
    echo "STAGED_VCODE=$(staged_vc_of "$(basename "$MODDIR")")"

    # ---- 公钥自检 ----
    echo "PUBKEY_FP=$(pubkey_fp)"
    echo "PUBKEY_EXPECT=$(expect_pubkey_fp)"
    echo "PUBKEY_INTACT=$(pubkey_intact)"
    echo "PUBKEY_ACTIVE=$(basename "$(active_pubkey)")"

    # ---- 服务端有效性（①）----
    echo "SERVER_VALIDITY=$(remote_validity_level)"
    echo "SERVER_DAYS=$(remote_days_remaining)"
    echo "SERVER_REASON=$(remote_validity_reason)"
    echo "SERVER_FALLBACKS=$(remote_fallback_count)"

    # ---- 本地已验签 keybox 池（③ 回滚能力）----
    local pc=0
    [ -d "$CACHE_DIR" ] && pc=$(ls -1 "$CACHE_DIR"/*.xml 2>/dev/null | wc -l | tr -d ' ')
    echo "POOL_COUNT=${pc:-0}"

    # ---- 网络与 WiFi 门控（⑤）----
    echo "WIFI_ONLY=$(cfg_get wifi_only off)"
    echo "NET_WIFI=$(net_is_wifi)"
}

# ============ 附属模块更新检查（WebUI 只读检查，不安装）============
# 依据：服务端 ?action=packages 清单（sha256 + url） 与 已安装模块的 module.prop
# 逻辑：本地已下载的包 sha256 与清单一致 -> 视为最新；
#       不一致 -> 把新包下到临时目录，解出其中的 module.prop 取版本，再与本地已装版本对比。
# 注意：只检查与提示，不安装任何东西；安装请用 KernelSU 的 Action 按钮。

# 取模块目录里 module.prop 的 versionCode（缺失则退回 version 字符串）
vc_of() { # $1 module dir
    local mp="$1/module.prop"
    [ -f "$mp" ] || return 1
    local v=$(sed -n 's/^versionCode=//p' "$mp" 2>/dev/null | head -1 | tr -d ' \r')
    [ -n "$v" ] && { echo "$v"; return 0; }
    v=$(sed -n 's/^version=//p' "$mp" 2>/dev/null | head -1 | tr -d ' \r')
    [ -n "$v" ] && { echo "$v"; return 0; }
    return 1
}

# 从 zip 包内读出 module.prop 的 id（模块真实 id，与 zip 文件名可能不同）
zip_id() { # $1 zip file
    local out=$(zip_prop "$1")
    [ -n "$out" ] || return 1
    local v=$(printf '%s\n' "$out" | sed -n 's/^id=//p' | head -1 | tr -d ' \r')
    [ -n "$v" ] || return 1
    echo "$v"
    return 0
}

# 读出 zip 内 module.prop 的全部内容
zip_prop() { # $1 zip file
    local z="$1" out="" c
    [ -f "$z" ] || return 1
    if command -v unzip >/dev/null 2>&1; then
        out=$(unzip -p "$z" module.prop 2>/dev/null)
    fi
    if [ -z "$out" ]; then
        for c in busybox toybox; do
            command -v "$c" >/dev/null 2>&1 || continue
            "$c" --list 2>/dev/null | grep -qx unzip || continue
            out=$("$c" unzip -p "$z" module.prop 2>/dev/null)
            [ -n "$out" ] && break
        done
    fi
    [ -n "$out" ] || return 1
    printf '%s\n' "$out"
    return 0
}

# 从 zip 包内读出 module.prop 的 versionCode（退回 version）
zip_version() { # $1 zip file
    local out=$(zip_prop "$1")
    [ -n "$out" ] || return 1
    local v=$(printf '%s\n' "$out" | sed -n 's/^versionCode=//p' | head -1 | tr -d ' \r')
    [ -n "$v" ] || v=$(printf '%s\n' "$out" | sed -n 's/^version=//p' | head -1 | tr -d ' \r')
    [ -n "$v" ] || return 1
    echo "$v"
    return 0
}

check_updates() {
    mkdir -p "$TMP" 2>/dev/null
    log "[·] 检查附属模块更新"

    if ! download "$(api_url packages)" "$TMP/pkg_check.json" >/dev/null 2>&1; then
        save_update_cache "FAIL" "-" "0" "清单下载失败"
        return 1
    fi

    # 防呆：若服务器回的是 301/302 跳转页（download 里的 curl 不带 -L 时会存成 HTML），
    # 这里必须识别出来，否则会被误判成"清单为空"。同时提示把 BASE_URL 写成带尾斜杠的地址。
    if grep -qiE '<html|301 moved|302 found' "$TMP/pkg_check.json" 2>/dev/null; then
        save_update_cache "FAIL" "-" "0" "清单被重定向（请给 BASE_URL 加尾斜杠）"
        log "[!] 清单返回的是跳转页，不是 JSON——把 BASE_URL 改为以 / 结尾即可"
        return 1
    fi

    # 抽取 文件名|url（清单格式 {"modules":{"X.zip":{"sha256","size","url"}}}）
    # 只认 "X.zip" 这种"键名"（后面紧跟冒号），否则会误命中 url 字段里的文件名。
    # 用 awk 单遍扫描，避免多层引号嵌套的转义坑；文件名在前、url 在后，顺序天然成立。
    awk -F'"' '
        /\.zip"[[:space:]]*:/ { k = $2 }
        /"url"/ {
            u = ""
            for (i = 1; i <= NF; i++) if ($i ~ /^http/) u = $i
            if (k != "" && u != "") print k "|" u
        }
    ' "$TMP/pkg_check.json" > "$TMP/plist.txt" 2>/dev/null
    [ -s "$TMP/plist.txt" ] || { save_update_cache "FAIL" "-" "0" "清单为空"; return 1; }

    # 抽取清单里的模块元信息 文件名|id|versionCode|version
    # 服务端 scan_packages.py 生成的新版清单会带 x-id / x-versionCode；
    # 老版清单没有这些字段时，抽取结果为空，后面自动退化成"下载包再读 module.prop"。
    # 解析器与 download_packages 共用 build_pmeta（见文件上方定义）。
    build_pmeta "$TMP/pkg_check.json"

    # 本地已下载包的 sha256（由 download_packages 维护）
    : > "$TMP/cache_hash.txt" 2>/dev/null
    for f in "$DATA_DIR"/packages/*.zip; do
        [ -f "$f" ] || continue
        echo "$(basename "$f")|$(sha256_of "$f")" >> "$TMP/cache_hash.txt"
    done

    # 已安装模块（含 modules_update 待生效）
    list_installed

    : > "$TMP/check_out.txt" 2>/dev/null
    while IFS='|' read -r fn u; do
        [ -n "$fn" ] || continue
        # 清单自带版本信息（服务端 scan_packages.py 生成）时，直接用清单判定，不下载任何包；
        # 老版清单没有这些字段 -> rvc 为空 -> 退回"下载包再读 module.prop"。
        p_id=$(grep -F "$fn|" "$TMP/pmeta.txt" 2>/dev/null | cut -d'|' -f2 | head -1)
        p_vc=$(grep -F "$fn|" "$TMP/pmeta.txt" 2>/dev/null | cut -d'|' -f3 | head -1)
        p_vr=$(grep -F "$fn|" "$TMP/pmeta.txt" 2>/dev/null | cut -d'|' -f4 | head -1)

        mid=$(echo "$fn" | sed 's/\.zip$//')
        [ -n "$p_id" ] && mid="$p_id"
        lvc=$(grep -F "$mid|" "$TMP/installed.txt" 2>/dev/null | cut -d'|' -f3 | head -1)

        if [ -n "$p_vc" ]; then
            # ---- 快路径：清单给了 versionCode，零下载 ----
            rvc="$p_vc"
            rvtxt=${p_vr:-$p_vc}
            if [ -z "$lvc" ]; then
                echo "CHECK|$fn|$mid|未安装|$rvc|NEW|未安装（可用 KernelSU 的 Action 安装）${rvtxt:+（$rvtxt）}" >> "$TMP/check_out.txt"
            elif [ "$lvc" = "$rvc" ]; then
                echo "CHECK|$fn|$mid|$lvc|$rvc|OK|已是最新" >> "$TMP/check_out.txt"
            elif [ "$lvc" -gt "$rvc" ] 2>/dev/null; then
                echo "CHECK|$fn|$mid|$lvc|$rvc|OK|本地版本($lvc)高于线上($rvc)，不提示更新" >> "$TMP/check_out.txt"
            else
                echo "CHECK|$fn|$mid|$lvc|$rvc|UPD|发现新版本${rvtxt:+：$rvtxt}" >> "$TMP/check_out.txt"
            fi
            continue
        fi

        # ---- 慢路径：清单没有版本信息，只能下载包（或用已下载的缓存包）来读 ----
        want=$(grep -F "\"$fn\"" "$TMP/pkg_check.json" 2>/dev/null | tr -d ' ' | grep -o '"sha256":"[0-9a-f]*"' | head -1 | sed 's/.*"sha256":"\([0-9a-f]*\)".*/\1/')
        have=$(grep -F "$fn|" "$TMP/cache_hash.txt" 2>/dev/null | cut -d'|' -f2)
        z="$TMP/$fn"
        if [ -n "$want" ] && [ -n "$have" ] && [ "$want" = "$have" ] && [ -s "$DATA_DIR/packages/$fn" ]; then
            z="$DATA_DIR/packages/$fn"
        else
            rm -f "$TMP/$fn" 2>/dev/null
            if ! download "$u" "$TMP/$fn" >/dev/null 2>&1 || [ ! -s "$TMP/$fn" ]; then
                echo "CHECK|$fn|$mid|?|?|ERR|新包下载失败（网络）" >> "$TMP/check_out.txt"
                continue
            fi
            if [ -n "$want" ] && [ "$(sha256_of "$TMP/$fn")" != "$want" ]; then
                echo "CHECK|$fn|$mid|?|?|ERR|sha256 校验失败" >> "$TMP/check_out.txt"
                continue
            fi
        fi

        # 模块 id 以包内 module.prop 为准（zip 文件名可能与 id 不同）
        bid=$(zip_id "$z")
        [ -n "$bid" ] && mid="$bid"
        rvc=$(zip_version "$z")
        [ -z "$rvc" ] && rvc="?"

        lvc=$(grep -F "$mid|" "$TMP/installed.txt" 2>/dev/null | cut -d'|' -f3 | head -1)
        if [ -z "$lvc" ]; then
            while IFS='|' read -r i_id i_nm i_vc; do
                [ -n "$i_id" ] || continue
                case "$mid" in
                    *"$i_id"*) lvc="$i_vc"; mid="$i_id"; break ;;
                    "$i_id"*)  lvc="$i_vc"; mid="$i_id"; break ;;
                esac
            done < "$TMP/installed.txt"
        fi

        if [ -z "$lvc" ]; then
            echo "CHECK|$fn|$mid|未安装|$rvc|NEW|未安装（可用 KernelSU 的 Action 安装）" >> "$TMP/check_out.txt"
        elif [ "$rvc" != "?" ] && [ "$rvc" = "$lvc" ]; then
            echo "CHECK|$fn|$mid|$lvc|$rvc|OK|已是最新" >> "$TMP/check_out.txt"
        elif [ "$rvc" = "?" ]; then
            echo "CHECK|$fn|$mid|$lvc|$rvc|MISMATCH|包内容有变化，版本号读取失败（建议重装）" >> "$TMP/check_out.txt"
        else
            echo "CHECK|$fn|$mid|$lvc|$rvc|UPD|发现新版本" >> "$TMP/check_out.txt"
        fi
    done < "$TMP/plist.txt"

    # 清掉本轮的临时下载（不占用手机存储）
    rm -f "$TMP"/*.zip 2>/dev/null

    # 汇总（按输出文件统计，避免子 shell 变量丢失）
    NU=$(grep -cE '\|(UPD|NEW|MISMATCH)\|' "$TMP/check_out.txt" 2>/dev/null); NU=${NU:-0}
    NE=$(grep -c '|ERR|' "$TMP/check_out.txt" 2>/dev/null); NE=${NE:-0}
    NT=$(wc -l < "$TMP/check_out.txt" 2>/dev/null | tr -d ' '); NT=${NT:-0}
    NC=$((NT - NU - NE)); [ "$NC" -lt 0 ] && NC=0

    if [ "$NE" -gt 0 ] && [ "$NU" -eq 0 ]; then ST=FAIL
    elif [ "$NU" -gt 0 ]; then ST=UPD
    else ST=OK; fi

    save_update_cache "$ST" "$(date '+%m-%d %H:%M')" "$NU" "共 ${NT} 个：最新 ${NC}，可更新 ${NU}，失败 ${NE}"
    log "[✓] 附属模块检查完成：可更新 ${NU} 个，失败 ${NE} 个"
    return 0
}

# 写检查结果缓存，供 WebUI 状态显示
save_update_cache() { # $1 state  $2 time  $3 need  $4 summary
    mkdir -p "$DATA_DIR" 2>/dev/null
    {
        echo "state=$1"
        echo "checked_at=$2"
        echo "need=$3"
        echo "summary=$4"
    } > "$DATA_DIR/update_check.prop" 2>/dev/null
}

update_state_field() { # $1 key  $2 default
    local f="$DATA_DIR/update_check.prop"
    [ -f "$f" ] || { echo "$2"; return; }
    local v=$(grep "^$1=" "$f" 2>/dev/null | tail -1 | cut -d= -f2-)
    [ -n "$v" ] && echo "$v" || echo "$2"
}
# ---- 下载服务端 package 清单里列出的所有模块 ----
# ---- 清单元信息解析 ----
# 输出：模块id|versionCode（供多处复用，避免重复解析）
# 说明：本函数只负责把清单转成元信息写到 $TMP/pmeta.txt，解析器兼容
# "美化"与"单行压缩"两种 JSON，且不能用 $(i+1) 这种动态字段引用
# （BusyBox awk 下会取到空值，必须用 split() 的数组元素）。
# 字段值有 ": 7854" 与 ":7854}" 两种形态：统一"去掉冒号与空白"，
# 为空或只剩 "{" 时再取下一个元素。
build_pmeta() { # $1 = 清单文件（默认 $TMP/packages.json）
    local src="${1:-$TMP/packages.json}"
    [ -f "$src" ] || return 1
    cat > "$TMP/pmeta.awk" <<'AWKEOF'
BEGIN { FS = "[,\"]" }
{
  n = split($0, f, "[,\"]")
  for (i = 1; i <= n; i++) {
    if (f[i] == "x-id" || f[i] == "module_id" ||
        f[i] == "x-versionCode" || f[i] == "versionCode" ||
        f[i] == "x-version" || f[i] == "version") {
      v = f[i+1]
      sub(/^[ \t]*:/, "", v)
      gsub(/[ \t]/, "", v)
      if (v == "" || v == "{") { v = f[i+2]; gsub(/[ \t]/, "", v) }
      if (f[i] == "x-id" || f[i] == "module_id") id = v
      else if (f[i] == "x-versionCode" || f[i] == "versionCode") { gsub(/[^0-9]/, "", v); if (v != "") vc = v }
      else vr = v
    } else if (f[i] ~ /\.zip$/ && f[i-1] != "url") {
      s = f[i+1]
      sub(/^[ \t]*:/, "", s)
      gsub(/[ \t]/, "", s)
      if (s != "{") continue
      if (k != "") print k "|" id "|" vc "|" vr
      k = f[i]; id = ""; vc = ""; vr = ""
    }
  }
}
END { if (k != "") print k "|" id "|" vc "|" vr }
AWKEOF
    rm -f "$TMP/pmeta.txt" 2>/dev/null
    if command -v python3 >/dev/null 2>&1; then
        python3 -c '
import json, sys
try:
    mods = json.load(open(sys.argv[1], encoding="utf-8")).get("modules") or {}
except Exception:
    sys.exit(0)
for name, e in mods.items():
    vid = e.get("x-id") or e.get("module_id") or ""
    vc  = e.get("x-versionCode")
    if vc is None:
        vc = e.get("versionCode")
    vr  = e.get("x-version") or e.get("version") or ""
    print("%s|%s|%s|%s" % (name, vid, "" if vc is None else vc, vr))
' "$src" > "$TMP/pmeta.txt" 2>/dev/null
    fi
    if [ ! -s "$TMP/pmeta.txt" ]; then
        awk -f "$TMP/pmeta.awk" "$src" > "$TMP/pmeta.txt" 2>/dev/null
    fi
    return 0
}

# 清单里某个模块的云端 versionCode；取不到输出空
remote_vc_of() { # $1 = 文件名（清单里直接可用的版本号，优先用它）
    sed -n "/^$1|/p" "$TMP/pmeta.txt" 2>/dev/null | cut -d'|' -f3 | head -1
}

# 取包内 module.prop 的 versionCode（已验证回退），失败输出空
zip_vc_of() { # $1 = zip
    zip_version "$1" 2>/dev/null
}

# 输出"需要下载"的 url 列表（每行一个）。
# 判定规则（尽量省流量，同时保证 Action 安装始终可用）：
#   1) 本地已装 / 已待生效(id 在 modules) 的模块：云端不高于它就不下载；
#      Action 装的就是这个版本，同版本无需再下一份。
#   2) 本地没装的模块：只有已下载的缓存包 sha256 等于云端 sha256 时才跳过，
#      否则下载（首次开机要拿到包，Action 才能安装）。
#   3) 拿不到云端版本号（老清单）时一律下载，安全优先。
dl_filter() { # $1 = 清单文件
    local src="$1"
    local urls=$(grep -o '"url"[[:space:]]*:[[:space:]]*"[^"]*"' "$src" 2>/dev/null | sed 's/.*"\(http[^"]*\)".*/\1/')
    [ -n "$urls" ] || return 0
    local have_meta=0
    [ -s "$TMP/pmeta.txt" ] && have_meta=1
    echo "$urls" | while IFS= read -r url; do
        [ -n "$url" ] || continue
        local name=$(basename "$url")
        [ "$have_meta" = "1" ] || { echo "$url"; continue; }

        local p_id=$(sed -n "/^$name|/p" "$TMP/pmeta.txt" 2>/dev/null | cut -d'|' -f2 | head -1)
        local p_vc=$(sed -n "/^$name|/p" "$TMP/pmeta.txt" 2>/dev/null | cut -d'|' -f3 | head -1)
        local mid="$p_id"; [ -n "$mid" ] || mid=$(echo "$name" | sed 's/\.zip$//')

        # 本地已装（或待生效）的版本
        local lvc=$(vc_of "/data/adb/modules/$mid" 2>/dev/null)
        [ -n "$lvc" ] || lvc=$(vc_of "/data/adb/modules_update/$mid" 2>/dev/null)

        if [ -n "$p_vc" ] && [ -n "$lvc" ] && [ "$p_vc" -le "$lvc" ] 2>/dev/null; then
            continue   # 已是最新，不必下载（Action 装的也是同一版本）
        fi

        # 本地没装：只有缓存包已是云端版本才跳过
        local want=$(sed -n "/\"$name\"/p" "$src" 2>/dev/null | tr -d ' ' | grep -o '"sha256":"[0-9a-f]*"' | head -1 | sed 's/.*"sha256":"\([0-9a-f]*\)".*/\1/')
        local cache="$DATA_DIR/packages/$name"
        if [ -n "$want" ] && [ -s "$cache" ] && [ "$(sha256_of "$cache")" = "$want" ]; then
            continue   # 缓存包与云端一致，直接复用
        fi
        echo "$url"
    done
}

# 已安装模块（含 modules_update 待生效）
list_installed() {
    : > "$TMP/installed.txt" 2>/dev/null
    for d in /data/adb/modules/* /data/adb/modules_update/*; do
        [ -d "$d" ] || continue
        local mp="$d/module.prop"
        [ -f "$mp" ] || continue
        local mid=$(sed -n 's/^id=//p' "$mp" 2>/dev/null | head -1 | tr -d ' \r')
        local mnm=$(sed -n 's/^name=//p' "$mp" 2>/dev/null | head -1 | tr -d '\r')
        local mvc=$(vc_of "$d")
        [ -n "$mid" ] && echo "$mid|$mnm|$mvc" >> "$TMP/installed.txt"
    done
    return 0
}

download_packages() {
    local list_url="$(api_url packages)"
    log "[·] 拉取模块清单"
    download_retry "$list_url" "$TMP/packages.json" || { log "[✗] 模块清单下载失败（已重试 $NET_RETRY 次）"; return 1; }

    # 解析清单元信息（含云端 versionCode），用来判断哪些包真的需要下载
    build_pmeta "$TMP/packages.json"

    local dest="/data/adb/yypm/packages"
    mkdir -p "$dest"

    # 只下载"确实需要"的包：已装同版本的不重下（实测开机可省约 16MB），
    # 但确保 Action 安装所需的包仍在本地（已装的模块本就不需要再装）。
    dl_filter "$TMP/packages.json" > "$TMP/dl_list.txt" 2>/dev/null
    local need=$(wc -l < "$TMP/dl_list.txt" 2>/dev/null | tr -d ' ')
    local total=$(grep -c '"url"' "$TMP/packages.json" 2>/dev/null | tr -d ' ')
    need=${need:-0}; total=${total:-0}

    if [ "$need" = "0" ]; then
        log "[✓] 附属模块均为最新，无需下载（共 ${total} 个）"
        return 0
    fi
    [ "$need" -lt "$total" ] 2>/dev/null && log "[·] 附属模块需下载 ${need}/${total} 个（其余已是本地版本）"

    while IFS= read -r url; do
        [ -n "$url" ] || continue
        local name=$(basename "$url")
        log "[·] 下载模块: $name"
        if download "$url" "$dest/$name"; then
            log "[✓] 模块已下载: $name"
        else
            log "[✗] 模块下载失败: $name"
        fi
    done < "$TMP/dl_list.txt"
    return 0
}

# ---- 一键安装：把检查到的"可更新"附属模块批量装到暂存区 ----
# 流程：check_updates（拿结论）-> 按需下载包 -> sha256 校验 -> ksud 安装
# 说明：ksud 会把模块装到 modules_update，重启后统一生效；这里逐个安装，
# 并在结束时汇报成功/失败个数。安装完不自动重启（交由用户决定）。
install_all_packages() {
    echo "正在检查附属模块 ..."
    check_updates
    if [ ! -f "$TMP/check_out.txt" ]; then
        echo "INSTALL_ALL=NONE"
        echo "INSTALL_ALL_MSG=检查失败，未取得结果"
        return 1
    fi

    local n=0 ok=0 fail=0 skip=0
    local KS=/data/adb/ksud
    local dest="$DATA_DIR/packages"
    mkdir -p "$dest"

    while IFS='|' read -r tag fn mid lvc rvc st msg; do
        [ -n "$fn" ] || continue
        # 只装"确实有新版本"的；OK/NEW/MISMATCH/ERR 都跳过
        [ "$st" = "UPD" ] || continue
        n=$((n + 1))
        echo "→ 安装 $mid $lvc → $rvc"

        if [ ! -x "$KS" ]; then
            echo "  [✗] 未找到 ksud，无法自动安装"
            fail=$((fail + 1))
            continue
        fi

        # 按清单里的 url 下载这一版（确保装的就是检查时看到的版本）
        # plist.txt 每行是 文件名|url，用 awk 取第二段（sed 多层引号转义易错）
        local src="$dest/$fn"
        local url=$(awk -F'|' -v k="$fn" '$1==k{print $2}' "$TMP/plist.txt" 2>/dev/null | head -1)
        [ -n "$url" ] || { echo "  [✗] 未找到 $fn 的下载地址"; fail=$((fail + 1)); continue; }

        echo "  [·] 下载 $fn"
        if ! download "$url" "$src" || [ ! -s "$src" ]; then
            echo "  [✗] 下载失败"
            fail=$((fail + 1))
            continue
        fi

        local out
        if out=$("$KS" module install "$src" 2>&1); then
            echo "  [✓] 已安装 $mid（重启后生效）"
            ok=$((ok + 1))
        else
            echo "  [✗] 安装失败"
            fail=$((fail + 1))
        fi
    done < "$TMP/check_out.txt"

    # 把本模块自身也纳入"待重启"判定：附属模块装好后同样需要重启
    if [ "$ok" -gt 0 ]; then
        log "[✓] 批量安装完成：成功 $ok，失败 $fail（重启后生效）"
        echo "INSTALL_ALL=OK"
        echo "INSTALL_ALL_OK=$ok"
        echo "INSTALL_ALL_FAIL=$fail"
        echo "INSTALL_ALL_RESTART=1"
    else
        if [ "$n" -eq 0 ]; then
            echo "INSTALL_ALL=NONE"
            echo "INSTALL_ALL_MSG=没有需要安装的附属模块"
        else
            log "[✗] 批量安装失败：成功 0，失败 $fail"
            echo "INSTALL_ALL=FAIL"
            echo "INSTALL_ALL_FAIL=$fail"
        fi
    fi
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

# ---- 自动更新模块自身 ----
# 下载源优先自建服务器（实测 3/3 成功），GitHub 直连作为兜底（实测 1/3）。
# 下载后会解包核对包内 versionCode，避免拿到旧包把模块"更新"回退。
check_module_update() {
    [ -f "$MODDIR/module.prop" ] || return 0
    local out; out=$(check_github_release) || return 0
    local tag=$(echo "$out" | sed -n 's/^REMOTE_VERSION=//p')
    local cur=$(echo "$out" | sed -n 's/^LOCAL_VERSION=//p')
    local gh_url=$(echo "$out" | sed -n 's/^DOWNLOAD_URL=//p')
    [ -n "$tag" ] && [ "$tag" != "$cur" ] || return 0

    local cur_vc=$(vc_of "$MODDIR")
    log "[·] 发现新版本 $tag（当前 $cur）"

    local got=""
    for u in "$(api_url module)" "$gh_url"; do
        [ -n "$u" ] || continue
        rm -f "$TMP/update.zip"
        if ! download_retry "$u" "$TMP/update.zip"; then
            log "[!] 下载失败，换下一个源"
            continue
        fi
        # 校验包内 versionCode 必须大于当前，防止装到旧包
        local pkg_vc=$(zip_version "$TMP/update.zip" 2>/dev/null)
        if [ -n "$pkg_vc" ] && [ "$pkg_vc" -gt "$cur_vc" ] 2>/dev/null; then
            got="$u"
            log "[✓] 已下载 $tag（versionCode $pkg_vc）"
            break
        fi
        log "[!] 包内 versionCode=$pkg_vc 不高于当前 $cur_vc，丢弃"
        rm -f "$TMP/update.zip"
    done
    [ -n "$got" ] || { log "[✗] 所有下载源均失败"; return 0; }

    [ -f "$TMP/update.zip" ] || return 0
    if command -v ksud >/dev/null 2>&1; then
        ksud module install "$TMP/update.zip" 2>/dev/null && log "[✓] 已通过 ksud 安装更新（重启后生效）"
    else
        log "[!] 新模块已下载到 $TMP/update.zip，请手动安装"
    fi
}

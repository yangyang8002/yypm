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

# 下载重试（开机时网络往往尚未就绪，单次失败会白等一个周期）
NET_RETRY=3
NET_RETRY_DELAY=20

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

# ---- 获取并挂载 keybox（下载 -> 校验 -> 验签 -> 写 tricky_store）----
fetch_keybox() {
    mkdir -p "$TMP"
    log "[·] 拉取 manifest"
    download_retry "$BASE_URL?action=manifest" "$TMP/manifest.json" || { log "[✗] manifest 下载失败（已重试 $NET_RETRY 次）"; return 1; }

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
    # 附属模块更新检查结果（由 webui.sh check-packages 写入缓存）
    echo "UPDATE_CHECKED=$(update_state_field checked_at 未检查)"
    echo "UPDATE_NEED=$(update_state_field need 0)"
    echo "UPDATE_SUMMARY=$(update_state_field summary -)"
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

    if ! download "$BASE_URL?action=packages" "$TMP/pkg_check.json" >/dev/null 2>&1; then
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

    # 兜底用的 awk 程序（无 python 的机器走这条）：先写好文件再用 -f 调用，
    # 避免把 awk 脚本内嵌在 shell 引号里被解析坏（踩过坑）。
    #
    # 注意：必须兼容"美化"与"单行压缩"两种 JSON 形态，且不能在 awk 里用
    # $(i+1) 这种动态字段引用——BusyBox awk 在这种写法下会取到空值，
    # 必须用 split() 得到的数组元素。字段值有两种形态：": 7854" 与 ":7854}"，
    # 统一"去掉冒号与空白，为空或只剩 {" 时再取下一个元素"。
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

    # 抽取清单里的模块元信息 文件名|id|versionCode|version
    # 服务端 scan_packages.py 生成的新版清单会带 x-id / x-versionCode；
    # 老版清单没有这些字段时，抽取结果为空，后面自动退化成"下载包再读 module.prop"。
    # 解析优先用 python（不装 python 或解析失败就回退到 awk）。
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
' "$TMP/pkg_check.json" > "$TMP/pmeta.txt" 2>/dev/null
    fi
    if [ ! -s "$TMP/pmeta.txt" ]; then
        # 兜底：老清单没有 x- 字段时这里也会是空，正好让后面走"下载包再读 module.prop"
        awk -f "$TMP/pmeta.awk" "$TMP/pkg_check.json" > "$TMP/pmeta.txt" 2>/dev/null
    fi

    # 本地已下载包的 sha256（由 download_packages 维护）
    : > "$TMP/cache_hash.txt" 2>/dev/null
    for f in "$DATA_DIR"/packages/*.zip; do
        [ -f "$f" ] || continue
        echo "$(basename "$f")|$(sha256_of "$f")" >> "$TMP/cache_hash.txt"
    done

    # 已安装模块（含 modules_update 待生效）
    : > "$TMP/installed.txt" 2>/dev/null
    for d in /data/adb/modules/* /data/adb/modules_update/*; do
        [ -d "$d" ] || continue
        mp="$d/module.prop"
        [ -f "$mp" ] || continue
        mid=$(sed -n 's/^id=//p' "$mp" 2>/dev/null | head -1 | tr -d ' \r')
        mnm=$(sed -n 's/^name=//p' "$mp" 2>/dev/null | head -1 | tr -d '\r')
        mvc=$(vc_of "$d")
        [ -n "$mid" ] && echo "$mid|$mnm|$mvc" >> "$TMP/installed.txt"
    done

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
download_packages() {
    local list_url="$BASE_URL?action=packages"
    log "[·] 拉取模块清单"
    download_retry "$list_url" "$TMP/packages.json" || { log "[✗] 模块清单下载失败（已重试 $NET_RETRY 次）"; return 1; }

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
    for u in "$BASE_URL?action=module" "$gh_url"; do
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

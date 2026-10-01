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
# ---- 适配的 Android 版本 ----
# 适配范围：Android 13 (API 33) ~ Android 17 (API 37)。
# 依赖的系统能力：
#   app_process   —— appinfo.dex 跑在它上面（按 app_process64 -> app_process -> app_process32 探测）
#   pm hide       —— 隐藏应用列表
#   resetprop     —— 属性伪装（KernelSU / Magisk 提供）
# 低于 API 33 时这些能力的现代行为不齐，不保证可用；高于 API 37 属未验证区间。
SDK_MIN=33
SDK_MAX=37

sdk_now() { getprop ro.build.version.sdk 2>/dev/null | tr -d ' \r'; }

# ok / old / new / unknown
sdk_state() {
    local s=$(sdk_now)
    [ -n "$s" ] || { echo unknown; return 0; }
    if [ "$s" -lt "$SDK_MIN" ] 2>/dev/null; then echo old
    elif [ "$s" -gt "$SDK_MAX" ] 2>/dev/null; then echo new
    else echo ok; fi
}

# 给人看的版本串，例如 Android 16 (API 36)
sdk_label() {
    local s=$(sdk_now) r=$(getprop ro.build.version.release 2>/dev/null | tr -d ' \r')
    echo "Android ${r:-?} (API ${s:-?})"
}

# 一行结论，供 WebUI 直接显示
sdk_report() {
    local st=$(sdk_state)
    echo "SDK_LABEL=$(sdk_label)"
    echo "SDK_NOW=$(sdk_now)"
    echo "SDK_MIN=$SDK_MIN"
    echo "SDK_MAX=$SDK_MAX"
    echo "SDK_STATE=$st"
    case "$st" in
        ok)  echo "SDK_TEXT=在适配范围内（Android 13-17）" ;;
        old) echo "SDK_TEXT=低于适配范围（需要 Android 13 / API 33 及以上），不保证可用" ;;
        new) echo "SDK_TEXT=高于已验证范围（Android 17 / API 37），可能有兼容问题" ;;
        *)   echo "SDK_TEXT=读不到系统版本" ;;
    esac
}

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

# 隐藏 BL 的属性层：伪造 bootloader 为锁定状态
hide_bl_props() {
    local rp; rp=$(get_resetprop) || return 1
    # 基础 5 项
    "$rp" ro.boot.verifiedbootstate green 2>/dev/null
    "$rp" ro.boot.flash.locked 1 2>/dev/null
    "$rp" ro.boot.vbmeta.device_state locked 2>/dev/null
    "$rp" ro.boot.warranty_bit 0 2>/dev/null
    "$rp" ro.boot.veritymode enforcing 2>/dev/null
    # 检测方还会读下面这几个键。不一起补的话，属性面自相矛盾，
    # 反而会被判成「启动状态异常」（属性说 locked、别的键说 unlocked）。
    "$rp" vendor.boot.verifiedbootstate green 2>/dev/null
    "$rp" vendor.boot.vbmeta.device_state locked 2>/dev/null
    "$rp" sys.oem_unlock_allowed 0 2>/dev/null
    return 0
}

# 隐藏 BL：伪造 bootloader 为锁定状态
hide_bl() {
    hide_bl_props || { log "[✗] 未找到 resetprop"; return 1; }
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

# =========================================================
# 环境对抗（对抗「春秋检测」这类环境检测）
# ---------------------------------------------------------
# 检测方是分层判断的：
#   1) 应用列表：装了 MT 管理器、风控敏感应用
#   2) 异常文件：MT2 之类的落地目录
#   3) getprop：ro.boot.verifiedbootstate 等        -> hide_bl 覆盖
#   4) 内核原始痕迹：/proc/cmdline、/proc/bootconfig -> resetprop 覆盖不到
#      而且属性与内核命令行对不上，本身就会被判「启动状态异常」
#
# 取舍：resetprop 改不到的，只有内核级（SUSFS）或 Zygisk 钩子（Shamiko）
# 能覆盖。没有这类支撑时**不硬来**——bind mount 会在 /proc/self/mountinfo
# 里留下劫持痕迹，反而让检测更容易命中。
# =========================================================

# ---- 4. 深度伪装启动状态 ----
# 有没有能"隐藏 mount 劫持痕迹"的支撑（Shamiko / SUSFS）
mount_hider_present() {
    [ -d /data/adb/modules/zygisk_shamiko ] && { echo shamiko; return 0; }
    [ -d /data/adb/modules/shamiko ]        && { echo shamiko; return 0; }
    [ -d /data/adb/modules/susfs4ksu ]      && { echo susfs;   return 0; }
    [ -e /proc/susfs ]                      && { echo susfs;   return 0; }
    [ -x /data/adb/ksu/bin/susfs ]          && { echo susfs;   return 0; }
    return 1
}

# 把内核命令行里的解锁特征改成锁定特征（单行、空格分隔）
spoof_cmdline_text() { # stdin -> stdout
    tr ' ' '\n' | sed \
        -e 's/^androidboot\.verifiedbootstate=.*/androidboot.verifiedbootstate=green/' \
        -e 's/^androidboot\.flash\.locked=.*/androidboot.flash.locked=1/' \
        -e 's/^androidboot\.vbmeta\.device_state=.*/androidboot.vbmeta.device_state=locked/' \
        -e 's/^androidboot\.warranty_bit=.*/androidboot.warranty_bit=0/' \
        -e 's/^androidboot\.veritymode=.*/androidboot.veritymode=enforcing/'
}

spoof_cmdline_file() { # $1 源  $2 目标
    [ -r "$1" ] || return 1
    # 先无条件补上两个关键键，再按「同名键只留第一条」去重：
    # 原命令行里已有的键被 sed 改写过、排在最前，所以留下的就是改写后的值；
    # 原本没有的键则由这里补上（键不存在同样会被判异常）。
    # 注意不能逐条 grep 后再 >> 追加：文件末尾没有换行时两条会粘成一条。
    {
        spoof_cmdline_text < "$1"
        echo
        echo androidboot.verifiedbootstate=green
        echo androidboot.flash.locked=1
    } > "$2.tmp" 2>/dev/null || return 1
    awk -F= '!seen[$1]++' "$2.tmp" 2>/dev/null | tr '\n' ' ' > "$2" 2>/dev/null
    rm -f "$2.tmp" 2>/dev/null
    return 0
}

# bootconfig 是「key = value」逐行格式，单独处理
spoof_bootconfig_file() { # $1 源  $2 目标
    [ -r "$1" ] || return 1
    sed \
        -e 's/^\(androidboot\.verifiedbootstate\)[[:space:]]*=.*/\1 = green/' \
        -e 's/^\(androidboot\.flash\.locked\)[[:space:]]*=.*/\1 = 1/' \
        -e 's/^\(androidboot\.vbmeta\.device_state\)[[:space:]]*=.*/\1 = locked/' \
        -e 's/^\(androidboot\.warranty_bit\)[[:space:]]*=.*/\1 = 0/' \
        -e 's/^\(androidboot\.veritymode\)[[:space:]]*=.*/\1 = enforcing/' \
        < "$1" > "$2" 2>/dev/null || return 1
    return 0
}

hide_bl_deep() {
    hide_bl_props || { log "[✗] 未找到 resetprop"; return 1; }
    local hider; hider=$(mount_hider_present) || hider=""
    if [ -z "$hider" ]; then
        log "[!] 深度伪装未执行：没有 SUSFS 内核支持，也没装 Shamiko。"
        log "    /proc/cmdline、/proc/bootconfig 由内核提供，resetprop 改不了；"
        log "    直接 bind mount 会在 mountinfo 里留下劫持痕迹，反而更易被检出。"
        log "    请换带 SUSFS 的内核，或装 Shamiko（Zygisk）后再开本项。"
        return 2
    fi
    local sp="$DATA_DIR/spoof"
    mkdir -p "$sp" 2>/dev/null
    local n=0
    if spoof_cmdline_file /proc/cmdline "$sp/cmdline" && mount --bind "$sp/cmdline" /proc/cmdline 2>/dev/null; then
        n=$((n + 1)); log "[✓] 已伪装 /proc/cmdline（支撑：$hider）"
    else
        log "[!] /proc/cmdline 伪装失败"
    fi
    if [ -e /proc/bootconfig ] && spoof_bootconfig_file /proc/bootconfig "$sp/bootconfig" \
       && mount --bind "$sp/bootconfig" /proc/bootconfig 2>/dev/null; then
        n=$((n + 1)); log "[✓] 已伪装 /proc/bootconfig（支撑：$hider）"
    fi
    log "[✓] 深度伪装完成（$n 项，支撑：$hider）"
    return 0
}

# ---- 1. 可定制隐藏应用列表 ----
# 用系统自带 pm hide 把指定包从「其它应用可见的包列表」里摘掉。
# 与 HMA（隐藏应用列表）的分工：pm hide 是系统级、对所有应用生效但粒度粗；
# HMA 按应用定制可见性、更精细。两者可以并存。
HIDE_APPS_MARK="$DATA_DIR/hide_apps.applied"

hide_apps_enabled() { [ "$(cfg_get hide_apps_enable off)" = "on" ]; }

# 归一化：逗号/分号/空白分隔 -> 每行一个包名
hide_apps_normalize() { # stdin -> stdout
    tr ',;' '\n\n' | tr ' \t' '\n\n' \
        | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' \
        | grep -E '^[A-Za-z0-9_][A-Za-z0-9_.]*$' | sort -u
}

hide_apps_list() { printf '%s\n' "$(cfg_get hide_apps '')" | hide_apps_normalize; }

pm_bin() {
    if [ -x /system/bin/pm ]; then echo /system/bin/pm; return 0; fi
    if command -v pm >/dev/null 2>&1; then echo pm; return 0; fi
    return 1
}

# 已隐藏的包数（以本模块的记录为准）
hide_apps_applied() {
    [ -f "$HIDE_APPS_MARK" ] || { echo 0; return 0; }
    grep -cv '^#' "$HIDE_APPS_MARK" 2>/dev/null
}

hide_apps_apply() {
    local pm; pm=$(pm_bin) || { log "[✗] 未找到 pm，无法隐藏应用"; return 1; }
    local list; list=$(hide_apps_list)
    [ -n "$list" ] || { log "[!] 隐藏应用列表为空，跳过"; return 1; }
    mkdir -p "$DATA_DIR" 2>/dev/null
    printf '#%s\n' "$(printf '%s' "$list" | tr '\n' ',')" > "$HIDE_APPS_MARK"
    local n=0 ok=0 p
    for p in $list; do
        n=$((n + 1))
        if "$pm" hide "$p" >/dev/null 2>&1; then
            ok=$((ok + 1)); echo "$p" >> "$HIDE_APPS_MARK"
        else
            log "[!] 隐藏失败：$p（未安装或系统不允许）"
        fi
    done
    log "[✓] 隐藏应用列表已应用：$ok/$n"
    return 0
}

hide_apps_restore() {
    local pm; pm=$(pm_bin) || return 1
    [ -f "$HIDE_APPS_MARK" ] || { log "[·] 没有已隐藏的应用"; return 0; }
    local n=0 p
    while read -r p; do
        case "$p" in ''|'#'*) continue ;; esac
        "$pm" unhide "$p" >/dev/null 2>&1 && n=$((n + 1))
    done < "$HIDE_APPS_MARK"
    rm -f "$HIDE_APPS_MARK" 2>/dev/null
    log "[✓] 已还原 $n 个应用"
    return 0
}

# 列表没变就不重复执行（重复 pm hide 会报 already hidden，白刷日志）
hide_apps_sync() {
    hide_apps_enabled || return 0
    # 指纹要和 hide_apps_apply 写进标记文件首行的格式完全一致
    # （命令替换会吃掉结尾换行，直接用管道会多出一个逗号，导致每轮都重来）
    local fp; fp="#$(printf '%s' "$(hide_apps_list)" | tr '\n' ',')"
    local cur=""
    [ -f "$HIDE_APPS_MARK" ] && cur=$(head -n 1 "$HIDE_APPS_MARK" 2>/dev/null)
    [ "$fp" = "$cur" ] && return 0
    hide_apps_restore >/dev/null 2>&1
    hide_apps_apply
}

# ---- 2. 异常文件清理 ----
# 默认只清 MT 管理器留下的工作目录，可用 abnormal_paths 覆盖（空格分隔）。
# 安全限制：只允许 /sdcard/ 与 /storage/emulated/0/ 下的路径。
ABNORMAL_DEFAULT="/sdcard/MT2 /storage/emulated/0/MT2 /sdcard/MT"

clean_abnormal() {
    local list; list=$(cfg_get abnormal_paths "$ABNORMAL_DEFAULT")
    local n=0 p
    for p in $list; do
        [ -n "$p" ] || continue
        case "$p" in
            /sdcard/*|/storage/emulated/0/*) ;;
            *) log "[!] 跳过不在 /sdcard 下的路径：$p"; continue ;;
        esac
        [ -e "$p" ] || continue
        if rm -rf "$p" 2>/dev/null; then
            n=$((n + 1)); log "[✓] 已清理：$p"
        else
            log "[!] 清理失败：$p"
        fi
    done
    [ "$n" = "0" ] && log "[·] 没有需要清理的目录"
    echo "CLEAN_ABNORMAL=$n"
    return 0
}

# ---- 3. 应用列表（借用系统自己的 PackageManager）----
# 应用名只存在 APK 的 resources.arsc 里；pm / dumpsys 只给 labelRes=0x7f... 这种资源 id，
# 纯 shell 解不出来。而 Android 11+ 的包可见性限制（<queries> / QUERY_ALL_PACKAGES）
# 只约束普通应用，root 本来就无视它 —— 我们缺的从来不是"列表权限"，是"名字解析"。
# 所以直接让系统替我们解析：把 appinfo.dex 跑在 app_process 里（TEESimulator 同款做法）。
# v2.3.4 起 dex 不再依赖 ActivityThread.systemMain()（真机上它可能什么都不输出），
# 改成 ActivityThread.getPackageManager() 拿服务 + 自己给每个 APK 建 Resources 解析 labelRes。
APPINFO_CLASS="com.yypm.appinfo.AppInfo"
APPINFO_ICON_DIR="$MODDIR/webroot/icons"
# 暂存区路径允许被测试覆盖（同 APPINFO_BIN 的做法）
APPINFO_STAGE_DEX="${APPINFO_STAGE_DEX:-/data/adb/modules_update/yypm/appinfo.dex}"
APPINFO_SHA_FILE="$MODDIR/appinfo.sha256"
APPINFO_SHA=""
[ -f "$APPINFO_SHA_FILE" ] && APPINFO_SHA=$(tr -d ' \t\r\n' < "$APPINFO_SHA_FILE" 2>/dev/null | tr 'A-Z' 'a-z')

# 候选 dex 能不能用：存在 + 非空 +（有随包校验文件时）hash 对得上
appinfo_dex_ok() { # $1 路径
    [ -f "$1" ] && [ -s "$1" ] || return 1
    [ -n "$APPINFO_SHA" ] || return 0
    [ "$(sha256_of "$1")" = "$APPINFO_SHA" ]
}

# 挑一个"内容正确"的 appinfo.dex。
# 只看文件在不在是不够的：v2.3.2/v2.3.3 的旧 dex 会一直躺在生效目录里
# （自更新白名单漏了它，v2.3.6 才改成排除法），而旧 dex 是 systemMain() 版本，
# 跑起来会卡死到被 timeout 掐掉 —— 表现是 stdout / stderr 全空、退出码非 0，
# 特别容易被误判成"Android 16 不让跑 app_process"。所以这里按内容认，不按存在认。
appinfo_pick_dex() {
    local p
    for p in "$MODDIR/appinfo.dex" "$APPINFO_STAGE_DEX"; do
        appinfo_dex_ok "$p" && { printf '%s\n' "$p"; return 0; }
    done
    # 都不匹配（比如没带校验文件）：至少挑个非空的，别让功能彻底消失
    for p in "$MODDIR/appinfo.dex" "$APPINFO_STAGE_DEX"; do
        [ -f "$p" ] && [ -s "$p" ] && { printf '%s\n' "$p"; return 0; }
    done
    return 1
}

APPINFO_DEX=$(appinfo_pick_dex) || APPINFO_DEX="$MODDIR/appinfo.dex"

# 跑 appinfo.dex；成功时输出 pkg<TAB>label<TAB>tags
appinfo_run() {
    [ -f "$APPINFO_DEX" ] || return 1
    mkdir -p "$TMP" 2>/dev/null
    # 必须加超时：dex 里虽然有 System.exit，但万一某个 ROM 上还是卡住，
    # 没有超时就会把 WebUI 的 exec 一起拖死（v2.3.2 就是这么卡死的）。
    local TO=""
    if command -v timeout >/dev/null 2>&1; then TO="timeout 12"
    elif [ -x /system/bin/timeout ]; then TO="/system/bin/timeout 12"
    fi
    local bin out rc
    # APPINFO_BIN 只给测试用；留空则按 64/默认/32 位顺序找
    for bin in ${APPINFO_BIN:-} /system/bin/app_process64 /system/bin/app_process /system/bin/app_process32; do
        [ -x "$bin" ] || continue
        # 1) -Djava.class.path（TEESimulator 同款）
        out=$($TO "$bin" -Djava.class.path="$APPINFO_DEX" "$MODDIR" --nice-name=yypm-appinfo "$APPINFO_CLASS" --icons "$APPINFO_ICON_DIR" 2>"$TMP/appinfo.err")
        rc=$?
        # 认自家的结束标记，避免把 app_process 的告警当成结果
        case "$out" in *'#mode='*) printf '%s\n' "$out"; return 0 ;; esac
        # 124 = 被 timeout 掐掉的。同一套运行时再换 app_process32 也是白等，直接放弃
        if [ "$rc" = "124" ]; then
            log "[!] appinfo 超时被终止（$bin / -D 方式），不再尝试其它入口"
            return 1
        fi
        # 2) CLASSPATH 环境变量（系统自带的 am / pm 就是这么起的，多留一条路）
        out=$(CLASSPATH="$APPINFO_DEX" $TO "$bin" "$MODDIR" --nice-name=yypm-appinfo "$APPINFO_CLASS" --icons "$APPINFO_ICON_DIR" 2>"$TMP/appinfo.err")
        rc=$?
        case "$out" in *'#mode='*) printf '%s\n' "$out"; return 0 ;; esac
        if [ "$rc" = "124" ]; then
            log "[!] appinfo 超时被终止（$bin / CLASSPATH 方式），不再尝试其它入口"
            return 1
        fi
    done
    return 1
}

# 一次把诊断信息打全，省得反复猜
apps_diag() {
    echo "DIAG_SDK=$(getprop ro.build.version.sdk 2>/dev/null)"
    echo "DIAG_ABI=$(getprop ro.product.cpu.abi 2>/dev/null)"
    echo "DIAG_UID=$(id -u 2>/dev/null)"
    echo "DIAG_MODDIR=$MODDIR"
    # 两个候选都报出来。只报"最终用了哪个"是查不出问题的 ——
    # 上一轮就是只看到 size=4908（正常是 9480），却不知道另一个候选是什么样。
    local p h sz mark
    for p in "$MODDIR/appinfo.dex" "$APPINFO_STAGE_DEX"; do
        if [ -f "$p" ]; then
            h=$(sha256_of "$p"); sz=$(wc -c <"$p" 2>/dev/null | tr -d ' ')
            if [ -z "$APPINFO_SHA" ]; then mark="无校验文件"
            elif [ "$h" = "$APPINFO_SHA" ]; then mark="OK"
            else mark="过期!"
            fi
            echo "DIAG_DEX[$mark] $p size=$sz sha=$(printf '%s' "$h" | cut -c1-16)"
        else
            echo "DIAG_DEX[缺失] $p"
        fi
    done
    echo "DIAG_DEX_USED=$APPINFO_DEX"
    echo "DIAG_DEX_EXPECT=${APPINFO_SHA:-（包内没有 appinfo.sha256）}"
    local b
    for b in /system/bin/app_process64 /system/bin/app_process /system/bin/app_process32; do
        if [ -x "$b" ]; then echo "DIAG_BIN=$b ok"; else echo "DIAG_BIN=$b missing"; fi
    done
    if command -v timeout >/dev/null 2>&1; then echo "DIAG_TIMEOUT=$(command -v timeout)"
    elif [ -x /system/bin/timeout ]; then echo "DIAG_TIMEOUT=/system/bin/timeout"
    else echo "DIAG_TIMEOUT=none"; fi
    echo "DIAG_CLASS=$APPINFO_CLASS"
    echo "---DIAG-OUT-BEGIN---"
    appinfo_run || echo "(appinfo_run 返回非 0)"
    echo "---DIAG-OUT-END---"
    echo "---DIAG-ERR-BEGIN---"
    [ -f "$TMP/appinfo.err" ] && head -c 4000 "$TMP/appinfo.err" 2>/dev/null
    echo ""
    echo "---DIAG-ERR-END---"
}

# zip 条目列表（unzip -> busybox -> toybox，与 zip_prop 同一套兜底）
zip_list() { # $1 zip file
    local z="$1" out="" c
    [ -f "$z" ] || return 1
    if command -v unzip >/dev/null 2>&1; then
        out=$(unzip -l "$z" 2>/dev/null | grep -E 'META-INF/xposed/|assets/xposed_init' | head -1)
        [ -n "$out" ] && { printf '%s\n' "$out"; return 0; }
    fi
    for c in busybox toybox; do
        command -v "$c" >/dev/null 2>&1 || continue
        "$c" --list 2>/dev/null | grep -qx unzip || continue
        out=$("$c" unzip -l "$z" 2>/dev/null | grep -E 'META-INF/xposed/|assets/xposed_init' | head -1)
        [ -n "$out" ] && { printf '%s\n' "$out"; return 0; }
    done
    return 1
}

# LSPosed 模块的 APK 里有 META-INF/xposed/（新版）；旧式 Xposed 模块有 assets/xposed_init
apk_is_xposed() {
    zip_list "$1" >/dev/null 2>&1
}

# 兜底：拿不到 Context 时只剩包名。这里刻意**不扫 zip** —— 扫上百个 APK 要几十秒，
# 会把 WebUI 拖成"点了没反应"。LSPosed 标记改由 apps_xposed_scan 按需触发。
apps_list_fallback() {
    local pm; pm=$(pm_bin) || return 1
    local line pkg
    "$pm" list packages -3 2>/dev/null | while IFS= read -r line; do
        pkg=${line#package:}
        [ -n "$pkg" ] || continue
        printf '%s\t%s\t\n' "$pkg" "$pkg"
    done
}

# 按需扫第三方 APK 里的 LSPosed 标记（慢，只在 appinfo 不可用时才需要）
# APK 里有没有 LSPosed 标记（新式 META-INF/xposed/，旧式 assets/xposed_init）。
# 只读 zip 中央目录，不解压。
#
# 这里刻意不套子 shell、不接 head：每包的真实开销就是「一次解包工具 + 一次 grep」。
# 老实现走 zip_list 会多出子 shell 和 head，还要每包用 --list 加 grep -qx 探一遍 unzip，
# 应用一多就贴着 ksu.exec 的 20s 上限。逐个试工具的代价可以忽略 —— command -v 是
# shell 内建，不 fork。所以「先挑一个工具定死」是错的：unzip 存在但不好使时会断掉兜底链。
apk_has_xposed_mark() { # $1 apk
    local t
    for t in unzip "busybox unzip" "toybox unzip"; do
        case "$t" in
            unzip)    command -v unzip   >/dev/null 2>&1 || continue ;;
            busybox*) command -v busybox >/dev/null 2>&1 || continue ;;
            toybox*)  command -v toybox  >/dev/null 2>&1 || continue ;;
        esac
        if $t -l "$1" 2>/dev/null | grep -qE 'META-INF/xposed/|assets/xposed_init'; then
            return 0
        fi
    done
    return 1
}

apps_xposed_scan() {
    local pm; pm=$(pm_bin) || return 1
    local line apk pkg
    "$pm" list packages -f -3 2>/dev/null | while IFS= read -r line; do
        apk=${line#package:}; apk=${apk%=*}; pkg=${line##*=}
        [ -n "$pkg" ] || continue
        apk_has_xposed_mark "$apk" && printf '%s\n' "$pkg"
    done
}

# 失败时把 app_process 的第一条报错带进日志，省得还要单独去取 appinfo.err
appinfo_err_hint() {
    [ -s "$TMP/appinfo.err" ] || return 0
    local l
    l=$(grep -v '^#diag' "$TMP/appinfo.err" 2>/dev/null | grep -v '^[[:space:]]*$' | head -n 2 | tr '\n' ' ')
    [ -n "$l" ] && log "[!] appinfo 报错: $l"
    return 0
}

# 输出：APPS_SOURCE / APPS_COUNT + ---APPS-BEGIN--- 与 ---APPS-END--- 之间的 TSV
apps_list() {
    local out src="appinfo"
    if [ ! -f "$APPINFO_DEX" ]; then
        src="fallback"
        log "[!] appinfo.dex 不在模块目录（$APPINFO_DEX）—— 应用内更新后新文件先落在 modules_update，重启才生效"
    elif ! out=$(appinfo_run); then
        src="fallback"
        log "[!] appinfo 跑不起来（app_process 或 dex 有问题），退回包名列表"
        appinfo_err_hint
    fi
    if [ "$src" = "fallback" ]; then
        out=$(apps_list_fallback)
    else
        out=$(printf '%s\n' "$out" | grep -v '^#mode=')
    fi
    printf 'APPS_SOURCE=%s\n' "$src"
    printf 'APPS_COUNT=%s\n' "$(printf '%s\n' "$out" | grep -c .)"
    printf '%s\n' '---APPS-BEGIN---'
    printf '%s\n' "$out"
    printf '%s\n' '---APPS-END---'
    return 0
}

# ---- 4. TEESimulator / TrickyStore 的目标清单 ----
# TEESimulator-RS 没有 WebUI（包内搜不到 WebUI/webroot），"勾选"其实就是编辑这个文件：
# 一行一个包名。列进去的应用，密钥认证请求才走模拟；不在清单里的直通真实 TEE。
TT_FILE="/data/adb/tricky_store/target.txt"

target_txt_show() {
    if [ ! -f "$TT_FILE" ]; then
        echo "TT_EXISTS=0"
        echo "TT_COUNT=0"
        return 0
    fi
    echo "TT_EXISTS=1"
    echo "TT_COUNT=$(grep -cv '^[[:space:]]*$' "$TT_FILE" 2>/dev/null)"
    printf '%s\n' '---TT-BEGIN---'
    cat "$TT_FILE" 2>/dev/null
    printf '%s\n' '---TT-END---'
    return 0
}

# 只追加、不覆盖：已存在的行原样保留，改前备份
target_txt_add() { # stdin: 包名列表（逗号/空白分隔都行）
    local list; list=$(hide_apps_normalize)
    [ -n "$list" ] || { echo "TT_ADD=EMPTY"; return 1; }
    mkdir -p "$(dirname "$TT_FILE")" 2>/dev/null
    if [ -f "$TT_FILE" ]; then
        cp -f "$TT_FILE" "$TT_FILE.bak.$(date +%Y%m%d%H%M%S)" 2>/dev/null
    fi
    touch "$TT_FILE" 2>/dev/null
    local n=0 p
    for p in $list; do
        grep -qxF "$p" "$TT_FILE" 2>/dev/null && continue
        printf '%s\n' "$p" >> "$TT_FILE" && n=$((n + 1))
    done
    log "[✓] 目标清单追加 $n 个包（共 $(grep -cv '^[[:space:]]*$' "$TT_FILE" 2>/dev/null) 行）"
    echo "TT_ADD=$n"
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

    # 3.5) appinfo 排障：dex 在不在、app_process 能不能跑、报什么错
    #      （上一次的包里没有这一段，结果只能靠猜）
    {
        echo "=== 模块目录 ==="
        ls -l "$MODDIR" 2>/dev/null
        echo
        echo "=== 暂存区 ==="
        ls -l /data/adb/modules_update/yypm 2>/dev/null
        echo
        echo "=== appinfo 自检 ==="
        apps_diag 2>&1
    } > "$stage/appinfo.txt" 2>/dev/null

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

    # ---- 环境对抗：隐藏应用列表 / 深度伪装 / 异常文件 ----
    echo "HIDE_APPS_ENABLE=$(cfg_get hide_apps_enable off)"
    echo "HIDE_APPS_COUNT=$(hide_apps_list | wc -l | tr -d ' ')"
    echo "HIDE_APPS_APPLIED=$(hide_apps_applied)"
    echo "HIDE_APPS_LIST=$(cfg_get hide_apps '')"
    echo "DEEP_BL=$(cfg_get deep_bl off)"
    # TEESimulator / TrickyStore 的目标清单（只读统计，别在这里改文件）
    if [ -f "$TT_FILE" ]; then
        echo "TT_EXISTS=1"
        echo "TT_COUNT=$(grep -cv '^[[:space:]]*$' "$TT_FILE" 2>/dev/null)"
    else
        echo "TT_EXISTS=0"
        echo "TT_COUNT=0"
    fi
    local _mh; _mh=$(mount_hider_present) || _mh="none"
    echo "MOUNT_HIDER=$_mh"
    echo "ABNORMAL_PATHS=$(cfg_get abnormal_paths "$ABNORMAL_DEFAULT")"

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

# ============================================================
# 密钥自检
# ============================================================
# 为什么需要：注入成功 != 证书有效。keybox 里的证书一旦过期或被 Google 吊销，
# 注入照样成功、开机也正常，只有依赖硬件认证的 App（支付/银行）会静默失效，
# 在手机上极难排查。这里把「本地这份 keybox 到底还能不能用」一次摊开。
#
# 分工：shell 里没有 JSON 解析器，让它去抠嵌套字段既脆弱又易错，所以服务端
# 单独提供 ?action=keyboxreport 把要展示的部分原样吐出来，本函数只负责搬运，
# 真正的解析交给 WebUI 的 JS。
keybox_audit() {
    local kb="$KEYBOX_DEST"
    local exists=0 size="" sha="" devid="" certs="" keyalg=""

    if [ -f "$kb" ]; then
        exists=1
        size=$(wc -c < "$kb" 2>/dev/null | tr -d ' \t')
        sha=$(sha256_of "$kb")
        devid=$(sed -n 's/.*DeviceID="\([^"]*\)".*/\1/p' "$kb" 2>/dev/null | head -1)
        certs=$(grep -c 'BEGIN CERTIFICATE' "$kb" 2>/dev/null)
        keyalg=$(sed -n 's/.*BEGIN \([A-Z0-9 ]*PRIVATE KEY\).*/\1/p' "$kb" 2>/dev/null | head -1)
    fi

    echo "KEYBOX_PATH=$kb"
    echo "KEYBOX_EXISTS=$exists"
    echo "KEYBOX_LOCAL_SIZE=$size"
    echo "KEYBOX_LOCAL_SHA=$sha"
    echo "KEYBOX_LOCAL_DEVICEID=$devid"
    echo "KEYBOX_LOCAL_CERTS=$certs"
    echo "KEYBOX_LOCAL_KEYALG=$keyalg"

    mkdir -p "$TMP"
    rm -f "$TMP/kbreport.json"
    if download "$(api_url keyboxreport)" "$TMP/kbreport.json" && [ -s "$TMP/kbreport.json" ]; then
        # 只取服务端报告的 sha256 用于比对；其余原样交给 WebUI 解析
        echo "KEYBOX_SERVER_SHA=$(sed -n 's/.*"sha256"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$TMP/kbreport.json" | head -1)"
        echo "KEYBOX_JSON_BEGIN"
        cat "$TMP/kbreport.json"
        echo ""
        echo "KEYBOX_JSON_END"
    else
        echo "KEYBOX_SERVER_SHA="
        echo "KEYBOX_JSON_BEGIN"
        echo '{"ok":false,"error":"服务端自检报告下载失败（检查网络或 BASE_URL）"}'
        echo "KEYBOX_JSON_END"
    fi
}

# ---- 一键修复：把自检发现的问题就地解决 ----
#
# 能修的：本地 keybox 缺失 / 被第三方替换 / 与服务端不一致 / 服务端已经换源
#   而设备还没跟上。这几类的解法是同一个 —— 重新与服务端对齐：走一次带
#   Ed25519 验签的拉取，拉不到就回滚到本地池里上一份已验签的 keybox。
#   （这一步其实每轮定时任务本来就会做，这里只是「现在立刻做一次」。）
#
# 不能修的：证书签发时间过早。例如当前这份叶证书是 2020-09-29 签发、有效期
#   到 2030-09-27。真实的 TEE 认证证书是按需即时签发的，检测方一看签发时间
#   就知道是套用了别人的密钥 —— 这正是春秋检测报「脏设备存在替换密钥行为」
#   的最可能原因。叶证书由中间 CA 签发，而中间 CA 的私钥不在 keybox 里
#   （keybox 只带叶的私钥），所以没有私钥就无法重签。这不是配置问题，
#   换多少个源都一样，必须如实告诉用户，不能假装能修。
keybox_repair() {
    local before_sha=$(sha256_of "$KEYBOX_DEST")
    local before_size=$(wc -c < "$KEYBOX_DEST" 2>/dev/null | tr -d ' \t')
    echo "REPAIR_BEFORE_SHA=$before_sha"
    echo "REPAIR_BEFORE_SIZE=$before_size"

    # fetch_keybox_safe 内部已包含：拉 manifest -> 看服务端有效性结论 ->
    # 无效则回滚到池里上一份 -> 拉取失败也回滚。所以这里不需要额外兜底。
    local rc=0
    fetch_keybox_safe || rc=$?

    local after_sha=$(sha256_of "$KEYBOX_DEST")
    local after_size=$(wc -c < "$KEYBOX_DEST" 2>/dev/null | tr -d ' \t')
    echo "REPAIR_AFTER_SHA=$after_sha"
    echo "REPAIR_AFTER_SIZE=$after_size"
    if [ -n "$before_sha" ] && [ "$before_sha" = "$after_sha" ]; then
        echo "REPAIR_CHANGED=0"
    elif [ -z "$before_sha" ] && [ -z "$after_sha" ]; then
        echo "REPAIR_CHANGED=0"
    else
        echo "REPAIR_CHANGED=1"
    fi
    echo "REPAIR_RC=$rc"
}

# ============================================================
# 反挂检查（游戏挂）
# ============================================================
# 判定思路：游戏挂的特征不是名字，而是「它挂了哪个游戏」和「它带了什么注入工具」。
# 分四级信号，可靠性从高到低：
#
#   A 级  LSPosed 模块的 scope 命中【游戏应用】
#         —— 最强信号。scope 表直接记录了模块 hook 哪些应用，而 Android 自己
#            知道哪些包是游戏（CATEGORY_GAME），两边求交集即可，不需要维护
#            游戏包名表。需要读 modules_config.db（见 ac_lspd_scope）。
#   B 级  模块目录里躺着注入/内存工具的实体文件
#         —— 文件级证据，比名字可靠得多，且不需要任何额外依赖。
#   C 级  ID/名称/描述含游戏挂关键字
#         —— 误报率最高，【只警告，永不自动处理】。
#   D 级  已安装的作弊 APK
#         —— 不是模块，只警告。
#
# 安全底线：只有 A/B 级允许自动处理；C/D 永远只警告。白名单在最低层强制。
# 默认动作 quarantine（移到隔离区，可一键还原），想真删把 anti_cheat 设成 delete。
#
# config: anti_cheat     = off | warn（默认）| quarantine | delete
#         anti_cheat_ids = 逗号分隔的自定义模块 id（精确匹配，按 A 级处理）

# 路径变量化：生产环境用默认值，测试里可以覆盖成临时目录。
AC_MODDIR="${AC_MODDIR:-/data/adb/modules}"
AC_QDIR="${AC_QDIR:-/data/adb/yypm/quarantine}"
AC_LOCK="${AC_LOCK:-/data/adb/yypm/ac.lock}"
AC_PENDING="${AC_PENDING:-/data/adb/yypm/ac.pending}"

# B 级：注入 / 内存工具的实体文件名特征。格式 文件名片段|说明。
# 只收【在模块里出现就基本不可能是正经用途】的东西。
ac_payload_strong() {
    cat <<'ACEOF'
ceserver|Cheat Engine 服务端（内存扫描/修改）
cheatengine|Cheat Engine（内存扫描/修改）
frida-server|Frida 注入框架服务端
frida-gadget|Frida 注入框架
libgg.so|GameGuardian 核心库
libgameguardian|GameGuardian 核心库
libsubstrate|Substrate Hook 框架（游戏挂常用）
ACEOF
}

# C 级：只提示、不处理的线索。ImGui/IL2CPP/UE4 在别的场景也可能是正经用途，
# 所以单独放一档，避免误杀。
ac_payload_weak() {
    cat <<'ACEOF'
libimgui|ImGui 绘制层（游戏 overlay 常用）
libil2cpp|IL2CPP 注入（Unity 游戏挂常用）
libue4|UE4 注入（虚幻引擎游戏挂常用）
ACEOF
}

# C 级：模块 ID/名称/描述里的关键字。只警告。
ac_keywords() {
    cat <<'ACEOF'
修改器
外挂
作弊
透视
自瞄
锁头
秒杀
无敌
游戏辅助
游戏脚本
按键精灵
自动点击
gg修改
gameguardian
lucky patcher
烧饼
八门
葫芦侠
叉叉助手
ACEOF
}

# D 级：作弊 APK 包名。只收确认过的。
ac_cheat_pkgs() {
    cat <<'ACEOF'
catch_.me_.if_.you_.can_|GameGuardian（内存修改器）
com.gameguardian.android|GameGuardian（内存修改器）
com.chelpus.luckypatcher|Lucky Patcher（破解工具）
com.forpda.lp|Lucky Patcher（破解工具）
cc.madkite.freedom|Freedom（内购破解）
ACEOF
}

# ---- 白名单 ----
# 反挂逻辑最容易犯的错是把自己人干掉。yypm 是 keybox 分发模块，它天然要跟一堆
# 「伪装类」模块共存 —— tricky_store、playintegrityfix 这些名字里全是敏感词，
# 按关键字扫第一个就会命中。删掉它们等于拆掉整个 keybox 基础设施，用户直接变砖。
#
# 所以白名单分三层，任何一层命中都放行，且在最底层生效（delete 模式也拦得住）：
#   1) yypm 自己
#   2) yypm 自己分发/安装的模块（服务端 package.json 里那 4 个）
#   3) 任何 yypm 亲手装上去的模块（从下载缓存反推，以后加新包不用回来改这里）
#   4) 常见的内核级 / 伪装类模块名模式（兜底）
ac_is_allowed() { # $1 = 模块 id
    local id=$(printf '%s' "$1" | tr 'A-Z' 'a-z')

    # 1) yypm 自己
    [ "$id" = "yypm" ] && return 0

    # 2) yypm 分发的模块 + 内核级依赖
    case "$id" in
        tricky_store|tricky-store|teesimulator|teesimulator-rs) return 0 ;;
        playintegrityfix|playintegrity|pif|pif_json|pifjson) return 0 ;;
        zygisksu|zygisk_su|zygisk-next) return 0 ;;
        zygisk_lsposed|lsposed) return 0 ;;
    esac

    # 3) 兜底模式：内核 / 隐藏 / 完整性伪装类
    case "$id" in
        shamiko|susfs*|kernelsu*|kernel_su*|magisk|*lsposed*|*shamiko*|*susfs*|*integrity*) return 0 ;;
    esac

    # 4) yypm 亲手装过的（缓存包里的 module.prop 反推）
    local bid
    for bid in $(ac_installed_ids); do
        [ "$(printf '%s' "$bid" | tr 'A-Z' 'a-z')" = "$id" ] && return 0
    done
    return 1
}

# yypm 装过的模块 id：直接读下载缓存里的 module.prop，不维护第二份名单。
# 以后往服务端 package/ 加新模块，白名单自动跟上。
# 结果缓存在 AC_INSTALLED_CACHE 里。ac_scan 会对每个模块调一次 ac_is_allowed，
# 而它每次都要把 packages/ 下的缓存包全部解一遍 —— 10 个模块就是几十次 unzip 派生。
# 这是扫描超时的主要来源之一，所以进程内缓存住。
AC_INSTALLED_CACHE=""
ac_installed_ids() {
    if [ -n "$AC_INSTALLED_CACHE" ]; then
        printf '%s\n' "$AC_INSTALLED_CACHE"
        return 0
    fi
    local d="${DATA_DIR:-/data/adb/yypm}/packages" z id acc=""
    if [ -d "$d" ]; then
        for z in "$d"/*.zip; do
            [ -f "$z" ] || continue
            id=$(zip_id "$z" 2>/dev/null)
            [ -n "$id" ] && acc="${acc}${id}
"
        done
    fi
    AC_INSTALLED_CACHE="$acc"
    [ -n "$acc" ] && printf '%s\n' "$acc"
    return 0
}

# 通用：在【换行分隔的 片段|说明】表里找 $1 是否出现在 $2（已转小写的全文）里。# 通用：在【换行分隔的 片段|说明】表里找 $1 是否出现在 $2（已转小写的全文）里。
# 命中输出说明。$3=strong 时按 A 级处理，否则按 C 级。
ac_match_table() { # $1=haystack(小写) $2=表内容
    local hay="$1" entry frag why
    local oldifs="$IFS"
    IFS='
'
    for entry in $2; do
        [ -n "$entry" ] || continue
        frag="${entry%%|*}"; why="${entry#*|}"
        case "$hay" in *"$frag"*) IFS="$oldifs"; printf '%s\n' "$why"; return 0 ;; esac
    done
    IFS="$oldifs"
    return 1
}

ac_match_user() { # $1 = 模块 id
    local id="$1" extra=$(cfg_get anti_cheat_ids "")
    [ -n "$extra" ] || return 1
    case ",$(printf '%s' "$extra" | tr -d ' ')," in *",$id,"*) return 0 ;; esac
    return 1
}

# B 级扫描：看模块目录里有没有注入/内存工具的实体文件。
# 只扫两层、只比文件名，避免在几百个文件上把时间耗光。
# 让 find 自己按文件名筛，只把命中的几个名字带回 shell。
# 原来的写法是把整个文件清单（find | tr）拉进变量再逐条子串匹配 —— 模块的
# system/ 动辄上万个文件，这一步在真机上能把 WebUI 的 20 秒预算吃光，
# 用户看到的就是「点了扫描没反应 / 没有输出」。
ac_payload_hit() { # $1=模块目录 $2=特征表 -> 命中则输出说明
    local dir="$1" table="$2" entry frag why hits f pat=""
    [ -d "$dir" ] || return 1
    local oldifs="$IFS"
    IFS='
'
    for entry in $table; do
        [ -n "$entry" ] || continue
        frag="${entry%%|*}"
        pat="$pat -o -iname *$frag*"
    done
    IFS="$oldifs"
    [ -n "$pat" ] || return 1
    pat="${pat# -o }"
    # 关掉路径展开：否则 *ceserver* 这种会被当前目录里的同名文件顶掉
    local hadf=0; case "$- " in *f*) hadf=1 ;; esac
    set -f
    hits=$(find "$dir" -maxdepth 3 -type f \( $pat \) 2>/dev/null | head -3)
    [ "$hadf" = "0" ] && set +f
    [ -n "$hits" ] || return 1
    f=$(printf '%s\n' "$hits" | head -1 | tr 'A-Z' 'a-z')
    why=$(ac_match_table "$f" "$table") || return 1
    printf '%s\n' "$why"
}

ac_scan_payload() { ac_payload_hit "$1" "$(ac_payload_strong)"; }

ac_scan_payload_weak() { # $1=模块目录 -> 命中则输出说明
    local dir="$1" names=""
    [ -d "$dir" ] || return 1
    names=$(find "$dir" -maxdepth 3 -type f 2>/dev/null | tr 'A-Z' 'a-z')
    [ -n "$names" ] || return 1
    ac_match_table "$names" "$(ac_payload_weak)"
}

# 扫描已安装模块。只读。
ac_scan() {
    local dir="$AC_MODDIR" total=0 block=0 warn=0 out=""
    if [ -d "$dir" ]; then
        for m in "$dir"/*; do
            [ -d "$m" ] || continue
            local id=$(basename "$m")
            total=$((total + 1))
            ac_is_allowed "$id" && continue
            local name="" desc="" prop="$m/module.prop"
            if [ -f "$prop" ]; then
                name=$(sed -n 's/^name=//p' "$prop" 2>/dev/null | head -1)
                desc=$(sed -n 's/^description=//p' "$prop" 2>/dev/null | head -1)
            fi
            local hay=$(printf '%s %s %s' "$id" "$name" "$desc" | tr 'A-Z' 'a-z')
            local lvl="" why=""
            # 用户自定义名单 -> 直接按 A 级
            if ac_match_user "$id"; then
                lvl=block; why="在你的自定义名单里"
            # B 级：实体注入/内存工具文件（证据最硬）
            elif why=$(ac_scan_payload "$m"); then
                lvl=block; why="目录含 $why"
            # C 级：ImGui/IL2CPP 之类线索 + 关键字，只警告
            elif why=$(ac_scan_payload_weak "$m"); then
                lvl=warn; why="目录含 $why"
            elif why=$(ac_match_table "$hay" "$(ac_keywords)"); then
                lvl=warn; why="名称/描述含关键字「$why」"
            fi
            [ -n "$lvl" ] || continue
            if [ "$lvl" = "block" ]; then block=$((block + 1)); else warn=$((warn + 1)); fi
            out="${out}${id}	${lvl}	${name}	${why}
"
        done
    fi
    echo "AC_MODE=$(ac_mode)"
    echo "AC_LOCKED=$(ac_locked && echo 1 || echo 0)"
    echo "AC_PENDING=$(ac_pending && echo 1 || echo 0)"
    echo "AC_TOTAL=$total"
    echo "AC_BLOCK=$block"
    echo "AC_WARN=$warn"
    echo "AC-BEGIN"
    printf "$out"
    echo "AC-END"
}

# D 级：已装的作弊 APK。只警告。
ac_scan_pkgs() {
    local list="" p entry pkg why
    list=$(pm list packages 2>/dev/null | sed 's/^package://')
    [ -n "$list" ] || { echo "AC_PKG_HIT=0"; return 0; }
    local n=0
    local oldifs="$IFS"
    IFS='
'
    for entry in $(ac_cheat_pkgs); do
        [ -n "$entry" ] || continue
        pkg="${entry%%|*}"; why="${entry#*|}"
        case "$list" in
            *"$pkg"*) n=$((n + 1)); printf 'PKG\t%s\t%s\n' "$pkg" "$why" ;;
        esac
    done
    IFS="$oldifs"
    echo "AC_PKG_HIT=$n"
}

# ---- 自我锁定 ----
# 策略（按需求定）：
#   实锤（block 级）-> 强制删除该模块
#   警告（warn 级）-> 不删，改为【锁定 yypm 自身】：
#        禁用自身全部功能 + 界面全局变红 + 开机不加载 + 断网不加载。
# 为什么警告不直接删：关键字命中误报率高，删错了不可挽回；锁定是可逆的，
# 而且效果同样明确 —— 只要机器上有可疑游戏挂，yypm 就罢工。
ac_locked() { [ -f "$AC_LOCK" ]; }

ac_lock_reason() { sed -n 's/^reason=//p' "$AC_LOCK" 2>/dev/null | head -1; }

ac_lock_set() { # $1 = 原因
    mkdir -p "$(dirname "$AC_LOCK")" 2>/dev/null
    {
        echo "reason=$1"
        echo "since=$(date '+%Y-%m-%d %H:%M:%S')"
    } > "$AC_LOCK" 2>/dev/null
    log "[✗] 反挂：已锁定自身全部功能 —— $1"
}

ac_lock_clear() {
    [ -f "$AC_LOCK" ] || return 0
    rm -f "$AC_LOCK" 2>/dev/null
    log "[✓] 反挂：锁定已解除"
}

# 功能闸门：锁定后 yypm 不做任何事。
# 注意是 fail-closed：断网时同样保持锁定，否则拔网线就能绕过检查。
ac_guard() {
    ac_locked || return 0
    log "[✗] 反挂锁定中，拒绝执行（$(ac_lock_reason)）"
    return 1
}

# 只读地汇报锁定状态，供 WebUI 用
ac_lock_status() {
    if ac_locked; then
        echo "AC_LOCKED=1"
        echo "AC_LOCK_REASON=$(ac_lock_reason)"
        echo "AC_LOCK_SINCE=$(sed -n 's/^since=//p' "$AC_LOCK" 2>/dev/null | head -1)"
    else
        echo "AC_LOCKED=0"
        echo "AC_LOCK_REASON="
        echo "AC_LOCK_SINCE="
    fi
}

# ---- 实锤处置：先警告，强制二选一 ----
# 实锤（block 级）不自动删。理由：删模块是不可逆的，而「实锤」也可能误判；
# 更重要的是，用挂与否应该由用户自己承担后果，而不是模块替他决定。
# 所以命中实锤时只做两件事：锁定自己 + 挂起一个待决状态，等用户在 WebUI 里选：
#
#   继续使用本模块 -> 立刻删掉那些挂模块（yypm 留下）
#   仍然继续用挂   -> 删掉 yypm 下载过的所有模块，并卸载 yypm 自身
#
# 两个选择都会解除锁定。不选，yypm 就一直不工作。
ac_pending() { [ -f "$AC_PENDING" ]; }

ac_pending_ids() { sed -n 's/^block=//p' "$AC_PENDING" 2>/dev/null; }

ac_pending_set() { # $1 = 实锤模块 id（换行分隔）
    mkdir -p "$(dirname "$AC_PENDING")" 2>/dev/null
    {
        echo "since=$(date '+%Y-%m-%d %H:%M:%S')"
        printf '%s\n' "$1" | sed '/^$/d; s/^/block=/'
    } > "$AC_PENDING" 2>/dev/null
}

ac_pending_clear() { rm -f "$AC_PENDING" 2>/dev/null; }

# 用户选择「继续使用本模块」：删掉实锤挂模块，yypm 留下。
ac_decide_keep_module() {
    ac_pending || { echo "AC_DECIDE=none"; return 1; }
    local id n=0
    for id in $(ac_pending_ids); do
        ac_is_allowed "$id" && continue
        [ -d "$AC_MODDIR/$id" ] || continue
        # 按配置档位处置：quarantine 移进隔离区（可还原），其余一律删除
        local mode=$(ac_mode)
        if [ "$mode" = "quarantine" ]; then
            ac_quarantine "$id" >/dev/null 2>&1 && { n=$((n + 1)); log "[!] 反挂：按你的选择已隔离挂模块 $id"; }
        elif rm -rf "$AC_MODDIR/$id" 2>/dev/null; then
            n=$((n + 1))
            log "[!] 反挂：按你的选择已删除挂模块 $id"
        fi
    done
    ac_pending_clear
    ac_lock_clear
    echo "AC_DECIDE=keep_module"
    echo "AC_REMOVED=$n"
    return 0
}

# 用户选择「仍然继续用挂」：yypm 把下载过的模块全删掉，然后卸载自己。
# 这是用户明确选择的结果，不是模块自作主张 —— 所以不算「自毁功能」。
ac_decide_keep_cheats() {
    ac_pending || { echo "AC_DECIDE=none"; return 1; }
    local pkgs="${DATA_DIR:-/data/adb/yypm}/packages" np=0
    if [ -d "$pkgs" ]; then
        np=$(ls -1 "$pkgs" 2>/dev/null | wc -l | tr -d ' ')
        rm -rf "$pkgs" 2>/dev/null
    fi
    ac_pending_clear
    # 生效目录 + 待生效目录都要清。先放 remove 标记再删目录：
    # KernelSU / Magisk 见到 remove 会走正规卸载流程，比裸删干净。
    local d
    for d in "$AC_MODDIR/yypm" /data/adb/modules_update/yypm; do
        [ -e "$d" ] || continue
        mkdir -p "$d" 2>/dev/null
        : > "$d/remove" 2>/dev/null
        rm -rf "$d" 2>/dev/null
    done
    rm -f "$AC_LOCK" 2>/dev/null
    log "[!] 反挂：你选择了保留游戏挂，yypm 已删除 $np 个已下载模块并卸载自身"
    echo "AC_DECIDE=keep_cheats"
    echo "AC_REMOVED_PKGS=$np"
    echo "AC_SELFUNINSTALL=1"
    return 0
}

ac_decide() { # $1 = keep_module | keep_cheats
    case "$1" in
        keep_module) ac_decide_keep_module ;;
        keep_cheats) ac_decide_keep_cheats ;;
        *) echo "AC_DECIDE=bad"; return 1 ;;
    esac
}

# 把模块移到隔离区（可还原）。效果等同于删除：模块不再加载。
ac_quarantine() { # $1 = 模块 id
    local id="$1" src="$AC_MODDIR/$id"
    local dst="$AC_QDIR/$(date +%Y%m%d-%H%M%S)/$id"
    [ -d "$src" ] || return 1
    mkdir -p "$(dirname "$dst")" || return 1
    mv "$src" "$dst" 2>/dev/null || return 1
    log "[!] 反挂：已隔离模块 $id -> $dst"
    return 0
}

ac_restore() {
    local q="$AC_QDIR" n=0
    [ -d "$q" ] || { echo "AC_RESTORED=0"; return 0; }
    for d in "$q"/*/; do
        [ -d "$d" ] || continue
        for m in "$d"*/; do
            [ -d "$m" ] || continue
            local id=$(basename "$m")
            [ -e "$AC_MODDIR/$id" ] && continue
            if mv "$m" "$AC_MODDIR/$id" 2>/dev/null; then
                n=$((n + 1)); log "[✓] 反挂：已还原模块 $id"
            fi
        done
    done
    echo "AC_RESTORED=$n"
}

# 按策略执行：block 级强制删除（或隔离），warn 级锁定自身。
# 反挂的处理档位。没有「关闭」档 —— 这不是留给用户的选择权，是模块的立场：
# 游戏挂和本模块互相拖累，允许关掉等于允许用户把自己玩坏。
# 历史配置里如果还留着 off / warn，一律按默认档处理。
ac_mode() {
    local m=$(cfg_get anti_cheat delete)
    case "$m" in
        off|warn|"") echo delete ;;
        *) echo "$m" ;;
    esac
}

ac_apply() {
    local mode=$(ac_mode)
    echo "AC_MODE=$mode"
    local scan=$(ac_scan)
    local nb=$(printf '%s\n' "$scan" | sed -n 's/^AC_BLOCK=//p')
    local nw=$(printf '%s\n' "$scan" | sed -n 's/^AC_WARN=//p')
    echo "AC_BLOCK=$nb"
    echo "AC_WARN=$nw"
    local rows=$(printf '%s\n' "$scan" | sed -n '/^AC-BEGIN$/,/^AC-END$/p' | sed '1d;$d')
    local acted=0 id lvl nm why

    # 实锤 -> 只锁定 + 挂起待决，等用户在 WebUI 里做选择。不自动删。
    if [ "$nb" != "0" ]; then
        ac_pending_set "$(printf '%s\n' "$rows" | awk -F'\t' '$2=="block"{print $1}')"
        ac_lock_set "发现 $nb 个游戏挂模块，需要你做出选择"
        printf '%s\n' "$rows" | while IFS="\t" read -r id lvl nm why; do
            [ "$lvl" = "block" ] && log "[!] 反挂实锤：$id（$nm）— $why"
        done
    fi

    # 警告 -> 锁定自身（不删，因为误报率高，删错不可挽回）
    if [ "$nw" != "0" ] && [ "$nb" = "0" ]; then
        ac_lock_set "发现 $nw 个可疑游戏挂模块（关键字命中），已停用 yypm 全部功能"
        printf '%s\n' "$rows" | while IFS="	" read -r id lvl nm why; do
            [ "$lvl" = "warn" ] && log "[!] 反挂可疑：$id（$nm）— $why"
        done
    elif [ "$nb" = "0" ]; then
        ac_lock_clear
    fi
    echo "AC_ACTED=$acted"
    echo "AC_PENDING=$(ac_pending && echo 1 || echo 0)"
    echo "AC_LOCKED=$(ac_locked && echo 1 || echo 0)"
    return 0
}

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

# ---- debug 日志（config.prop 里 debug=on 才落盘；默认关，日志不膨胀）----
# 覆盖关键决策点：跳过原因 / 供源选择 / 验签结果 / 自动安装判定 ——
# 排障时打开它就能看到「为什么没做某件事」，不用猜。同进程内读一次配置后缓存。
DEBUG_ON=""
dbg() {
    if [ -z "$DEBUG_ON" ]; then
        [ "$(cfg_get debug off)" = "on" ] && DEBUG_ON=1 || { DEBUG_ON=0; return 0; }
    fi
    [ "$DEBUG_ON" = "1" ] || return 0
    echo "[$(date '+%m-%d %H:%M:%S')] [dbg] $*" >> "$LOG"
}

# ---- URL 拼接（保证 BASE_URL 以 / 结尾，避免每次请求都被 301 补斜杠）----
# 拼接前去掉可能存在的结尾斜杠，避免出现 "module//?action=" 这种双斜杠，
# 双斜杠同样会触发重定向。历史上 BASE_URL 没有尾斜杠，这里兜底。
api_url() { # $1 = action 名
    local b="${BASE_URL%/}"
    # 万一有人把 query 写进了 BASE_URL，先切掉
    b="${b%%\?*}"
    echo "$b/?action=$1"
}

# ---- 去中心化镜像（P3）----
# 清单 / keybox / 组件包全都带 Ed25519 签名，从任何镜像拿到的内容都可信 ——
# 这就是敢用免费公共 CDN 的底气。镜像由 GitHub Actions 定时从主源拉取、
# 验签后发布（.github/workflows/mirror.yml）：主源被攻击 / 宕机 / 被封时，
# 客户端自动切镜像继续工作，自建服务器只剩 acreport 一个轻量职责。
# 取用顺序（v2.8.3）：主源在前（清单必须新鲜；jsDelivr 分支解析缓存可达 12h 且
# 实测钉在旧提交、purge 刷不掉 —— v2.8.2「更新了却毫无作用」的实锤根因）->
# 镜像按测速顺序兜底（主源被攻击/宕机/被封时接管）-> GitHub API 最后。
# 重载荷（模块 zip/组件包）直走 GitHub release/raw，镜像只兜小体量签名 JSON。
# mirror_urls=off 整体关闭；mirror_url_list="..." 自定义镜像列表（不测速照单全收）。
#
# 镜像节点测速（v2.8.3）：不再写死 cdn.jsdelivr.net 一个边缘。jsDelivr 的公共边缘
# （gcore / cdn / fastly / testingcf）+ raw 全部列为候选，拉取前对每个节点实测一次
# manifest 往返延迟，按延迟排序取用 —— 最快的节点因设备网络而异，写死任何一个都是
# 把慢路强加给一部分设备；gcore 排候选首位（国内可达性通常最好，慢/不可达会被测速淘汰）。
# mirror_speed_test=off 关测速（退回静态顺序）；mirror_nodes 自定义候选节点；
# mirror_test_ttl 测速缓存秒数（默认 86400：一天只测一次，不是每次拉取都测）。
MIRROR_NODES_DEFAULT="gcore.jsdelivr.net cdn.jsdelivr.net fastly.jsdelivr.net testingcf.jsdelivr.net raw.githubusercontent.com"
# 测速关闭/测速失败时的静态兜底顺序（gcore 在前）
MIRROR_URLS_DEFAULT="https://gcore.jsdelivr.net/gh/yourname/yypm@mirror-data/mirror https://cdn.jsdelivr.net/gh/yourname/yypm@mirror-data/mirror https://raw.githubusercontent.com/yourname/yypm/mirror-data/mirror"

mirror_speed_test_enabled() { [ "$(cfg_get mirror_speed_test on)" != "off" ]; }

# 静态默认顺序逐行输出（MIRROR_URLS_DEFAULT 是空格分隔的，别用 printf 一行全打）
mirror_default_urls() {
    local m
    for m in $MIRROR_URLS_DEFAULT; do printf '%s\n' "$m"; done
}

# 节点 -> 镜像 base：jsDelivr 系边缘共用 /gh/<repo>@<branch>/ 路径；raw 是独立源
mirror_node_base() { # $1 = 节点域名
    case "$1" in
        raw.githubusercontent.com) echo "https://raw.githubusercontent.com/$GITHUB_REPO/mirror-data/mirror" ;;
        *)                          echo "https://$1/gh/$GITHUB_REPO@mirror-data/mirror" ;;
    esac
}

# 下载前测速（stdout：按延迟排序的 base，每行一个；不可达的按候选顺序垫底）。
# 复用 probe_source（curl -> busybox wget -> toybox wget，含毫秒计时）：
# 量的是「这台设备真实拉一次 manifest」的往返，不是纸面距离。
mirror_speed_test() {
    local node base out code ms ok_lines="" bad=""
    local f; f=$(mirror_file_of manifest 2>/dev/null)
    if [ -z "$f" ]; then mirror_default_urls; return 1; fi
    for node in $(cfg_get mirror_nodes "$MIRROR_NODES_DEFAULT"); do
        [ -n "$node" ] || continue
        base=$(mirror_node_base "$node")
        out=$(probe_source "node" "$base/$f")
        code=$(printf '%s' "$out" | cut -d'|' -f2)
        ms=$(printf '%s' "$out" | cut -d'|' -f3)
        case "$code" in 200|204|304|301|302|307|308) ;; *) bad="$bad $base"; dbg "测速: $node 不可达($code)，垫底保留"; continue ;; esac
        case "$ms" in ''|*[!0-9]*) ms=999999 ;; esac   # 可达但量不出延迟：排可达者末尾
        ok_lines="$ok_lines$ms|$base
"
        dbg "测速: $node ${ms}ms"
    done
    [ -n "$ok_lines" ] || { mirror_default_urls; return 1; }
    printf '%s' "$ok_lines" | sort -n | cut -d'|' -f2
    for base in $bad; do printf '%s\n' "$base"; done
    return 0
}

# 测速排序结果缓存（默认 24h）：一天只测一次，拉取不重复等测速
mirror_order_cached() {
    local cache="$DATA_DIR/mirror_order.cache" stamp="$DATA_DIR/mirror_order.stamp"
    if ! mirror_speed_test_enabled; then
        mirror_default_urls                            # 关测速：静态顺序（gcore 优先）
        return 0
    fi
    if [ -s "$cache" ] && [ -s "$stamp" ]; then
        local st now ttl
        st=$(cat "$stamp" 2>/dev/null); now=$(date +%s)
        ttl=$(cfg_get mirror_test_ttl 86400)
        case "$st" in ''|*[!0-9]*) ;; *) [ $((now - st)) -lt "$ttl" ] 2>/dev/null && { cat "$cache"; return 0; } ;; esac
    fi
    local ordered; ordered=$(mirror_speed_test)
    mkdir -p "$DATA_DIR" 2>/dev/null
    printf '%s\n' "$ordered" > "$cache" 2>/dev/null
    date +%s > "$stamp" 2>/dev/null
    printf '%s\n' "$ordered"
}

mirror_urls() { # stdout：每行一个镜像 base（无尾斜杠）；测速排序后的真实取用顺序
    [ "$(cfg_get mirror_urls on)" = "off" ] && return 0
    local m custom
    custom=$(cfg_get mirror_url_list "")
    if [ -n "$custom" ]; then          # 用户自定义列表：不测速，照单全收
        for m in $custom; do [ -n "$m" ] && printf '%s\n' "${m%/}"; done
        return 0
    fi
    mirror_order_cached
}

# action -> 镜像上的静态文件名（镜像是纯静态托管，没有 PHP 路由）
mirror_file_of() { # $1=action
    case "$1" in
        manifest)   echo "manifest.json" ;;
        keybox)     echo "keybox.xml" ;;
        revocation) echo "revocation.json" ;;
        packages)   echo "packages.json" ;;
        *)          return 1 ;;
    esac
}

# 依次尝试 镜像 -> 主源 下载某个 action。$1=action  $2=dest
# stdout = 实际供源的 base；全部失败返回 1。内容可信度由调用方验签保证。
api_fetch_any() {
    # 顺序（v2.8.3 改）：主源在前 —— 清单/组件表这类小体量签名 JSON 必须新鲜。
    # jsDelivr 对分支的解析缓存可达 12 小时、且会钉在旧提交上（实测：purge 只刷
    # 文件层缓存，@mirror-data 仍解析到上一个 commit，v2.8.2「更新了却毫无作用」
    # 的实锤根因）。重载荷（模块 zip / 组件包）本来就直走 GitHub release / raw，
    # 不占镜像带宽；主源每轮只承担 ~20KB 的 JSON，挂前面换新鲜性稳赚。
    # 主源被攻击/宕机/被封时，镜像按测速顺序接管兜底。
    if download "$(api_url "$1")" "$2" >/dev/null 2>&1 && [ -s "$2" ]; then
        dbg "api_fetch_any $1 <- 主源"
        printf '%s\n' "${BASE_URL%/}"; return 0
    fi
    dbg "api_fetch_any $1: 主源不通，转镜像"
    local m f=""
    f=$(mirror_file_of "$1" 2>/dev/null)
    if [ -n "$f" ]; then
        for m in $(mirror_urls); do
            if download "$m/$f" "$2" >/dev/null 2>&1 && [ -s "$2" ]; then
                dbg "api_fetch_any $1 <- 镜像 $m"
                printf '%s\n' "$m"; return 0
            fi
            dbg "api_fetch_any $1: 镜像 $m 不通"
        done
    fi
    dbg "api_fetch_any $1: 全部来源失败"
    return 1
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

# 应用是否真的装在系统里：pm path -> pm list packages -> cmd package path 三级判定。
# 只用 pm path 会在个别 ROM/时机上假阴性（binder 抖动 / 子命令不可用），
# 假阴性直接把 APK 条目判成「未安装」→ 界面永远显示「还有一项要更新」、
# 自动安装每轮重装。收敛到这一个函数，检查与自动安装共用同一条判定。
apk_installed() { # $1 = 应用包名
    local p="$1" pm
    [ -n "$p" ] || return 1
    pm=$(pm_bin 2>/dev/null) || { dbg "apk_installed: 无 pm，视为未装"; return 1; }
    if "$pm" path "$p" >/dev/null 2>&1; then dbg "apk_installed: $p 由 pm path 判定已装"; return 0; fi
    if "$pm" list packages 2>/dev/null | grep -xq -e "$p" -e "package:$p"; then dbg "apk_installed: $p 由 pm list packages 判定已装"; return 0; fi
    if command -v cmd >/dev/null 2>&1 && cmd package path "$p" >/dev/null 2>&1; then dbg "apk_installed: $p 由 cmd package path 判定已装"; return 0; fi
    dbg "apk_installed: $p 三级判定均为未装"
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

# ---- 1.5 风险应用自动隐藏（春秋检测「风险应用」整改）----
# 春秋 Native check 会查 Scene / NP管理器 / Shizuku 等工具的安装状态，
# 也会查 GG/幸运破解器这类作弊器（与反挂 D 级同一份名单）。
# 检测到已安装就自动并入上面的隐藏列表（pm hide，对所有应用的包可见性
# 查询生效），WebUI 隐藏应用卡片可见、可一键还原。
# 注意：hide 后这些应用自己也打不开（launcher 同样看不到），要用先还原。
# 关闭：risk_autohide=off；自定义名单：risk_apps="包名1 包名2"。
RISK_APPS_DEFAULT="com.omarea.vtools com.wn.app.np moe.shizuku.privileged.api"

risk_apps_autohide() {
    if [ "$(cfg_get risk_autohide on)" = "off" ]; then
        dbg "risk_autohide: off，跳过"
        return 0
    fi
    local pm; pm=$(pm_bin) || return 0
    # 名单 = 春秋点名三包 + 反挂 D 级作弊 APK（只取包名段）
    local known="$(cfg_get risk_apps "$RISK_APPS_DEFAULT") $(ac_cheat_pkgs 2>/dev/null | cut -d'|' -f1 | tr '\n' ' ')"
    local cur added="" changed=0 p
    cur=" $(hide_apps_list | tr '\n' ' ') "
    for p in $known; do
        "$pm" path "$p" >/dev/null 2>&1 || continue       # 没装
        case "$cur" in *" $p "*) continue ;; esac         # 已在隐藏列表
        cur="${cur}${p} "
        added="$added $p"
        changed=1
    done
    [ "$changed" = "1" ] || return 0
    cfg_set hide_apps "$(printf '%s' "$cur" | tr -s ' ')"
    [ "$(cfg_get hide_apps_enable off)" = "on" ] || cfg_set hide_apps_enable on
    log "[!] 检测到风险应用（$(echo $added)）→ 已自动并入隐藏应用列表并生效（WebUI 可一键还原）"
    hide_apps_sync
    return 0
}

# ---- 1.7 HMA-OSS 自动配置（v2.8.4：装完即用，不用打开管理 App 手配）----
# 背景：HMA-OSS 的 zygisk 服务开机时读 /data/misc/hide_my_applist_<随机>/config.json
# （HMAService.loadConfig；管理 App 只是编辑器）。装完没人打开管理 App 的话，配置
# 永远是空的 —— 检测对抗等于没开。这里自动写一份够用的默认配置：对检测类应用
# （默认春秋，hma_scope 可扩）隐藏风险应用（MT/Scene/NP/Shizuku/各管理器 +
# 反挂 D 级作弊包 + 用户隐藏列表里的应用）。
# 归属规则：配置里有我们的模板名（yypm-auto）才算我们写的；用户自己配过
# （文件非空且无标记）绝不覆盖；用户删掉我们的模板后视为用户接管，不再重写。
# configVersion 必须与服务端构建一致（oss-173 = 93），不符会被整份拒收。
HMA_MOD_ID="hma_oss_zygisk"           # HMA-OSS 的模块 id（其 module.prop）
HMA_TPL_NAME="yypm-auto"              # 我们的模板名 = 配置归属标记
HMA_SCOPE_DEFAULT="com.chunqiuna"    # 默认拦截其包列表查询的检测应用（春秋）
HMA_CONFIG_VERSION=93                   # oss-173 的 JsonConfig.configVersion
HMA_MODULES_DIR="/data/adb/modules"           # 以下三项允许测试覆盖
HMA_STAGED_DIR="/data/adb/modules_update"
HMA_MISC_DIR="/data/misc"

# HMA-OSS 数据目录（服务首次启动时自建）；没有 = 服务还没跑起来
hma_data_dir() {
    local d
    for d in "$HMA_MISC_DIR"/hide_my_applist_*; do
        [ -d "$d" ] && { echo "$d"; return 0; }
    done
    return 1
}

# 默认要隐藏的应用：内置风险应用 + 各管理器 + 反挂 D 级作弊包 + 用户隐藏列表
hma_hidden_apps() {
    {
        echo bin.mt.plus                 # MT 管理器（春秋「风险应用」点名）
        echo com.omarea.vtools           # Scene
        echo com.wn.app.np               # NP 管理器
        echo moe.shizuku.privileged.api  # Shizuku
        echo org.frknkrc44.hma_oss       # HMA-OSS 管理器（藏好藏人的工具本身）
        echo me.weishu.kernelsu          # KernelSU 管理器
        echo org.lsposed.manager         # LSPosed 管理器（没装列着也无害）
        echo io.github.a13e300.fusefixer
        ac_cheat_pkgs 2>/dev/null | cut -d'|' -f1 | tr '\n' ' '
        hide_apps_list 2>/dev/null | tr '\n' ' '
    } | tr ' ' '\n' | grep -E '^[A-Za-z0-9_.]+$' | sort -u
}

# 生成整份配置 JSON（黑名单模板 + 每个 scope 条目挂模板）
hma_build_config() {
    local apps_json="" p first=1
    for p in $(hma_hidden_apps); do
        [ "$first" = "1" ] || apps_json="$apps_json,"
        apps_json="$apps_json\"$p\""
        first=0
    done
    local scope_json="" s sfirst=1
    for s in $(cfg_get hma_scope "$HMA_SCOPE_DEFAULT"); do
        [ -n "$s" ] || continue
        [ "$sfirst" = "1" ] || scope_json="$scope_json,"
        scope_json="$scope_json\"$s\":{\"useWhitelist\":false,\"excludeSystemApps\":true,\"applyTemplates\":[\"$HMA_TPL_NAME\"]}"
        sfirst=0
    done
    printf '{"configVersion":%s,"templates":{"%s":{"isWhitelist":false,"appList":[%s]}},"scope":{%s}}\n' \
        "$HMA_CONFIG_VERSION" "$HMA_TPL_NAME" "$apps_json" "$scope_json"
}

hma_oss_autocfg() {
    [ "$(cfg_get hma_auto on)" = "off" ] && { dbg "HMA-OSS: hma_auto=off，跳过"; return 0; }
    # 装了（生效区或待生效区）才有配置的意义
    [ -d "$HMA_MODULES_DIR/$HMA_MOD_ID" ] || [ -d "$HMA_STAGED_DIR/$HMA_MOD_ID" ] \
        || { dbg "HMA-OSS: 未安装，跳过"; return 0; }
    local d
    if ! d=$(hma_data_dir); then
        # 服务还没建目录（刚装完没重启/没生效）：预建 + 先写好配置。
        # 服务 searchDataDir 会认领已存在的 hide_my_applist_* 目录，首启即加载 —— 不多等一轮重启。
        # 属主给 system(1000)：服务跑在 system_server 里，要往目录写 status/log。
        d="$HMA_MISC_DIR/hide_my_applist_yypm"
        mkdir -p "$d" 2>/dev/null || { dbg "HMA-OSS: 预建目录失败"; return 0; }
        chown 1000:1000 "$d" 2>/dev/null
        chmod 755 "$d" 2>/dev/null
    fi
    local cfg="$d/config.json"
    if [ -s "$cfg" ] && ! grep -q "\"$HMA_TPL_NAME\"" "$cfg" 2>/dev/null; then
        dbg "HMA-OSS: 用户已自行配置，不覆盖"
        return 0
    fi
    local want; want=$(hma_build_config)
    [ -s "$cfg" ] && [ "$(cat "$cfg" 2>/dev/null)" = "$(printf '%s' "$want")" ] \
        && { dbg "HMA-OSS: 配置已是最新"; return 0; }
    printf '%s' "$want" > "$cfg" 2>/dev/null || return 0
    chmod 644 "$cfg" 2>/dev/null
    log "[✓] HMA-OSS 已自动配置：对春秋等检测应用隐藏 $(hma_hidden_apps | grep -c . | tr -d ' ') 个风险应用（管理 App 里可查看修改，重启后生效）"
    return 0
}

# ---- 1.8 旧组件自动清退：hma-uidfake（v2.8.4）----
# 它盯的是 LSPosed 版 HMA 的私有配置（com.tsng.hidemyapplist/files/config.json），
# 我们从没分发过 LSPosed 版 HMA —— 装上也永远 waiting for config；对抗面已被
# HMA-OSS 完整替代。自动打 remove 标记交给 KernelSU 按标准流程清理（不硬删目录），
# 生效区与待生效区都标；已标记过的不再重复（避免每轮刷日志）。
cleanup_replaced_mods() {
    local id d n=0
    for id in hma-uidfake; do
        for d in "$HMA_MODULES_DIR/$id" "$HMA_STAGED_DIR/$id"; do
            [ -d "$d" ] || continue
            [ -f "$d/remove" ] && continue
            touch "$d/remove" 2>/dev/null || continue
            n=$((n + 1))
            log "[✓] 已标记移除被 HMA-OSS 取代的旧组件 $id（重启后清理）"
        done
    done
    [ "$n" -gt 0 ] && echo "REPLACED_CLEAN=$n"
    return 0
}

# ---- 2. 异常文件清理 ----
# 默认只清 MT 管理器留下的工作目录，可用 abnormal_paths 覆盖（空格分隔）。
# MT 的落地点有两代：老版本用 /sdcard/MT2，新版本退回 /sdcard/MT；
# 应用私有目录（Android/data|media/bin.mt.plus）卸载后也会残留，春秋同样算「异常文件」。
# 安全限制：只允许 /sdcard/ 与 /storage/emulated/0/ 下的路径。
ABNORMAL_DEFAULT="/sdcard/MT2 /storage/emulated/0/MT2 /sdcard/MT /storage/emulated/0/MT /sdcard/Android/data/bin.mt.plus /sdcard/Android/media/bin.mt.plus"

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

# ---- 2.5 可疑进程诊断（春秋检测「异常进程」排查，只读）----
# 只列出来、不处理：杀进程会牵一发而动全身（ksud/su 是 root 基础设施本身），
# 这里只负责把「检测方可能看到了什么」摆给用户看。
# 输出契约（WebUI 靠它解析，别改格式）：
#   PROC_COUNT=<命中数>
#   ---PROC-BEGIN---
#   <pid> <name>     （每行一个）
#   ---PROC-END---
suspicious_procs() {
    # 可疑名（大小写不敏感）：ksud/magisk/su 是 root 与框架进程；
    # ceserver/frida/gameguardian 是注入与内存修改工具；gg- 是 GG 的守护进程前缀；
    # bin.mt.plus 是 MT 管理器常驻；scene 是调优工具（春秋把这类常驻都算「异常进程」）。
    local pat='ksud|magisk|^su$|ceserver|cheatengine|frida|gameguardian|gg-|bin\.mt\.plus|scene'
    local raw pairs names hitnames n=0 lines=""
    # 优先 -o PID,NAME 拿干净的两列；老 busybox 不认 -o 时退到默认输出。
    # 注意必须先快照、后匹配：若写成 ps | grep 一条管道，grep 自己的进程
    # 会和 ps 同时启动，它的命令行里带着 magisk|scene 这些特征串，
    # 必然命中自己 —— 于是 PROC_COUNT 永远至少多算 1 个，查不干净。
    raw=$(ps -A -o PID,NAME 2>/dev/null || ps -A 2>/dev/null || ps 2>/dev/null)
    # 归一化成「name pid」：常见输出里 pid 都是第一个纯数字列，名字在最后一列
    # （表头 PID/USER 行不是纯数字开头，awk 自动滤掉）。
    pairs=$(printf '%s\n' "$raw" | awk '$1 ~ /^[0-9]+$/ {print $NF, $1}')
    [ -n "$pairs" ] || { echo "PROC_COUNT=0"; echo "---PROC-BEGIN---"; echo "---PROC-END---"; return 0; }
    names=$(printf '%s\n' "$pairs" | awk '{print $1}')
    # 在纯名字流上匹配，^su$ 这类锚点才锚得住名字本身；
    # grep -v grep 是双保险（快照里本不该有 grep，防以后有人改回单管道写法）。
    hitnames=$(printf '%s\n' "$names" | grep -Ei "$pat" | grep -v grep | sort -u)
    if [ -n "$hitnames" ]; then
        # 按命中名单回查 pairs，把 pid 带回来（同一个名字可能对应多个 pid）
        lines=$(printf '%s\n' "$pairs" | awk -v h="$hitnames" '
            BEGIN { m=split(h, a, "\n"); for (i=1; i<=m; i++) ok[a[i]]=1 }
            ($1 in ok) { print $2, $1 }')
        n=$(printf '%s\n' "$lines" | grep -c .)
    fi
    echo "PROC_COUNT=$n"
    echo "---PROC-BEGIN---"
    [ -n "$lines" ] && printf '%s\n' "$lines"
    echo "---PROC-END---"
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
        # 1) -Djava.class.path（TEESimulator 同款）；"$@" 透传命令模式（如 lspd-enable）
        out=$($TO "$bin" -Djava.class.path="$APPINFO_DEX" "$MODDIR" --nice-name=yypm-appinfo "$APPINFO_CLASS" --icons "$APPINFO_ICON_DIR" "$@" 2>"$TMP/appinfo.err")
        rc=$?
        # 认自家的结束标记，避免把 app_process 的告警当成结果
        case "$out" in *'#mode='*) printf '%s\n' "$out"; return 0 ;; esac
        # 124 = 被 timeout 掐掉的。同一套运行时再换 app_process32 也是白等，直接放弃
        if [ "$rc" = "124" ]; then
            log "[!] appinfo 超时被终止（$bin / -D 方式），不再尝试其它入口"
            return 1
        fi
        # 2) CLASSPATH 环境变量（系统自带的 am / pm 就是这么起的，多留一条路）
        out=$(CLASSPATH="$APPINFO_DEX" $TO "$bin" "$MODDIR" --nice-name=yypm-appinfo "$APPINFO_CLASS" --icons "$APPINFO_ICON_DIR" "$@" 2>"$TMP/appinfo.err")
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

# ---- 4.5 自动把检测类应用并入 TrickyStore 目标清单（春秋检测项 26 整改）----
# 为什么需要：春秋这类检测应用自己会发起密钥认证（key attestation）来验设备完整性。
# 它不在 target.txt 里时，认证请求直通真实 TEE，真 TEE 一答就露馅（报 26）。
# 所以光注入 keybox 不够 —— 必须把「检测方自己」也加进目标清单，让它的认证走模拟。
# 名单内置、只增不删；config.prop 里 auto_target=off 可整体关闭。
AUTO_TARGET_APPS="com.chunqiuna"

auto_target_known_apps() {
    if [ "$(cfg_get auto_target on)" = "off" ]; then
        dbg "auto_target: off，跳过"
        return 0
    fi
    # 没有 TrickyStore 时 target.txt 无处可写，建空目录本身还会被当成「异常文件」
    [ -d "$TRICKY_DIR" ] || { dbg "auto_target: 无 TrickyStore，跳过"; return 0; }
    local pm; pm=$(pm_bin) || { dbg "auto_target: 无 pm，跳过"; return 0; }
    local p
    for p in $AUTO_TARGET_APPS; do
        # pm path 成功才算真的装了（包名出现在名单里 ≠ 设备上装着）
        "$pm" path "$p" >/dev/null 2>&1 || continue
        # 已在清单里的不重复追加（target_txt_add 自身也查重，这里先挡一层）
        grep -qxF "$p" "$TT_FILE" 2>/dev/null && continue
        if printf '%s\n' "$p" | target_txt_add >/dev/null 2>&1; then
            log "[✓] 已把检测应用加入密钥认证目标清单：$p（春秋等检测项 26 需要）"
        fi
    done
    return 0
}

# ---- 获取并挂载 keybox（manifest -> 判断有无变化 -> 校验 -> 验签 -> 写 tricky_store）----
# 省流量：manifest 里已带 keybox 的 sha256，先比 sha256；本地缓存已是同一份就
# 跳过下载（12.6KB -> 0），签名仍会重验一遍（成本低且更安全）。
fetch_keybox() {
    mkdir -p "$TMP"
    log "[·] 拉取 manifest"
    local served_by=""
    if ! served_by=$(api_fetch_any manifest "$TMP/manifest.json"); then
        log "[✗] manifest 下载失败（镜像与主源都不通）"
        retry_note_fail
        return 1
    fi
    [ -n "$served_by" ] && log "[·] manifest 来自: $served_by"

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
        dbg "fetch_keybox: fresh=1 sha=$KB_SHA"
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

    # 验签对象：fresh 分支没下载新文件，必须验【当前挂载的 DEST】本身 ——
    # 验 TMP 里的上轮残留会发现不了本地被替换，rollback 后还会把旧文件盖回去。
    local src="$TMP/keybox.verify"
    [ "$fresh" = "1" ] && src="$KEYBOX_DEST"
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

    # fresh 时 DEST 已是服务端最新且刚验过签：不重拷、不再入池
    if [ "$fresh" = "0" ]; then
        # 挂载到 TEESimulator（写 tricky_store/keybox.xml）+ 本地缓存
        mkdir -p "$TRICKY_DIR"
        cp -f "$src" "$KEYBOX_DEST"
        chmod 644 "$KEYBOX_DEST"
        cp -f "$src" "$KEYBOX_CACHE"
        chmod 644 "$KEYBOX_CACHE"

        # 已验签 -> 存进本地池（供将来失效时回滚）
        cache_store "$src" "$(sha256_of "$src")"
        cache_prune
    fi

    # 顺带对齐 TrickyStore 的安全补丁级别（春秋检测整改，prop 模式）
    ensure_security_patch

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

# ---- 安全补丁级别对齐（春秋检测「Tampered Attestation Key(26)」整改）----
# 成因：检测方拿 getprop 读到的补丁日期与 attestation 应答里的补丁日期做比对，
# 对不上就判「密钥被替换」。TEESimulator-RS / TrickyStore 支持 security_patch.txt
# 显式声明补丁级别（与 keybox.xml 同目录，是它的正常配置项）。
#
# 关键设计：用 prop 模式（system=prop），不写固定日期 ——
# TEESimulator-RS 对 prop 的处理是应答时【实时读 ro.build.version.security_patch】，
# 并把 boot/vendor 强制同走 prop（上游源码注释：防跨组件日期错位，TrickyAddon
# 写 Pixel 公报日期就踩过这个坑）。固定日期在 OTA / PIF 改 prop / vendor 分区
# 日期不同之后必然错位，26 会复报；prop 模式永不过时、永不错位。
# TEESimulator-RS 用 FileObserver 监听该文件（CLOSE_WRITE/MOVED_TO），写完即时生效。
#
# 覆盖策略：内容不是目标就备份成 .bak 后重写 —— 不管文件原来是谁写的。
# 该文件语义上只是「TEE 模拟器报什么日期」，备份在 .bak 可回滚，没有风险。
# 实在想自己维护这个文件：设置 security_patch=off，本模块完全不管。
SP_FILE="${SP_FILE:-/data/adb/tricky_store/security_patch.txt}"

# 目标内容。只写一行 system=prop：TEESimulator-RS 会强制 boot/vendor 同走 prop；
# 经典 TrickyStore 也认 system=prop（「keep consistent with system prop」）。
sp_body() {
    printf '# yypm 生成：prop 模式 = attestation 补丁级别实时跟随系统属性\n# 不要手改本文件，yypm 会重写（原文件备份在同目录 .bak）\nsystem=prop\n'
}

# 只读状态：none（不存在）/ ok（已是 prop 模式）/ fixed（固定日期或其它内容，待切换）
security_patch_state() {
    [ -f "$SP_FILE" ] || { echo none; return 0; }
    grep -q '^system=prop[[:space:]]*$' "$SP_FILE" 2>/dev/null && { echo ok; return 0; }
    echo fixed
}

# 生成/对齐 security_patch.txt 为 prop 模式。内容已是目标就不动；
# 否则先把原文件备份为 .bak 再重写（外来文件同样处理 —— 该文件只是
# 「TEE 模拟器报什么日期」的声明，备份可回滚，覆盖无风险）。
ensure_security_patch() {
    if [ "$(cfg_get security_patch auto)" = "off" ]; then
        dbg "security_patch: off，跳过"
        return 0
    fi
    # 设备上没有 TrickyStore 目录时别创建它 —— 空目录本身就是「异常文件」
    [ -d "$TRICKY_DIR" ] || { dbg "security_patch: 无 tricky_store 目录，跳过"; return 0; }
    if [ -f "$SP_FILE" ] && [ "$(cat "$SP_FILE" 2>/dev/null)" = "$(sp_body)" ]; then
        dbg "security_patch: 已是 prop 模式，无需写"
        return 0
    fi
    dbg "security_patch: 写入 system=prop（旧文件备份 .bak）"
    [ -f "$SP_FILE" ] && cp -f "$SP_FILE" "$SP_FILE.bak" 2>/dev/null
    sp_body > "$SP_FILE" 2>/dev/null || return 1
    chmod 644 "$SP_FILE" 2>/dev/null
    log "[✓] security_patch.txt 已对齐为 prop 模式（补丁级别实时跟随系统属性，原文件备份在 .bak）"
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
    # 连通性检测必须测「客户端实际取用的那条链」，而不是挑两个顺手的地址：
    # 顺序与 api_fetch_any 完全一致 —— 主源在前（清单必须新鲜）-> 镜像兜底（测速排序）-> GitHub API。
    # v2.8.2 及之前只测 主源+GitHub 两条；jsDelivr 分支解析缓存钉旧提交实测在案，
    # 主源前置正是为了绕开它。mirror_urls=off 时不测镜像（与真实行为一致）。
    probe_source "主源（自建服务器）" "$(api_url manifest)"
    local m f h
    f=$(mirror_file_of manifest 2>/dev/null)
    if [ -n "$f" ]; then
        for m in $(mirror_urls); do
            h="${m#*://}"; h="${h%%/*}"   # 镜像 base -> 域名（纯参数展开，不依赖 sed）
            probe_source "镜像 ${h}" "$m/$f"
        done
    fi
    probe_source "GitHub API（更新检查）" "https://api.github.com/repos/$GITHUB_REPO/releases/latest"
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
    # 安全补丁级别对齐状态（春秋检测整改；只读，不在这里写文件）
    echo "SP_STATE=$(security_patch_state)"
    echo "SP_PROP=$(getprop ro.build.version.security_patch 2>/dev/null | tr -d ' \r')"
    # 组件自动安装（P1）：待重启提示 + 风险应用自动隐藏开关
    if [ -s "$AUTO_INSTALL_PENDING" ]; then
        echo "AUTO_INSTALL_PENDING=$(tr '\n' ' ' < "$AUTO_INSTALL_PENDING" 2>/dev/null | sed 's/ $//')"
    fi
    echo "RISK_AUTOHIDE=$(cfg_get risk_autohide on)"
    echo "ABNORMAL_AUTO=$(cfg_get abnormal_auto on)"
    # 检测类应用自动并入 TrickyStore 目标清单的开关状态（春秋检测项 26 整改）
    echo "AUTO_TARGET=$(cfg_get auto_target on)"
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
    echo "DEBUG=$(cfg_get debug off)"
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

# ---- ksud 统一获取 ----
# 之前三处口径不一（command -v / /data/adb/ksud / find_ksud），PATH 不对时
# 会出现「检查通过、执行失败」。统一成这一个函数。
ksud_bin() {
    command -v ksud 2>/dev/null && return 0
    [ -x /data/adb/ksud ] && { echo /data/adb/ksud; return 0; }
    [ -x /data/adb/ksu/bin/ksud ] && { echo /data/adb/ksu/bin/ksud; return 0; }
    return 1
}

# ---- 通用 Ed25519 验签（模块包/附属模块包复用 keybox 的同一把公钥）----
# 信任根是公钥：内容从任何镜像/CDN 下载都安全，这是去中心化分发的前提。
# $1=文件 $2=base64 签名
# rc: 0=验过且通过；1=验了不过；2=验不了（无工具/公钥/签名为空）
verify_blob_sig() {
    local f="$1" sig="$2"
    [ -n "$sig" ] || return 2
    [ -f "$f" ] || return 1
    local pk=$(active_pubkey)
    [ -x "$VERIFY_TOOL" ] && [ -f "$pk" ] || return 2
    mkdir -p "$TMP" 2>/dev/null
    printf '%s' "$sig" > "$TMP/blob.sig"
    "$VERIFY_TOOL" "$pk" "$TMP/blob.sig" "$f" >/dev/null 2>&1
}

# 从 manifest.json 里取 module 块的字段（嵌套 JSON：先切 module 块再取值）。
# 优先读 TMP 里的新 manifest，没有再退回 DATA_DIR 缓存。
manifest_module_field() { # $1 = 字段名（sha256/signature/url/size）
    local mf="$TMP/manifest.json"
    [ -f "$mf" ] || mf="$DATA_DIR/manifest.json"
    [ -f "$mf" ] || return 1
    sed -n '/"module"[[:space:]]*:[[:space:]]*{/,/^[[:space:]]*}/p' "$mf" 2>/dev/null \
        | grep -o "\"$1\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" | head -1 \
        | sed 's/.*:[[:space:]]*"//; s/"$//'
}

# 从 packages.json 取某个包的字段（sha256/signature 等）
pkg_field() { # $1=文件名 $2=字段
    # check_updates 存 pkg_check.json，download_packages 存 packages.json —— 谁在用谁
    local src="$TMP/pkg_check.json"
    [ -f "$src" ] || src="$TMP/packages.json"
    [ -f "$src" ] || return 1
    if command -v python3 >/dev/null 2>&1; then
        python3 -c '
import json, sys
try:
    m = json.load(open(sys.argv[1], encoding="utf-8")).get("modules") or {}
    v = (m.get(sys.argv[2]) or {}).get(sys.argv[3])
    print("" if v is None else v)
except Exception:
    pass
' "$src" "$1" "$2" 2>/dev/null
        return 0
    fi
    # awk 兜底：服务端固定 PRETTY_PRINT（每字段一行），定位包名所在行后向下找字段
    awk -v name="\"$1\"" -v key="\"$2\"" '
        index($0, name) { inblk = 1; next }
        inblk && index($0, key) {
            line = $0
            sub(/^[^:]*:[[:space:]]*"/, "", line)
            sub(/".*$/, "", line)
            print line; exit
        }' "$src" 2>/dev/null
}

check_updates() {
    mkdir -p "$TMP" 2>/dev/null
    log "[·] 检查附属模块更新"

    if ! api_fetch_any packages "$TMP/pkg_check.json" >/dev/null 2>&1; then
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
        /\.(zip|apk)"[[:space:]]*:/ { k = $2 }
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
        p_ty=$(grep -F "$fn|" "$TMP/pmeta.txt" 2>/dev/null | cut -d'|' -f5 | head -1)
        p_pk=$(grep -F "$fn|" "$TMP/pmeta.txt" 2>/dev/null | cut -d'|' -f7 | head -1)

        # ---- APK 条目：已装三级判定（apk_installed），更新看安装时记的 sha 与清单 sha ----
        if [ "$p_ty" = "apk" ]; then
            local apk_label="${p_pk:-$fn}"
            local want_sha=$(pkg_field "$fn" sha256)
            local inst_sha=$(sed -n "s/^$fn=//p" "$AUTO_INSTALL_STATE" 2>/dev/null | head -1)
            if [ -z "$p_pk" ]; then
                # 清单没带包名（老服务端/手工清单）：没法判定装没装。
                # 如实报 ERR 而不是默默当「未安装」—— 否则这一项会永远显示待更新。
                echo "CHECK|$fn|$apk_label|?|?|ERR|清单缺应用包名（x-package），无法判断" >> "$TMP/check_out.txt"
                continue
            fi
            dbg "check: $fn apk pkg=$p_pk inst_sha=${inst_sha:-无} want_sha=${want_sha:-?}"
            if apk_installed "$p_pk"; then
                if [ -n "$inst_sha" ] && [ -n "$want_sha" ] && [ "$inst_sha" != "$want_sha" ]; then
                    echo "CHECK|$fn|$apk_label|已安装|新版|UPD|应用有新版本" >> "$TMP/check_out.txt"
                else
                    echo "CHECK|$fn|$apk_label|已安装|-|OK|已安装（应用）" >> "$TMP/check_out.txt"
                fi
            else
                echo "CHECK|$fn|$apk_label|未安装|-|NEW|未安装（应用，可自动安装）" >> "$TMP/check_out.txt"
            fi
            continue
        fi

        mid=$(echo "$fn" | sed 's/\.zip$//')
        [ -n "$p_id" ] && mid="$p_id"
        lvc=$(grep -F "$mid|" "$TMP/installed.txt" 2>/dev/null | cut -d'|' -f3 | head -1)
        local lstaged=$(grep -F "$mid|" "$TMP/installed.txt" 2>/dev/null | cut -d'|' -f4 | head -1)

        if [ -n "$p_vc" ]; then
            # ---- 快路径：清单给了 versionCode，零下载 ----
            rvc="$p_vc"
            rvtxt=${p_vr:-$p_vc}
            if [ -z "$lvc" ]; then
                echo "CHECK|$fn|$mid|未安装|$rvc|NEW|未安装（可用 KernelSU 的 Action 安装）${rvtxt:+（$rvtxt）}" >> "$TMP/check_out.txt"
            elif [ "$lvc" = "$rvc" ]; then
                if [ "$lstaged" = "1" ]; then
                    echo "CHECK|$fn|$mid|$lvc|$rvc|OK|已装好，重启后生效" >> "$TMP/check_out.txt"
                else
                    echo "CHECK|$fn|$mid|$lvc|$rvc|OK|已是最新" >> "$TMP/check_out.txt"
                fi
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
        f[i] == "x-version" || f[i] == "version" ||
        f[i] == "x-type" || f[i] == "x-auto" || f[i] == "x-package") {
      v = f[i+1]
      sub(/^[ \t]*:/, "", v)
      gsub(/[ \t]/, "", v)
      if (v == "" || v == "{") { v = f[i+2]; gsub(/[ \t]/, "", v) }
      if (f[i] == "x-id" || f[i] == "module_id") id = v
      else if (f[i] == "x-versionCode" || f[i] == "versionCode") { gsub(/[^0-9]/, "", v); if (v != "") vc = v }
      else if (f[i] == "x-type") ty = v
      else if (f[i] == "x-auto") au = v
      else if (f[i] == "x-package") pk = v
      else vr = v
    } else if (f[i] ~ /\.(zip|apk)$/ && f[i-1] != "url") {
      s = f[i+1]
      sub(/^[ \t]*:/, "", s)
      gsub(/[ \t]/, "", s)
      if (s != "{") continue
      if (k != "") print k "|" id "|" vc "|" vr "|" ty "|" au "|" pk
      k = f[i]; id = ""; vc = ""; vr = ""; ty = ""; au = ""; pk = ""
    }
  }
}
END { if (k != "") print k "|" id "|" vc "|" vr "|" ty "|" au "|" pk }
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
    ty  = e.get("x-type") or ""
    au  = e.get("x-auto") or ""
    pk  = e.get("x-package") or ""
    print("%s|%s|%s|%s|%s|%s|%s" % (name, vid, "" if vc is None else vc, vr, ty, au, pk))
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
    local d mp mid mnm mvc staged
    for d in /data/adb/modules/* /data/adb/modules_update/*; do
        [ -d "$d" ] || continue
        mp="$d/module.prop"
        [ -f "$mp" ] || continue
        mid=$(sed -n 's/^id=//p' "$mp" 2>/dev/null | head -1 | tr -d ' \r')
        mnm=$(sed -n 's/^name=//p' "$mp" 2>/dev/null | head -1 | tr -d '\r')
        mvc=$(vc_of "$d")
        # 第 4 字段：1 = 躺在 modules_update（已装好、重启后才生效）
        case "$d" in */modules_update/*) staged=1 ;; *) staged=0 ;; esac
        [ -n "$mid" ] && echo "$mid|$mnm|$mvc|$staged" >> "$TMP/installed.txt"
    done
    return 0
}

# ---- 组件自动安装的状态文件 ----
# state：APK 安装记录（文件名=安装时的清单 sha256，换版重装靠它判断）
# pending：本轮自动装过的组件（WebUI 提示「重启后生效」；modules_update 清空后自动销）
AUTO_INSTALL_STATE="${AUTO_INSTALL_STATE:-$DATA_DIR/apk_installed.sha}"
AUTO_INSTALL_PENDING="${AUTO_INSTALL_PENDING:-$DATA_DIR/auto_install.pending}"

download_packages() {
    log "[·] 拉取模块清单"
    api_fetch_any packages "$TMP/packages.json" >/dev/null 2>&1 || { log "[✗] 模块清单下载失败（镜像与主源都不通）"; return 1; }

    # 解析清单元信息（含云端 versionCode），用来判断哪些包真的需要下载
    build_pmeta "$TMP/packages.json"

    # 文件名 -> url 映射（auto_install_packages 按需补下载时用）
    grep -o '"url"[[:space:]]*:[[:space:]]*"[^"]*"' "$TMP/packages.json" 2>/dev/null \
        | sed 's/.*"\(http[^"]*\)".*/\1/' \
        | while IFS= read -r u; do [ -n "$u" ] && echo "$(basename "$u")|$u"; done > "$TMP/pkg_urls.txt"

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
            # 下载即校验：缓存里的包必须可信（Action/自动安装直接用这份）
            local wsig=$(pkg_field "$name" signature)
            local wsha=$(pkg_field "$name" sha256)
            if [ -n "$wsig" ]; then
                if ! verify_blob_sig "$dest/$name" "$wsig"; then
                    log "[✗] 验签失败，已删除: $name"
                    rm -f "$dest/$name"
                    continue
                fi
            elif [ -n "$wsha" ] && [ "$(sha256_of "$dest/$name")" != "$wsha" ]; then
                log "[✗] sha256 不匹配，已删除: $name"
                rm -f "$dest/$name"
                continue
            fi
            log "[✓] 模块已下载: $name"
        else
            log "[✗] 模块下载失败: $name"
        fi
    done < "$TMP/dl_list.txt"
    return 0
}

# ---- 组件自动安装（清单里 x-auto=1 的条目，每轮巡检末尾跑）----
# 模块：未装或云端 versionCode 更高 -> 下载（若无缓存）+ 验签 + ksud install（重启生效）
# APK：未安装或清单 sha256 与安装记录不同 -> 下载 + 验签 + pm install -r（立即生效）
# 只动清单里明确标了 x-auto 的条目；验签不过一律不装。失败不致命，下轮再试。
auto_install_packages() {
    [ -s "$TMP/pmeta.txt" ] || return 0
    local fn fid fvc fvr fty fau fpk
    local n_mod=0 n_apk=0
    : > "$TMP/auto_pending.txt" 2>/dev/null
    while IFS='|' read -r fn fid fvc fvr fty fau fpk; do
        [ -n "$fn" ] || continue
        if [ "$fau" != "1" ]; then
            dbg "auto_install: $fn 未标 x-auto，跳过"
            continue
        fi
        dbg "auto_install: 评估 $fn (type=${fty:-module} id=${fid:-?} vc=${fvc:-?} pkg=${fpk:-?})"
        local cache="$DATA_DIR/packages/$fn"
        local want_sig="" want_sha=""
        want_sig=$(pkg_field "$fn" signature)
        want_sha=$(pkg_field "$fn" sha256)

        if [ "$fty" = "apk" ]; then
            # ---- APK：pm install ----
            [ -n "$fpk" ] || continue
            local pm; pm=$(pm_bin 2>/dev/null) || continue
            local inst_sha=$(sed -n "s/^$fn=//p" "$AUTO_INSTALL_STATE" 2>/dev/null | head -1)
            if apk_installed "$fpk" && [ -n "$inst_sha" ] && [ "$inst_sha" = "$want_sha" ]; then
                dbg "auto_install: $fpk 已装且 sha 一致，跳过"
                continue   # 已装且就是清单里这份
            fi
            dbg "auto_install: $fpk 需要（未装或 sha 不同 inst=${inst_sha:-无} want=${want_sha:-?}）"
            if [ ! -s "$cache" ]; then
                local u=$(awk -F'|' -v k="$fn" '$1==k{print $2}' "$TMP/pkg_urls.txt" 2>/dev/null | head -1)
                [ -n "$u" ] || continue
                log "[·] 自动下载组件: $fn"
                download "$u" "$cache" || { rm -f "$cache"; continue; }
            fi
            if [ -n "$want_sig" ]; then
                verify_blob_sig "$cache" "$want_sig" || { log "[✗] $fn 验签失败，不装"; rm -f "$cache"; continue; }
            elif [ -n "$want_sha" ] && [ "$(sha256_of "$cache")" != "$want_sha" ]; then
                log "[✗] $fn sha256 不匹配，不装"; rm -f "$cache"; continue
            fi
            if "$pm" install -r "$cache" >/dev/null 2>&1; then
                log "[✓] 已自动安装应用 $fpk（$fn）"
                mkdir -p "$DATA_DIR" 2>/dev/null
                grep -v "^$fn=" "$AUTO_INSTALL_STATE" 2>/dev/null > "$AUTO_INSTALL_STATE.tmp"
                echo "$fn=$want_sha" >> "$AUTO_INSTALL_STATE.tmp"
                mv "$AUTO_INSTALL_STATE.tmp" "$AUTO_INSTALL_STATE"
                echo "$fpk（应用）" >> "$TMP/auto_pending.txt"
                n_apk=$((n_apk + 1))
            else
                log "[✗] 自动安装应用失败: $fn"
            fi
        else
            # ---- 模块 zip：ksud install ----
            [ -n "$fid" ] || continue
            local lvc=$(vc_of "/data/adb/modules/$fid" 2>/dev/null)
            [ -n "$lvc" ] || lvc=$(vc_of "/data/adb/modules_update/$fid" 2>/dev/null)
            if [ -n "$fvc" ] && [ -n "$lvc" ] && [ "$fvc" -le "$lvc" ] 2>/dev/null; then
                dbg "auto_install: $fid 已装 v$lvc >= 云端 v$fvc，跳过"
                continue   # 已装且云端不更高
            fi
            dbg "auto_install: $fid 需要（本地 ${lvc:-未装} < 云端 ${fvc:-?}）"
            if [ ! -s "$cache" ]; then
                local u=$(awk -F'|' -v k="$fn" '$1==k{print $2}' "$TMP/pkg_urls.txt" 2>/dev/null | head -1)
                [ -n "$u" ] || continue
                log "[·] 自动下载组件: $fn"
                download "$u" "$cache" || { rm -f "$cache"; continue; }
            fi
            if [ -n "$want_sig" ]; then
                verify_blob_sig "$cache" "$want_sig" || { log "[✗] $fn 验签失败，不装"; rm -f "$cache"; continue; }
            elif [ -n "$want_sha" ] && [ "$(sha256_of "$cache")" != "$want_sha" ]; then
                log "[✗] $fn sha256 不匹配，不装"; rm -f "$cache"; continue
            fi
            local KS=$(ksud_bin)
            [ -n "$KS" ] || continue
            if "$KS" module install "$cache" >/dev/null 2>&1; then
                log "[✓] 已自动安装模块 $fid（${fvr:-$fvc}，重启后生效）"
                echo "$fid（模块，重启后生效）" >> "$TMP/auto_pending.txt"
                n_mod=$((n_mod + 1))
            else
                log "[✗] 自动安装模块失败: $fid"
            fi
        fi
    done < "$TMP/pmeta.txt"

    if [ -s "$TMP/auto_pending.txt" ]; then
        mv "$TMP/auto_pending.txt" "$AUTO_INSTALL_PENDING" 2>/dev/null
        log "[✓] 组件自动安装完成：模块 $n_mod 个 / 应用 $n_apk 个"
    fi
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
    local KS=$(ksud_bin)
    local dest="$DATA_DIR/packages"
    mkdir -p "$dest"

    while IFS='|' read -r tag fn mid lvc rvc st msg; do
        [ -n "$fn" ] || continue
        # 装"确实有新版本"(UPD)与"未安装"(NEW)的条目。
        # 界面的可更新计数包含 NEW —— 一键安装必须与计数同口径，否则显示 N 项待更新、
        # 点了却只处理其中一部分（v2.8.3 修正：NEW 由跳过改为安装）。
        # OK（已最新）/ MISMATCH（建议手动重装）/ ERR（清单问题）仍然跳过。
        case "$st" in UPD|NEW) ;; *) continue ;; esac
        n=$((n + 1))
        echo "→ 安装 $mid $lvc → $rvc"

        # 类型提前判定：APK 走 pm install，不需要 ksud
        local p_ty=$(grep -F "$fn|" "$TMP/pmeta.txt" 2>/dev/null | cut -d'|' -f5 | head -1)
        local p_pk=$(grep -F "$fn|" "$TMP/pmeta.txt" 2>/dev/null | cut -d'|' -f7 | head -1)
        if [ "$p_ty" != "apk" ] && [ -z "$KS" ]; then
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

        # 安装前校验：有签名验签（首选），没签名至少对 sha256（旧服务端兼容）
        local want_sig=$(pkg_field "$fn" signature)
        if [ -n "$want_sig" ]; then
            if verify_blob_sig "$src" "$want_sig"; then
                echo "  [✓] 验签通过"
            else
                echo "  [✗] 验签失败，拒绝安装（包可能被篡改）"
                fail=$((fail + 1))
                continue
            fi
        else
            local want_sha=$(pkg_field "$fn" sha256)
            if [ -n "$want_sha" ] && [ "$(sha256_of "$src")" != "$want_sha" ]; then
                echo "  [✗] sha256 不匹配，拒绝安装"
                fail=$((fail + 1))
                continue
            fi
        fi

        if [ "$p_ty" = "apk" ]; then
            local pm; pm=$(pm_bin 2>/dev/null)
            if [ -n "$pm" ] && "$pm" install -r "$src" >/dev/null 2>&1; then
                echo "  [✓] 已安装应用 $p_pk（立即生效）"
                local wsha2=$(pkg_field "$fn" sha256)
                grep -v "^$fn=" "$AUTO_INSTALL_STATE" 2>/dev/null > "$AUTO_INSTALL_STATE.tmp"
                echo "$fn=$wsha2" >> "$AUTO_INSTALL_STATE.tmp"
                mv "$AUTO_INSTALL_STATE.tmp" "$AUTO_INSTALL_STATE"
                ok=$((ok + 1))
            else
                echo "  [✗] 应用安装失败"
                fail=$((fail + 1))
            fi
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
            # 刚才还显示可更新、现在却没有了：多半是后台巡检已自动装好（待重启）
            if [ -s "$AUTO_INSTALL_PENDING" ] || ls /data/adb/modules_update/*/module.prop >/dev/null 2>&1; then
                echo "INSTALL_ALL_MSG=可更新的组件已自动装好，重启后生效（无需手动安装）"
            else
                echo "INSTALL_ALL_MSG=没有需要安装的附属模块"
            fi
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

    # 拉 manifest 拿模块包签名（验签依据；镜像->主源，拉不到就降级为仅 versionCode 校验）
    api_fetch_any manifest "$TMP/manifest.json" >/dev/null 2>&1 \
        && cp -f "$TMP/manifest.json" "$DATA_DIR/manifest.json" 2>/dev/null
    local msig=$(manifest_module_field signature)

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
        if [ -z "$pkg_vc" ] || ! [ "$pkg_vc" -gt "$cur_vc" ] 2>/dev/null; then
            log "[!] 包内 versionCode=$pkg_vc 不高于当前 $cur_vc，丢弃"
            rm -f "$TMP/update.zip"
            continue
        fi
        # Ed25519 验签：服务器被攻破 / 下载被劫持都推不了假包
        if [ -n "$msig" ]; then
            if verify_blob_sig "$TMP/update.zip" "$msig"; then
                log "[✓] 模块包验签通过"
            else
                log "[✗] 模块包验签失败，丢弃（可能下载被篡改）"
                rm -f "$TMP/update.zip"
                continue
            fi
        else
            log "[!] 服务端未提供模块签名，仅按 versionCode 校验"
        fi
        got="$u"
        log "[✓] 已下载 $tag（versionCode $pkg_vc）"
        break
    done
    [ -n "$got" ] || { log "[✗] 所有下载源均失败"; return 0; }

    [ -f "$TMP/update.zip" ] || return 0
    local KS=$(ksud_bin)
    if [ -n "$KS" ]; then
        "$KS" module install "$TMP/update.zip" 2>/dev/null && log "[✓] 已通过 ksud 安装更新（重启后生效）"
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
# 强特征：只有游戏挂会用，正常模块不会带。
# 曾经把 ceserver / cheatengine / frida-server 放在这里，结果 FreePPS、Scene、
# uperf 这些【性能调优】模块全被判成实锤 —— 内存扫描工具是双用途的，
# 调优模块也带。把双用途的东西当实锤，代价是删掉用户正常的模块。
# 所以这里只留 GameGuardian 专属特征。
ac_payload_strong() {
    cat <<'ACEOF'
libgameguardian|GameGuardian 核心库（游戏内存修改器）
libgg.so|GameGuardian 核心库（游戏内存修改器）
ACEOF
}

# 双用途特征：内存扫描 / 注入框架。游戏挂在用，性能调优、逆向工具也在用。
# 单独命中只警告；如果这个模块的名字或描述同时带游戏挂关键字，才升级为实锤。
ac_payload_dual() {
    cat <<'ACEOF'
ceserver|Cheat Engine 服务端（内存扫描/修改）
cheatengine|Cheat Engine（内存扫描/修改）
frida-server|Frida 注入框架服务端
frida-gadget|Frida 注入框架
libsubstrate|Substrate Hook 框架
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

    # 3.5) 已知的性能调优 / 搞机模块。它们会带内存扫描类工具（ceserver 等），
    # 但用途是调度和调参，不是游戏挂。真机上这四个曾被误判，所以直接放行。
    case "$id" in
        freepps|uperf|scene|scene_*|*_swap_controller|*_systemless) return 0 ;;
        *perf*|*turbo*|*tune*|*boost*) return 0 ;;
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
ac_payload_hit() { # $1=模块目录 $2=特征表 -> 命中则输出「说明 ← 文件名」
    local dir="$1" table="$2" entry frag why hits f fb pat="" ok=""
    [ -d "$dir" ] || return 1
    local oldifs="$IFS"
    IFS='
'
    for entry in $table; do
        [ -n "$entry" ] || continue
        frag="${entry%%|*}"
        # 空片段会让 find 的模式退化成 **，也就是匹配一切。真机上就是它把
        # module.prop 报成了「含 GameGuardian 核心库」。片段里带空白同理，
        # 因为模式串是按空白分词后交给 find 的，一拆就散。
        [ -n "$frag" ] || continue
        case "$frag" in *" "*|*"	"*) continue ;; esac
        pat="$pat -o -iname *$frag*"
    done
    IFS="$oldifs"
    [ -n "$pat" ] || return 1
    pat="${pat# -o }"
    # 关掉路径展开：否则 *ceserver* 这种会被当前目录里的同名文件顶掉
    local hadf=0; case "$- " in *f*) hadf=1 ;; esac
    set -f
    hits=$(find "$dir" -maxdepth 3 -type f \( $pat \) 2>/dev/null | head -8)
    [ "$hadf" = "0" ] && set +f
    [ -n "$hits" ] || return 1
    # find 只当粗筛，真正的判定在这里：拿【文件名】逐条比对特征串。
    # 之前直接采信 find 的结果，模式串一旦被拆散就会退化成匹配一切，
    # 于是 module.prop 这种文件也被报成实锤 —— 这一步是那个 bug 的根治。
    IFS='
'
    for f in $hits; do
        fb=$(basename "$f" | tr 'A-Z' 'a-z')
        for entry in $table; do
            frag="${entry%%|*}"
            [ -n "$frag" ] || continue
            case "$fb" in *"$frag"*) why="${entry#*|}"; ok="$f"; break 2 ;; esac
        done
    done
    IFS="$oldifs"
    [ -n "$ok" ] || return 1
    printf '%s\n' "$why ← $(basename "$ok")"
}

ac_scan_payload() { ac_payload_hit "$1" "$(ac_payload_strong)"; }

ac_scan_payload_dual() { ac_payload_hit "$1" "$(ac_payload_dual)"; }

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
            # B 级：GameGuardian 专属特征 —— 只有游戏挂会带，直接实锤
            elif why=$(ac_scan_payload "$m"); then
                lvl=block; why="目录含 $why"
            # C 级：双用途工具（内存扫描/注入）。单独命中只警告，
            # 名字或描述里同时带游戏挂关键字才升级 —— 否则会误伤调优模块。
            elif why=$(ac_scan_payload_dual "$m"); then
                local kw2=""
                if kw2=$(ac_match_table "$hay" "$(ac_keywords)"); then
                    lvl=block; why="目录含 $why，且名称/描述含「$kw2」"
                else
                    lvl=warn; why="目录含 $why（内存/注入工具，可能是调优或逆向，需你确认）"
                fi
            # D 级：ImGui/IL2CPP 之类线索，只警告
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

    # Signal C：已安装的作弊 APK。只提醒，永不处理（不在 AC-BEGIN 的模块行里）。
    local pkgscan pkgrows npkg
    pkgscan=$(ac_scan_pkgs)
    npkg=$(printf '%s\n' "$pkgscan" | sed -n 's/^AC_PKG_HIT=//p' | head -1)
    case "$npkg" in ''|*[!0-9]*) npkg=0 ;; esac
    pkgrows=$(printf '%s\n' "$pkgscan" | grep '^PKG' 2>/dev/null)

    # Signal A（A3）：LSPosed 作用域命中游戏。只提醒；strings 粗扫无法归因到模块。
    # 没有 LSPosed 库 / 游戏清单不可用 / 库里没有游戏，都不算命中。
    local lspdrows nlspd=0 lspddb=0 games grc=0
    if [ -f "$AC_LSPD_DB" ]; then
        lspddb=1
        games=$(ac_game_pkgs) || grc=$?
        if [ "$grc" = "0" ] && [ -n "$games" ]; then
            lspdrows=$(ac_lspd_scope "$AC_LSPD_DB" "$games")
            [ -n "$lspdrows" ] && nlspd=$(printf '%s\n' "$lspdrows" | sed '/^$/d' | wc -l | tr -d ' ')
        fi
    fi
    case "$nlspd" in ''|*[!0-9]*) nlspd=0 ;; esac

    echo "AC_MODE=$(ac_mode)"
    echo "AC_LOCKED=$(ac_locked && echo 1 || echo 0)"
    echo "AC_PENDING=$(ac_pending && echo 1 || echo 0)"
    echo "AC_TOTAL=$total"
    echo "AC_BLOCK=$block"
    echo "AC_WARN=$warn"
    echo "AC_PKG_HIT=$npkg"
    echo "AC_LSPD_DB=$lspddb"
    echo "AC_LSPD_HIT=$nlspd"
    # 宽限期/封禁状态也要在「只扫描」时报出来 —— WebUI 的倒计时与封禁横幅指望它。
    # 纯只读：不调 ac_grace_update 重建计时表。
    echo "AC_DEVCODE=$(ac_device_code)"
    echo "AC_BANNED=$(ac_banned && echo 1 || echo 0)"
    local gleft=0
    if ac_pending; then
        gleft=$(ac_grace_left "$(cat "$AC_PENDING" 2>/dev/null | head -1)")
        case "$gleft" in ''|*[!0-9]*) gleft=0 ;; esac
    fi
    echo "AC_GRACE=$gleft"
    echo "AC-BEGIN"
    printf '%s' "$out"
    echo "AC-END"
    echo "AC-PKG-BEGIN"
    printf '%s\n' "$pkgrows" | sed '/^$/d'
    echo "AC-PKG-END"
    echo "AC-LSPD-BEGIN"
    printf '%s\n' "$lspdrows" | sed '/^$/d'
    echo "AC-LSPD-END"
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

# ---- Signal A：LSPosed 作用域识别（A3 零成本方案）----
# LSPosed 的 scope 表（哪个模块 hook 哪个应用）存在 SQLite 库 modules_config.db 里。
# A3 方案不解析表结构：对 db 做 strings 式粗扫，把「像包名」的字符串全抠出来，
# 再与设备上的游戏包名求交集。缺点是无法归因到具体模块 —— 所以这一档只提醒，
# 永远不提实锤（要归因得用 dex 直接读 SQLite，即 HANDOFF 任务 B 的 A1 方案）。
AC_LSPD_DB="${AC_LSPD_DB:-/data/adb/lspd/config/modules_config.db}"
AC_GAME_CACHE="${AC_GAME_CACHE:-$DATA_DIR/cache/game_pkgs.txt}"

# 设备上游戏类应用包名（ApplicationInfo.CATEGORY_GAME），一行一个。
# 来自 appinfo dex 输出的 game 标记；结果缓存 12 小时（新装的游戏最迟半天内认出）。
# dex 不可用 -> 返回 1（调用方据此把信号标成「未执行」，不算干净也不算命中）。
ac_game_pkgs() {
    local f="$AC_GAME_CACHE" mt
    if [ -f "$f" ]; then
        mt=$(stat -c %Y "$f" 2>/dev/null)
        case "$mt" in ''|*[!0-9]*) mt=0 ;; esac
        if [ $(( $(date +%s) - mt )) -lt 43200 ] 2>/dev/null; then
            cat "$f" 2>/dev/null
            return 0
        fi
    fi
    local out games
    out=$(appinfo_run 2>/dev/null) || return 1
    games=$(printf '%s\n' "$out" | awk -F'\t' '$3 ~ /(^|,)game(,|$)/ {print $1}' 2>/dev/null | sed '/^$/d')
    mkdir -p "$(dirname "$f")" 2>/dev/null
    printf '%s\n' "$games" | sed '/^$/d' > "$f" 2>/dev/null
    printf '%s\n' "$games" | sed '/^$/d'
    return 0
}

# $1=db 路径  $2=游戏包名（换行分隔）-> 输出出现在作用域库里的游戏包名（换行分隔）
# 返回码：0=有命中  1=无命中/db 不可读  2=游戏清单不可用（信号未执行）
ac_lspd_scope() {
    local db="$1" games="$2" pkgs g hits=""
    [ -f "$db" ] || return 1
    [ -n "$games" ] || return 2
    # tr 把非包名字符全部压成换行（等价 strings 的效果），再按包名形状过滤。
    # 不用 grep -a 直接读二进制：toybox / busybox / GNU 对二进制 -a 的行为不一致。
    pkgs=$(tr -cs 'A-Za-z0-9_.' '\n' < "$db" 2>/dev/null | \
        grep -E '^[a-zA-Z][a-zA-Z0-9_]*(\.[a-zA-Z0-9_]+){2,}$' 2>/dev/null | sort -u)
    [ -n "$pkgs" ] || return 1
    local oldifs="$IFS"
    IFS='
'
    for g in $games; do
        [ -n "$g" ] || continue
        case "
$pkgs
" in
            *"
$g
"*) hits="${hits}${g}
" ;;
        esac
    done
    IFS="$oldifs"
    [ -n "$hits" ] || return 1
    printf '%s' "$hits"
}

# ---- 疑似提醒（只提醒，无任何处置）----
# warn 级模块 / 作弊 APK / LSPosed 作用域命中游戏 —— 三类统一汇成一条提醒存
# $AC_NOTICE。WebUI 打开时读它，有就挂黄色提醒条；下次扫描干净了自动撤下。
# 提醒不是处置：不写锁定、不写计时、不动任何模块文件。
AC_NOTICE="${AC_NOTICE:-$DATA_DIR/ac.notice}"

ac_notice_set() { # $1=warn数 $2=pkg数 $3=lspd数
    local total=$(( ${1:-0} + ${2:-0} + ${3:-0} ))
    if [ "$total" -le 0 ] 2>/dev/null; then
        [ -f "$AC_NOTICE" ] && { rm -f "$AC_NOTICE" 2>/dev/null; log "[✓] 反挂：可疑项已清空，提醒撤下"; }
        return 0
    fi
    mkdir -p "$DATA_DIR" 2>/dev/null
    {
        echo "n=$total"
        echo "warn=${1:-0}"
        echo "pkg=${2:-0}"
        echo "lspd=${3:-0}"
        echo "at=$(date '+%Y-%m-%d %H:%M:%S')"
    } > "$AC_NOTICE" 2>/dev/null
}

ac_notice_report() {
    if [ -f "$AC_NOTICE" ]; then
        echo "AC_NOTICE=1"
        echo "AC_NOTICE_N=$(sed -n 's/^n=//p' "$AC_NOTICE" 2>/dev/null | head -1)"
        echo "AC_NOTICE_WARN=$(sed -n 's/^warn=//p' "$AC_NOTICE" 2>/dev/null | head -1)"
        echo "AC_NOTICE_PKG=$(sed -n 's/^pkg=//p' "$AC_NOTICE" 2>/dev/null | head -1)"
        echo "AC_NOTICE_LSPD=$(sed -n 's/^lspd=//p' "$AC_NOTICE" 2>/dev/null | head -1)"
        echo "AC_NOTICE_AT=$(sed -n 's/^at=//p' "$AC_NOTICE" 2>/dev/null | head -1)"
    else
        echo "AC_NOTICE=0"
    fi
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
    # 有实锤在时必须联网才工作 —— 断网即停，拔网线躲不掉 3 天期限。
    ac_net_gate || return 1
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
    # 疑似提醒（只提醒不处置）：warn 模块 / 作弊 APK / LSPosed 作用域的汇总
    ac_notice_report
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

# ============ 反挂：宽限期 / 设备码 / 封禁 / 联网闸 ============
# 规则（实锤才管；疑似只提醒 —— 记日志 + WebUI 黄条，无任何处置）：
#   开机扫描 -> 发现实锤 -> 给 3 天期限，期间锁定自身并倒计时
#   3 天内删掉挂模块 -> 计时清零，一切照常
#   逾期仍在     -> 删掉挂模块 + 封本机设备码，并把设备码上报服务端
#   有实锤在时   -> 模块只在联网状态下工作（断网即停，拔网线躲不掉）
AC_TIMER="${AC_TIMER:-$DATA_DIR/ac.timer}"
AC_BAN="${AC_BAN:-$DATA_DIR/ac.ban}"
AC_DEVCODE="${AC_DEVCODE:-$DATA_DIR/device.code}"
AC_GRACE_DAYS="${AC_GRACE_DAYS:-3}"

# 设备码：稳定、跨重装模块存活，且不落地原始隐私信息（只存哈希）。
ac_device_code() {
    [ -s "$AC_DEVCODE" ] && { cat "$AC_DEVCODE"; return 0; }
    local src="" id=""
    src="$(getprop ro.serialno 2>/dev/null)$(getprop ro.product.model 2>/dev/null)$(getprop ro.build.fingerprint 2>/dev/null)"
    [ -n "$src" ] || src="$(cat /proc/sys/kernel/random/uuid 2>/dev/null)"
    if command -v sha256sum >/dev/null 2>&1; then
        id=$(printf '%s' "$src" | sha256sum | cut -c1-16)
    elif command -v openssl >/dev/null 2>&1; then
        id=$(printf '%s' "$src" | openssl dgst -sha256 2>/dev/null | awk '{print $NF}' | cut -c1-16)
    fi
    [ -n "$id" ] || id=$(printf '%s' "$src" | cksum | tr -d ' ' | cut -c1-16)
    mkdir -p "$DATA_DIR" 2>/dev/null
    printf '%s\n' "$id" > "$AC_DEVCODE" 2>/dev/null
    printf '%s\n' "$id"
}

# 宽限期计时。$1 = 当前实锤 id（换行分隔）。
# 每次都按当前实锤重建计时表 —— 用户删掉挂模块后，对应条目自然消失，计时归零。
# 输出：已逾期的 id（换行分隔）。
ac_grace_update() {
    local ids="$1" now id t out="" new=""
    now=$(date +%s)
    for id in $ids; do
        [ -n "$id" ] || continue
        t=$(sed -n "s|^$id=||p" "$AC_TIMER" 2>/dev/null | head -1)
        case "$t" in ''|*[!0-9]*) t=$now ;; esac
        new="${new}${id}=${t}
"
        [ $((now - t)) -ge $((AC_GRACE_DAYS * 86400)) ] && out="${out}${id}
"
    done
    mkdir -p "$DATA_DIR" 2>/dev/null
    printf '%s' "$new" > "$AC_TIMER" 2>/dev/null
    printf '%s' "$out"
}

ac_grace_left() { # $1 = id -> 剩余天数（不足一天按一天算）
    local t now left
    t=$(sed -n "s|^$1=||p" "$AC_TIMER" 2>/dev/null | head -1)
    case "$t" in ''|*[!0-9]*) echo "$AC_GRACE_DAYS"; return 0 ;; esac
    now=$(date +%s)
    left=$(( AC_GRACE_DAYS - (now - t) / 86400 ))
    [ "$left" -lt 1 ] && left=1
    echo "$left"
}

ac_banned() {
    [ -s "$AC_BAN" ] || return 1
    # 文件里是「设备码 封禁时间」，只能比第一个字段。之前拿整行比，
    # 带上时间戳后永远不相等，封禁形同虚设。
    [ "$(head -1 "$AC_BAN" 2>/dev/null | cut -d" " -f1)" = "$(ac_device_code)" ]
}

ac_ban_set() {
    mkdir -p "$DATA_DIR" 2>/dev/null
    printf '%s %s\n' "$(ac_device_code)" "$(date '+%Y-%m-%d %H:%M:%S')" > "$AC_BAN" 2>/dev/null
    log "[✗] 反挂：已封禁本机设备码 $(ac_device_code)"
}

# 设备令牌文件（v2.7.0 起）：服务端首次联系时下发，之后上报必须带牌，
# 防止「知道设备码就能伪造 expire 封禁别人」。令牌只存本地，不落隐私。
AC_TOK_FILE="${AC_TOK_FILE:-$DATA_DIR/ac.token}"

ac_tok() { head -1 "$AC_TOK_FILE" 2>/dev/null | tr -cd '0-9a-f'; }

# 统一的服务端反挂通道：ping 探活 / scan 上报 / expire 上报都走这里。
# 服务端首次联系会下发 tok（响应里的 "tok":"..."），本地存 $AC_TOK_FILE（600）；
# 已持有的令牌绝不被响应里的值覆盖（防服务端被冒充后换牌）。
# 丢了令牌的后果：expire 会被服务端拒绝（不再接受无牌封禁），扫描上报与
# 封禁查询不受影响 —— 宁可封不上，也不能让伪造者封别人。
ac_call() { # $1=ev(ping|scan|expire)  $2=hits(csv，可空) -> stdout=响应体
    command -v curl >/dev/null 2>&1 || return 1
    local code=$(ac_device_code)
    # v2.8.0 起走 POST：tok 放 body 里，不进 nginx 访问日志（GET 时代码+令牌都在 query 里）
    local data="code=$code&ev=$1"
    [ -n "$2" ] && data="$data&hits=$2"
    local tok=$(ac_tok)
    [ -n "$tok" ] && data="$data&tok=$tok"
    local body=$(curl -s --connect-timeout 8 --max-time 20 -d "$data" "$(api_url acreport)" 2>/dev/null)
    [ -n "$body" ] || return 1
    case "$body" in
        *'"tok":"'*)
            if [ ! -s "$AC_TOK_FILE" ]; then
                local nt=$(printf '%s' "$body" | sed -n 's/.*"tok":"\([0-9a-f]\{64\}\)".*/\1/p' | head -1)
                if [ -n "$nt" ]; then
                    mkdir -p "$DATA_DIR" 2>/dev/null
                    printf '%s\n' "$nt" > "$AC_TOK_FILE" 2>/dev/null
                    chmod 600 "$AC_TOK_FILE" 2>/dev/null
                    log "[·] 反挂：已从服务端登记设备令牌（上报通道已加签）"
                fi
            fi
            ;;
    esac
    printf '%s' "$body"
}

# 联网探测：拿一个轻量端点试连通性。断网时模块停摆，靠的就是它。
# 能拿到响应体就算在线（哪怕业务上被拒绝，也说明网络通、服务在）。
# 主源不通（被攻击/维护）时退到镜像探活：镜像清单能拿到就算「降级在线」——
# 封禁状态冻结在本地最后一次已知结果，扫描上报排队到主源恢复。
ac_online() {
    ac_call ping "" >/dev/null 2>&1 && return 0
    local m
    for m in $(mirror_urls); do
        if curl -s --connect-timeout 5 --max-time 10 -o /dev/null "$m/manifest.json" 2>/dev/null; then
            log "[·] 主源不可达，镜像在线（降级模式：封禁冻结、上报排队）"
            return 0
        fi
    done
    return 1
}

# 上报：$1 = 事件（ping/scan/expire）  $2 = 命中 id（换行分隔）
ac_report() {
    local hits=$(printf '%s' "$2" | tr '\n' ',' | sed 's/,$//; s/ //g')
    local body
    body=$(ac_call "$1" "$hits") || return 1
    case "$body" in
        *'"ok":0'*)
            log "[!] 反挂：服务端拒绝了上报（$(printf '%s' "$body" | sed -n 's/.*"err":"\([^"]*\)".*/\1/p' | head -1)）"
            ;;
    esac
    return 0
}

# 向服务端确认本机是否被封。
#
# 这一步不能省：没有它，「封机器码」就是摆设 —— 用户删掉 /data/adb/yypm
# 重装模块，本地封禁文件就没了。只有向服务端问一次，封禁才跨重装有效。
# 注意：这里只【读状态】，服务端不下发任何指令。
ac_ban_query() {
    local r
    r=$(ac_call ping "") || return 1
    case "$r" in *'"banned":1'*) return 0 ;; esac
    return 1
}

# 联网闸：有实锤在时，模块必须联网才工作。
# 这不是「检查前先联网」，而是「不联网就别用」—— 否则拔网线就能把 3 天期限冻住。
ac_net_gate() {
    ac_pending || return 0
    ac_online && return 0
    log "[✗] 反挂：检测到实锤且当前离线，按规则停止运行"
    return 1
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
    local ids=$(printf '%s\n' "$rows" | awk -F'\t' '$2=="block"{print $1}')
    local id lvl nm why
    local pkgrows=$(printf '%s\n' "$scan" | sed -n '/^AC-PKG-BEGIN$/,/^AC-PKG-END$/p' | sed '1d;$d')
    local npkg=$(printf '%s\n' "$scan" | sed -n 's/^AC_PKG_HIT=//p' | head -1)
    local nlspd=$(printf '%s\n' "$scan" | sed -n 's/^AC_LSPD_HIT=//p' | head -1)
    case "$npkg" in ''|*[!0-9]*) npkg=0 ;; esac
    case "$nlspd" in ''|*[!0-9]*) nlspd=0 ;; esac

    # 疑似档（warn 模块 / 作弊 APK / LSPosed 作用域命中游戏）只提醒：记日志 +
    # 挂 WebUI 黄色提醒条（ac.notice），绝不处置。误报率摆在那里，动它得不偿失。
    printf '%s\n' "$rows" | while IFS="	" read -r id lvl nm why; do
        [ "$lvl" = "warn" ] && log "[?] 反挂可疑（仅记录）：$id（$nm）— $why"
    done
    printf '%s\n' "$pkgrows" | while IFS="	" read -r _tag _pkg _pwhy; do
        [ "$_tag" = "PKG" ] && [ -n "$_pkg" ] && log "[?] 反挂提醒：已安装作弊应用 $_pkg（$_pwhy）—— 仅提醒，不处理"
    done
    [ "$nlspd" != "0" ] && log "[?] 反挂提醒：LSPosed 作用域包含 $nlspd 个游戏（strings 粗扫无法归因到具体模块）—— 仅提醒"
    ac_notice_set "${nw:-0}" "$npkg" "$nlspd"

    echo "AC_DEVCODE=$(ac_device_code)"

    if [ "$nb" = "0" ]; then
        ac_grace_update "" >/dev/null   # 没有实锤：计时清零
        ac_pending_clear
        # 已封禁的设备不因为挂模块消失就解封 —— 封了就是封了，解封只能走服务端。
        if ac_banned; then
            ac_lock_set "本机设备码已被封禁（$(head -1 "$AC_BAN" 2>/dev/null | cut -d" " -f2- )）"
        else
            ac_lock_clear
        fi
        ac_report "scan" "" >/dev/null 2>&1
        # 本地没实锤，但服务端可能已把本机封了（用户重装过模块也一样查得到）。
        if ! ac_banned && ac_ban_query; then
            ac_ban_set
        fi
        echo "AC_GRACE=0"
        echo "AC_DUE=0"
        echo "AC_ACTED=0"
        echo "AC_BANNED=$(ac_banned && echo 1 || echo 0)"
        echo "AC_PENDING=0"
        echo "AC_LOCKED=$(ac_locked && echo 1 || echo 0)"
        return 0
    fi

    printf '%s\n' "$rows" | while IFS="	" read -r id lvl nm why; do
        [ "$lvl" = "block" ] && log "[!] 反挂实锤：$id（$nm）— $why"
    done

    local due=$(ac_grace_update "$ids")
    local ndue=$(printf '%s\n' "$due" | sed '/^$/d' | wc -l | tr -d ' ')
    local left=$(ac_grace_left "$(printf '%s\n' "$ids" | head -1)")
    echo "AC_GRACE=$left"
    echo "AC_DUE=$ndue"

    if [ "$ndue" != "0" ]; then
        # 逾期：删掉实锤模块并封设备码。这是全流程里唯一不可逆的动作，只对实锤做。
        local n=0 d
        for d in $due; do
            [ -n "$d" ] || continue
            ac_is_allowed "$d" && continue
            [ -d "$AC_MODDIR/$d" ] || continue
            if [ "$mode" = "quarantine" ]; then
                ac_quarantine "$d" && n=$((n + 1))
            elif rm -rf "$AC_MODDIR/$d" 2>/dev/null; then
                n=$((n + 1))
                log "[✗] 反挂：宽限期已过，已删除实锤模块 $d"
            fi
        done
        ac_ban_set
        ac_report "expire" "$ids" >/dev/null 2>&1
        ac_pending_clear
        ac_lock_set "实锤逾期未处理，已处理挂模块并封禁本机设备码"
        log "[✗] 反挂：宽限期已过，处置 $n 个实锤模块"
        echo "AC_ACTED=1"
        echo "AC_REMOVED=$n"
    else
        ac_pending_set "$ids"
        ac_lock_set "发现 $nb 个游戏挂模块，请在 $left 天内删除（逾期将自动删除并封禁本机）"
        ac_report "scan" "$ids" >/dev/null 2>&1
        echo "AC_ACTED=0"
    fi
    echo "AC_BANNED=$(ac_banned && echo 1 || echo 0)"
    echo "AC_PENDING=$(ac_pending && echo 1 || echo 0)"
    echo "AC_LOCKED=$(ac_locked && echo 1 || echo 0)"
    return 0
}

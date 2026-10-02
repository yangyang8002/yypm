#!/system/bin/sh
# =========================================================
# yypm Action 脚本 —— KernelSU 管理器里点「Action」触发
# 下载 package 清单里所有模块 -> sha256 校验本体 -> 一起安装
# =========================================================
BASE_URL="https://your-server.example.com/api/kernelsu/module"
TMP="/data/adb/yypm/tmp"

ui_print() { echo "$1"; }

download() { # $1 url  $2 out
    local url="$1" out="$2"
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL --connect-timeout 10 --max-time 60 --retry 2 -o "$out" "$url" 2>/dev/null && return 0
        return 1
    fi
    if command -v wget >/dev/null 2>&1; then
        wget -T 60 -t 2 --no-check-certificate -q -O "$out" "$url" 2>/dev/null && return 0
        return 1
    fi
    if command -v busybox >/dev/null 2>&1 && busybox --list 2>/dev/null | grep -qx wget; then
        busybox wget -T 60 -t 2 --no-check-certificate -q -O "$out" "$url" 2>/dev/null && return 0
        return 1
    fi
    ui_print "[x] 未找到 curl/wget"
    return 1
}

sha256_of() { # $1 file
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" | awk '{print $1}' 2>/dev/null
    elif command -v openssl >/dev/null 2>&1; then
        openssl dgst -sha256 "$1" 2>/dev/null | awk '{print $NF}'
    fi
}

# 从清单里提取指定模块的 sha256
get_sha() { # $1 文件名  $2 清单文件
    grep -A3 '"'$1'"' "$2" | grep '"sha256"' | head -1 | sed 's/.*"\([0-9a-fA-F]*\)".*/\1/'
}

# 从清单里提取指定模块的 Ed25519 签名（新版服务端有；没有时退回 sha256 校验）
get_sig() { # $1 文件名  $2 清单文件
    grep -A8 '"'$1'"' "$2" | grep '"signature"' | head -1 | sed 's/.*"signature"[[:space:]]*:[[:space:]]*"//; s/".*//'
}

SELF_DIR="$(cd "$(dirname "$0")" 2>/dev/null && pwd)"
VERIFY_TOOL="$SELF_DIR/verify_tool"
PUBKEY="$SELF_DIR/pubkey.b64"

# Ed25519 验签（与 keybox 同一把公钥）。rc: 0=通过 1=不过 2=验不了
verify_sig() { # $1 file $2 sig-b64
    [ -n "$2" ] || return 2
    [ -x "$VERIFY_TOOL" ] && [ -f "$PUBKEY" ] || return 2
    printf '%s' "$2" > "$TMP/pkg.sig"
    "$VERIFY_TOOL" "$PUBKEY" "$TMP/pkg.sig" "$1" >/dev/null 2>&1
}

# 输出 ksud 路径（之前只检查存在却调裸 ksud，PATH 不对时检查通过执行失败）
find_ksud() {
    command -v ksud 2>/dev/null && return 0
    [ -x /data/adb/ksud ] && { echo /data/adb/ksud; return 0; }
    [ -x /data/adb/ksu/bin/ksud ] && { echo /data/adb/ksu/bin/ksud; return 0; }
    return 1
}

ui_print "===== yypm 下载·校验·安装全部模块 ====="
mkdir -p "$TMP"

ui_print "[*] 拉取模块清单..."
if ! download "$BASE_URL?action=packages" "$TMP/packages.json"; then
    ui_print "[x] 清单下载失败"
    exit 1
fi
[ -s "$TMP/packages.json" ] || { ui_print "[x] 清单为空"; exit 1; }

# 提取所有模块 url
urls="$(grep -o '"url"[[:space:]]*:[[:space:]]*"[^"]*"' "$TMP/packages.json" | sed 's/.*"\(http[^"]*\)".*/\1/')"
[ -n "$urls" ] || { ui_print "[!] 清单无模块"; exit 0; }

KSUD_BIN="$(find_ksud)"; [ -n "$KSUD_BIN" ] && HAVE_KSUD=1 || HAVE_KSUD=0

OK_LIST=""
FAIL=0

for url in $urls; do
    name="$(basename "$url")"
    ui_print ""
    ui_print "[*] 下载 $name ..."
    if ! download "$url" "$TMP/$name"; then
        ui_print "[x] 下载失败 $name"
        FAIL=1
        continue
    fi

    ui_print "[*] 校验本体 $name ..."
    sig="$(get_sig "$name" "$TMP/packages.json")"
    expected="$(get_sha "$name" "$TMP/packages.json")"
    actual="$(sha256_of "$TMP/$name")"
    if [ -n "$sig" ]; then
        if verify_sig "$TMP/$name" "$sig"; then
            ui_print "[+] 验签通过（Ed25519）"
            OK_LIST="$OK_LIST $name"
        else
            ui_print "[x] 验签失败！包可能被篡改，拒绝安装"
            FAIL=1
        fi
    elif [ -n "$expected" ] && [ "$expected" = "$actual" ]; then
        ui_print "[+] 校验通过 ($actual)"
        OK_LIST="$OK_LIST $name"
    elif [ -z "$expected" ]; then
        ui_print "[!] 清单无 sha256，跳过校验（$actual）"
        OK_LIST="$OK_LIST $name"
    else
        ui_print "[x] 校验失败！期望 $expected 实际 $actual"
        FAIL=1
    fi
done

ui_print ""
if [ -n "$OK_LIST" ]; then
    ui_print "[*] 开始一起安装..."
    for name in $OK_LIST; do
        if [ "$HAVE_KSUD" = "1" ]; then
            ui_print "[*] 安装 $name ..."
            "$KSUD_BIN" module install "$TMP/$name" 2>&1 | grep -v '^$'
            [ $? -eq 0 ] && ui_print "[+] 已安装 $name" || ui_print "[x] 安装失败 $name"
        else
            ui_print "[!] 未找到 ksud，$name 已下载到 $TMP/$name"
        fi
    done
fi

[ "$FAIL" = "1" ] && ui_print "[!] 部分模块下载/校验失败，请检查网络后重试"
ui_print ""
ui_print "===== 完成 ====="
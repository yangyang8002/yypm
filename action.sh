#!/system/bin/sh
# =========================================================
# yypm Action 按钮脚本 —— 在 KernelSU 管理器里点「Action」触发
# 作用：下载并安装剩余模块（服务端 package 清单里的所有模块）
# 输出会显示在管理器的执行终端里
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

find_ksud() {
    command -v ksud >/dev/null 2>&1 && return 0
    [ -x /data/adb/ksu/bin/ksud ] && return 0
    return 1
}

ui_print "===== yypm 下载并安装剩余模块 ====="
mkdir -p "$TMP"

ui_print "[*] 拉取模块清单..."
if ! download "$BASE_URL?action=packages" "$TMP/packages.json"; then
    ui_print "[x] 清单下载失败，请检查网络或服务端"
    exit 1
fi
[ -s "$TMP/packages.json" ] || { ui_print "[x] 清单为空"; exit 1; }

urls="$(grep -o '"url"[[:space:]]*:[[:space:]]*"[^"]*"' "$TMP/packages.json" | sed 's/.*"\(http[^"]*\)".*/\1/')"
[ -n "$urls" ] || { ui_print "[!] 清单无模块"; exit 0; }

find_ksud && HAVE_KSUD=1 || HAVE_KSUD=0

for url in $urls; do
    name="$(basename "$url")"
    ui_print ""
    ui_print "[*] 下载 $name ..."
    if download "$url" "$TMP/$name" && [ -s "$TMP/$name" ]; then
        ui_print "    下载成功 ($(wc -c < "$TMP/$name") 字节)"
        if [ "$HAVE_KSUD" = "1" ]; then
            ui_print "[*] 安装 $name ..."
            if ksud module install "$TMP/$name" 2>&1 | grep -v '^$'; then
                ui_print "[+] 已安装 $name"
            else
                ui_print "[x] 安装失败 $name（可尝试重启后重装）"
            fi
        else
            ui_print "[!] 未找到 ksud，已下载到 $TMP/$name，请手动安装"
        fi
    else
        ui_print "[x] 下载失败 $name"
    fi
done

ui_print ""
ui_print "===== 完成 ====="
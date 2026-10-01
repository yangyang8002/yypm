# yypm

KernelSU 模块：自动获取 keybox 并挂载到 TEESimulator，附带隐藏 BL / 关闭调试伪装，
以及 WebUI 管理界面与 GitHub Release 自更新。

> 半开源：以下源码全部公开，但**敏感配置不公开**（服务端地址、Ed25519 公钥/私钥需自行生成与填写）。

## 功能

- 定时自动 / 手动获取 keybox，Ed25519 验签 + sha256 校验后挂载到 `/data/adb/tricky_store/keybox.xml`
- 隐藏 BL（伪造 bootloader 锁定）与关闭调试（伪造 release 版本），支持自动/手动
- KernelSU WebUI 图形界面管理所有开关
- 从 GitHub Release 检查并下载更新
- 自动下载服务端 `package.json` 清单里的所有模块

## 环境对抗（v2.3.1）

WebUI 新增「环境对抗」卡片，用于应对「春秋检测」这类环境检测：

- **隐藏应用列表（可定制）**：`pm hide` 把指定包从其它应用可见的包列表里摘掉，可一键还原
- **异常文件清理**：清掉 `/sdcard/MT2` 等落地目录，路径可配置
- **深度伪装启动状态**：伪装 `/proc/cmdline`、`/proc/bootconfig`；需要 Shamiko/SUSFS 支撑，
  没有支撑时不会硬改（bind mount 会在 mountinfo 里留下劫持痕迹）

## 应用名解析（AppInfo.java）

Android 的 `pm` / `dumpsys` **不输出应用显示名**，只给 `labelRes=0x7f...` 这种资源 id；
而 Android 11+ 的包可见性限制只约束普通应用，root 不受限。所以这里让系统自己解析：
把 `AppInfo.java` 编译成 `appinfo.dex`，用 `app_process` 跑起来（root），
一次 `getInstalledPackages` + `getApplicationLabel` 就拿到全部应用与本地化名称。

```bash
javac --release 11 -d build/classes AppInfo.java
java -cp r8.jar com.android.tools.r8.D8 --release --min-api 29 --output build/dex build/classes/AppInfo.class
cp build/dex/classes.dex appinfo.dex
```

产出约 5 KB。运行：

```bash
app_process -Djava.class.path=/data/adb/modules/yypm/appinfo.dex /data/adb/modules/yypm --nice-name=yypm-appinfo AppInfo
```

拿不到系统 Context 时（个别 ROM）会退回只输出包名，调用方再退回 `pm list packages`。

## 目录

```
module.prop
customize.sh     安装脚本
common.sh        公共库（下载/验签/注入/config/状态）
service.sh       主服务（定时循环）
webui.sh         WebUI 后端
verify_tool.go   验签工具源码（需 Go 交叉编译 arm64）
webroot/index.html  WebUI 前端
```

## 使用前必填（脱敏项）

1. `common.sh` 里的 `BASE_URL` —— 你自己的 keybox 分发服务地址
2. `common.sh` 里的 `GITHUB_REPO` —— 你的 GitHub 仓库（owner/repo）
3. `pubkey.b64` —— 你自己服务端生成的 Ed25519 公钥（base64）

```bash
# 编译验签工具（任意有 Go 的机器）
CGO_ENABLED=0 GOOS=linux GOARCH=arm64 go build -ldflags "-s -w" -o verify_tool verify_tool.go

# 打包
zip -r yypm.zip module.prop customize.sh service.sh webui.sh common.sh verify_tool pubkey.b64 webroot/
```

## 服务端配套

需自行部署一个 keybox 分发服务（拉取上游 keybox → 解码 → Ed25519 签名 → 分发），
其 API 端点：

| 端点 | 说明 |
|---|---|
| `?action=manifest` | keybox 元信息（url/sha256/signature）|
| `?action=keybox`   | keybox.xml |
| `?action=packages` | 模块清单 |
| `?action=pubkey`   | 公钥 |

## License

源码公开部分可自由使用；keybox 等敏感材料与分发服务请自行合规处理。

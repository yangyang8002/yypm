# yypm

> 自建 keybox 分发系统的 KernelSU 客户端模块
> KernelSU module client for a self-hosted keybox distribution system

**[中文](#中文) · [English](#english)**

---

## 中文

### 这是什么

yypm 是一个 KernelSU 模块。它从你自己搭建的服务器定时拉取 keybox，验签后注入
`/data/adb/tricky_store/keybox.xml`，供 **TrickyStore / TEESimulator-RS** 使用，让设备通过
Play Integrity 的硬件认证。

keybox 不随模块分发，而是由服务端从多个公开上游源拉取、解码、校验、Ed25519 签名后再下发。
客户端只信任自己服务端的公钥，因此上游源挂掉或被投毒都不会影响已装设备。

### 系统要求

| 项目 | 要求 |
|---|---|
| Android | **13 ~ 17（API 33 ~ 37）** |
| 框架 | KernelSU（也兼容 Magisk） |
| 架构 | arm64（`verify_tool` 与 `appinfo.dex` 都只带 arm64） |
| 宿主模块 | TrickyStore 或 TEESimulator-RS |

**为什么是 Android 13 起**：模块依赖三项系统能力 —— `app_process`（应用名 / 图标解析）、
`pm hide`（隐藏应用列表）、`resetprop`（属性伪装）。低于 API 33 时这些能力的现代行为不齐，
不保证可用。

**Android 17（API 37）之后**属于未验证区间：模块会在安装和 WebUI 里提示，但不会阻止使用。

版本信息在 WebUI 的「安全」卡片里能直接看到，超出范围时会标成「超出范围」。

### 功能

#### 1. keybox 自动分发与注入

- 定时（默认 6 小时，可配）从服务端拉取 keybox，**Ed25519 验签 + sha256 校验**后才落盘
- 拉取失败自动回滚到本地缓存的上一个可用 keybox，不会把设备留在无 keybox 状态
- 注入 `/data/adb/tricky_store/keybox.xml`，兼容 TrickyStore 与 TEESimulator-RS
- 手动触发：WebUI 按钮，或 KernelSU 的 Action 按钮

#### 2. 环境伪装

- **隐藏 BL**：伪造 bootloader 锁定状态
- **关闭调试**：把 `userdebug` / `eng` 版本伪装成 `user` 版
- **深度伪装**：伪装 `/proc/cmdline`、`/proc/bootconfig`。需要 Shamiko / SUSFS 支撑；
  没有支撑时**不会硬改** —— bind mount 会在 mountinfo 里留下劫持痕迹，反而更容易被检测
- **隐藏应用列表**：用 `pm hide` 把指定包从其它应用可见的包列表里摘掉，可一键还原

#### 3. WebUI（Material You / MD3）

- 完整的中文图形界面，深色 / 浅色跟随系统
- **7 套配色**：紫、蓝、绿、青、橙、**金**、红，外加**任意自选颜色**
  （取色器实时预览，按 M3 的 HCT 规则自动推导整套色板）
- 横屏自适应，平板 / 折叠屏不会挤成一列
- 双通道兼容：优先用 `ksu.exec`，不可用时退回 `import('kernelsu')`

#### 4. 应用名与图标解析（appinfo.dex）

Android 的 `pm` / `dumpsys` **不输出应用显示名**，只给 `labelRes=0x7f...` 这种资源 id。
本模块自带一个 10 KB 的 `appinfo.dex`，用 `app_process` 以 root 身份跑，通过 `PackageManager`
拿到真实的应用名和图标 —— 全部用 `Class.forName` 反射实现，不依赖 `android.jar`，
所以 dex 极小且跨 ROM 通用。

拿不到系统 Context 时（个别 ROM）会退回只输出包名，调用方再退回 `pm list packages`。

#### 5. LSPosed 模块识别

扫描已装模块的 APK 特征，识别出哪些是 LSPosed / Xposed 模块并显示作用域，
避免用户把「模块没生效」误判成「模块没装」。

#### 6. keybox 自检与修复

这是本模块比较特别的部分 —— 它不只负责发 keybox，还会**自己判断手里的 keybox 还能不能用**。

- **吊销状态检查**：从多个公开镜像（purainity / KimmyXYC / Google 官方 CRL）拉取吊销列表，
  本地缓存 24 小时；把当前 keybox 的证书序列号逐个比对，判断是否已被吊销
- **证书链检查**：用 `app_process` 拉起真实的密钥认证流程，dump 出设备实际使用的证书链，
  与 keybox 里的链对比
- **有效期推算**：算出生效日期、剩余天数，并按剩余时间给出建议（该换了 / 还能用）
- **一键修复**：自检发现问题时可直接触发一次重新拉取 + 重挂载，不用手动折腾

> 需要说明的是：如果 keybox 里的证书**签发日期**很老（比如 2020 年签发、2030 年到期），
> 部分检测会据此判断「设备存在替换密钥行为」。这是泄漏 keybox 的固有特征 ——
> 真实的 TEE 证书是**按需签发**的。中间 CA 的私钥不在 keybox 里（只有叶证书私钥），
> 所以叶证书无法重签，换源也解决不了。自检会把这个情况如实报出来。

#### 7. 反挂检查（游戏挂）

游戏挂和本模块会互相拖累：反作弊一旦标记本机，依赖硬件认证的应用会跟着一起失效。
所以模块会检查机器上有没有游戏挂，并且**判定依据不是名字，而是行为证据**。

分四级信号，可靠性从高到低：

| 级别 | 依据 | 处置 |
|---|---|---|
| **A** | 模块目录里躺着注入 / 内存工具的**实体文件**（`ceserver`、`frida-server`、`libgg.so`、`libsubstrate` 等） | 按模式处理 |
| **B** | 模块 ID / 名称 / 描述命中游戏挂关键字 | **只警告** |
| **C** | 已安装的作弊 APK（GameGuardian、Lucky Patcher、Freedom） | **只警告** |
| **D** | 你在配置里精确点名的模块 id | 按模式处理 |

**为什么关键字只警告**：`tricky_store`、`playintegrityfix` 这些伪装类模块名字里全是敏感词，
按关键字扫第一个就会命中它们，删掉等于拆掉整个 keybox 基础设施。所以只有**文件级证据**
和**用户精确点名**才允许动手。

**处置策略**：

- **实锤** → 强制删除该模块（默认），或移到隔离区（可一键还原）
- **可疑** → **锁定 yypm 自身**：停用全部功能、界面全局转红、开机不加载、断网不加载

锁定是 fail-closed 的：断网同样保持锁定，拔网线绕不过去。可疑模块消失后自动解锁。

**反馈通道**：锁定时界面顶部会出现「发邮件反馈」和「复制反馈内容」。前者直接调起邮件
客户端，收件人 `your-email@example.com`，正文自动带上模块版本、系统版本、处理模式、锁定原因、
锁定时间和完整检测结果 —— 你只需要补一句说明。部分 WebView 会吞掉 `mailto:`，
这时用「复制反馈内容」手动粘贴发送。

**白名单**（三层，任何一层命中都放行，且在 `delete` 模式下同样生效）：

1. yypm 自己
2. yypm 分发的模块：`tricky_store`、`playintegrityfix`、`zygisksu`、`zygisk_lsposed`
3. 任何 yypm 亲手装上去的模块（从下载缓存反推，以后加新包不用改代码）
4. 兜底：`shamiko`、`susfs*`、`kernelsu*`、`magisk`、`*lsposed*`、`*integrity*`

安装阶段也会跑一次检查：命中实锤就**中止安装**，此时还没有任何副作用，是最干净的拦截点。

#### 8. 模块分发

服务端 `package/` 目录里的模块会被自动打包成清单，客户端可一键下载安装。默认分发 4 个：

| 模块 | 用途 |
|---|---|
| `tricky_store` (TEESimulator) | keybox 的宿主 |
| `playintegrityfix` | Play Integrity 修复 |
| `zygisksu` (Zygisk-Next) | Zygisk 实现 |
| `zygisk_lsposed` | LSPosed |

#### 9. 自更新与诊断

- 从 GitHub Release 检查新版本，显示更新日志，可直接下载安装
- 一键导出诊断 zip：模块状态、配置、日志、挂载信息、已装模块清单、keybox 状态

### 安装

1. 在 KernelSU / Magisk 里刷入 `yypm.zip`
2. 重启
3. 打开 KernelSU 管理器 → 本模块 → WebUI（或点 Action 按钮）
4. 首次会自动拉取 keybox 并注入

### 使用前必填（脱敏项）

本仓库是脱敏版，需要你填三个地方：

1. `common.sh` 里的 `BASE_URL` —— 你自己的 keybox 分发服务地址
2. `common.sh` 里的 `GITHUB_REPO` —— 你的 GitHub 仓库（`owner/repo`）
3. `pubkey.b64` —— 你自己服务端生成的 Ed25519 公钥（base64）

### 编译

```bash
# 验签工具（任意有 Go 的机器）
CGO_ENABLED=0 GOOS=linux GOARCH=arm64 go build -ldflags "-s -w" -o verify_tool verify_tool.go

# appinfo.dex（需要 JDK + r8）
javac --release 11 -encoding UTF-8 -d build/classes appinfo/AppInfo.java
java -cp r8.jar com.android.tools.r8.D8 --release --min-api 29 --output build/dex build/classes/**/*.class

# 打包
zip -r yypm.zip module.prop customize.sh service.sh webui.sh common.sh \
    verify_tool pubkey.b64 appinfo.dex webroot/
```

### 目录

```
module.prop          模块元信息
customize.sh         安装脚本（含反挂拦截）
common.sh            公共库（下载 / 验签 / 注入 / 配置 / 自检 / 反挂）
service.sh           主服务（定时循环）
webui.sh             WebUI 后端
action.sh            KernelSU Action 按钮
verify_tool.go       验签工具源码（Go，交叉编译 arm64）
appinfo/AppInfo.java 应用名 / 图标解析（编译成 appinfo.dex）
webroot/index.html   WebUI 前端（MD3）
```

### 服务端 API

| 端点 | 说明 |
|---|---|
| `?action=manifest` | keybox 元信息（url / sha256 / signature）|
| `?action=keybox` | keybox.xml |
| `?action=packages` | 模块清单 |
| `?action=pubkey` | 公钥 |
| `?action=revocation` | 吊销列表 |
| `?action=keyboxreport` | keybox 自检报告（证书链 / 有效期 / 吊销状态）|

---

## English

### What is this

yypm is a KernelSU module. It periodically pulls a keybox from your own server, verifies
the signature, and injects it into `/data/adb/tricky_store/keybox.xml` for
**TrickyStore / TEESimulator-RS**, so the device passes Play Integrity hardware attestation.

The keybox itself is not shipped with the module. Your server pulls it from several public
upstream sources, decodes, validates and Ed25519-signs it before distribution. The client
only trusts your server's public key, so a compromised or dead upstream cannot affect
already-installed devices.

### Requirements

| Item | Requirement |
|---|---|
| Android | **13 – 17 (API 33 – 37)** |
| Framework | KernelSU (Magisk also works) |
| Architecture | arm64 (both `verify_tool` and `appinfo.dex` ship arm64 only) |
| Host module | TrickyStore or TEESimulator-RS |

**Why Android 13 as the floor**: the module relies on three system capabilities —
`app_process` (app label / icon resolution), `pm hide` (hidden app list) and `resetprop`
(property spoofing). Below API 33 their modern behaviour is inconsistent, so support is not
guaranteed.

**Beyond Android 17 (API 37)** is unverified territory: the module warns during installation
and in the WebUI, but does not block usage.

The detected version is shown in the WebUI's "Security" card, marked as out of range when it
falls outside the supported window.

### Features

#### 1. Automatic keybox distribution and injection

- Pulls the keybox on a schedule (6 h by default, configurable), and only writes it after
  **Ed25519 signature + sha256 verification**
- On failure it rolls back to the last known-good cached keybox, so the device is never
  left without one
- Injects into `/data/adb/tricky_store/keybox.xml`; works with both TrickyStore and
  TEESimulator-RS
- Trigger manually from the WebUI or the KernelSU Action button

#### 2. Environment spoofing

- **Hide bootloader**: fake a locked bootloader state
- **Disable debugging**: disguise `userdebug` / `eng` builds as `user`
- **Deep disguise**: spoof `/proc/cmdline` and `/proc/bootconfig`. Requires Shamiko / SUSFS
  support; **without it the module refuses to fake anything** — a bind mount leaves hijack
  traces in mountinfo and is easier to detect than doing nothing
- **Hidden app list**: use `pm hide` to remove selected packages from the list other apps
  can see, with one-tap restore

#### 3. WebUI (Material You / MD3)

- Full graphical interface; dark / light follows the system
- **7 palettes**: purple, blue, green, teal, orange, **gold**, red — plus an **arbitrary
  custom colour** (live picker, derives the whole M3 palette using HCT rules)
- Landscape-aware layout; tablets and foldables do not collapse into one column
- Dual-channel compatibility: prefers `ksu.exec`, falls back to `import('kernelsu')`

#### 4. App name and icon resolution (appinfo.dex)

Android's `pm` / `dumpsys` **do not print app display names**, only resource ids like
`labelRes=0x7f...`. This module ships a 10 KB `appinfo.dex` that runs under `app_process`
as root and uses `PackageManager` to get real labels and icons. Everything goes through
`Class.forName` reflection, so it needs no `android.jar` — the dex stays tiny and works
across ROMs.

If the system Context is unavailable (some ROMs) it degrades to package names only, and the
caller falls back to `pm list packages`.

#### 5. LSPosed module detection

Scans installed module APKs for Xposed markers to identify which ones are LSPosed modules
and what scope they target, so users do not mistake "module not active" for "module not
installed".

#### 6. Keybox self-check and repair

This is the unusual part — the module does not just hand out a keybox, it also **decides
whether the keybox it holds is still usable**.

- **Revocation check**: pulls revocation lists from several public mirrors (purainity /
  KimmyXYC / Google CRL), caches them for 24 h, and compares every certificate serial in the
  current keybox against them
- **Certificate chain check**: drives a real key attestation through `app_process` and dumps
  the chain the device actually presents, then compares it with the one inside the keybox
- **Validity estimate**: computes issue date and days remaining, and advises whether a
  replacement is due
- **One-tap repair**: when the self-check finds a problem, it can re-fetch and re-mount
  immediately

> Caveat: if the certificates inside the keybox have an old **issue date** (e.g. issued 2020,
> expiring 2030), some detectors conclude "the device replaced its key". That is inherent to
> leaked keyboxes — real TEE certificates are **minted on demand**. The intermediate CA
> private key is not in the keybox (only the leaf key is), so the leaf cannot be re-signed,
> and switching sources does not help. The self-check reports this honestly.

#### 7. Anti-cheat check (game cheats)

Game cheats and this module undermine each other: once an anti-cheat flags the device, every
app relying on hardware attestation fails with it. So the module checks for game cheats — and
it judges by **behavioural evidence, not by name**.

Four signal levels, most to least reliable:

| Level | Evidence | Action |
|---|---|---|
| **A** | Actual injection / memory tool **binaries** in a module directory (`ceserver`, `frida-server`, `libgg.so`, `libsubstrate`, ...) | Act per mode |
| **B** | Module id / name / description matches a game-cheat keyword | **Warn only** |
| **C** | Installed cheat APKs (GameGuardian, Lucky Patcher, Freedom) | **Warn only** |
| **D** | Module ids you name explicitly in config | Act per mode |

**Why keywords only warn**: spoofing modules like `tricky_store` and `playintegrityfix` are
full of sensitive words in their names; a keyword scan hits them first, and deleting them
tears down the entire keybox infrastructure. So only **file-level evidence** and **explicit
user listing** are allowed to trigger action.

**Policy**:

- **Hard evidence** → force-delete that module (default), or move it to quarantine (one-tap
  restore)
- **Suspicious** → **lock yypm itself down**: all features disabled, UI turns red globally,
  no loading at boot, no loading while offline

The lockdown is fail-closed: it stays locked while offline, so pulling the network cable does
not bypass it. It clears automatically once the suspicious modules are gone.

**Feedback channel**: while locked, the top of the UI offers "Email feedback" and "Copy
feedback". The first opens your mail client addressed to `your-email@example.com` with the module
version, Android version, mode, lock reason, lock time and the full detection result already
filled in — you only add a sentence of explanation. Some WebViews swallow `mailto:`, in which
case use "Copy feedback" and paste it manually.

**Whitelist** (three layers; any match passes, and it is enforced even in `delete` mode):

1. yypm itself
2. Modules distributed by yypm: `tricky_store`, `playintegrityfix`, `zygisksu`, `zygisk_lsposed`
3. Anything yypm installed itself (derived from the download cache, so new packages need no
   code change)
4. Fallback patterns: `shamiko`, `susfs*`, `kernelsu*`, `magisk`, `*lsposed*`, `*integrity*`

The install script runs the check too: hard evidence **aborts the installation**, which is the
cleanest interception point because nothing has taken effect yet.

#### 8. Module distribution

Modules placed in the server's `package/` directory are packaged into a manifest that clients
can download and install in one tap. Four are distributed by default:

| Module | Purpose |
|---|---|
| `tricky_store` (TEESimulator) | Host for the keybox |
| `playintegrityfix` | Play Integrity fix |
| `zygisksu` (Zygisk-Next) | Zygisk implementation |
| `zygisk_lsposed` | LSPosed |

#### 9. Self-update and diagnostics

- Checks GitHub Releases for a new version, shows the changelog, and installs it
- Exports a diagnostic zip in one tap: module state, config, logs, mount info, installed
  module list, keybox state

### Installation

1. Flash `yypm.zip` in KernelSU / Magisk
2. Reboot
3. Open KernelSU manager → this module → WebUI (or tap the Action button)
4. The keybox is fetched and injected automatically on first run

### Required before use (redacted values)

This repository is sanitised. Fill in three places:

1. `BASE_URL` in `common.sh` — your own keybox distribution server
2. `GITHUB_REPO` in `common.sh` — your GitHub repo (`owner/repo`)
3. `pubkey.b64` — the Ed25519 public key generated by your server (base64)

### Building

```bash
# verification tool (any machine with Go)
CGO_ENABLED=0 GOOS=linux GOARCH=arm64 go build -ldflags "-s -w" -o verify_tool verify_tool.go

# appinfo.dex (requires JDK + r8)
javac --release 11 -encoding UTF-8 -d build/classes appinfo/AppInfo.java
java -cp r8.jar com.android.tools.r8.D8 --release --min-api 29 --output build/dex build/classes/**/*.class

# package
zip -r yypm.zip module.prop customize.sh service.sh webui.sh common.sh \
    verify_tool pubkey.b64 appinfo.dex webroot/
```

### Layout

```
module.prop          module metadata
customize.sh         install script (includes anti-cheat interception)
common.sh            shared library (fetch / verify / inject / config / self-check / anti-cheat)
service.sh           main service (scheduled loop)
webui.sh             WebUI backend
action.sh            KernelSU Action button
verify_tool.go       verification tool source (Go, cross-compiled for arm64)
appinfo/AppInfo.java app label / icon resolution (compiled into appinfo.dex)
webroot/index.html   WebUI frontend (MD3)
```

### Server API

| Endpoint | Description |
|---|---|
| `?action=manifest` | keybox metadata (url / sha256 / signature) |
| `?action=keybox` | keybox.xml |
| `?action=packages` | module manifest |
| `?action=pubkey` | public key |
| `?action=revocation` | revocation list |
| `?action=keyboxreport` | keybox self-check report (chain / validity / revocation) |

### License

Public sources may be used freely. Sensitive material such as keyboxes and the distribution
service must be handled in compliance with applicable rules.

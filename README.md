# yypm

> 自建 keybox 分发系统的 KernelSU 客户端模块
> KernelSU module client for a self-hosted keybox distribution system

**[中文](#中文) · [English](#english)**

---

## 中文

### ⚖️ 安全声明（先读这个）

> **本模块不会、也不能在远端运行任何代码。**
>
> 服务器只下发「数据」，而且每一份数据（keybox、清单、模块安装包、组件包）都必须通过
> 客户端内置公钥的 **Ed25519 验签**才会被采用。模块不接收、不解析、不执行服务器下发的
> 任何命令或脚本 —— 协议里根本不存在这种通道。
>
> 为了保证所有用户的公平，服务端能做的最坏的事只有一件：**封禁作弊设备的设备号**
> （设备属性的单向哈希，不是手机号/IMEI 等个人信息）。被封禁的设备后果是模块停止工作，
> **不影响设备上除本模块之外的任何功能**。
>
> 换句话说：服务器被攻陷的最坏结果是「服务不可用」，而不是「你的手机被控制」。

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

### 功能

#### 1. keybox 自动分发与注入
- 定时从服务端拉取，Ed25519 验签 + sha256 双校验后注入 TrickyStore
- 本地保留多份已验签 keybox 池，上游失效自动回滚
- Google 吊销名单多源镜像拉取，本地比对序列号，被判吊销的 keybox 自动停用
- 注入用「原子替换 + 权限修正」，不触发 TEESimulator 的异常文件监控

#### 2. 环境检测整改（春秋/牛牛等检测器的逐项自动处理）
- **安全补丁级别**：自动写入 `security_patch.txt`（`system=prop` 模式），attestation
  始终回答系统当前属性值，OTA 后不再出现跨组件日期错位；他人的固定日期文件会被
  备份（`.bak`）后替换，`security_patch=off` 可整体关闭
- **风险应用自动隐藏**：检测到 Scene/Shizuku/NP 管理器等风险应用已安装时，自动并入
  隐藏列表并开启隐藏（`risk_autohide=off` 可关）
- **异常环境自动清理**：发现 MT 管理器残留等异常时自动处置（`abnormal_auto=off` 可关）
- **FuseFixer / hma-uidfake**：服务器自动跟踪上游 release，验签后**自动安装**；
  WebUI 一键把 FuseFixer 写进 LSPosed 配置库（启用模块 + 勾选系统框架）

#### 3. 组件包分发（带签名的应用商店）
- 服务端维护组件清单（LSPosed / Zygisk-Next / PlayIntegrityFix / TEESimulator 等）
- 每个包都带服务端 Ed25519 签名 + 包内 module.prop 解析出的真实版本号
- 客户端按 versionCode 判断更新，验签通过才允许安装；APK 类组件按 sha256 判断
- `fetch_packages.php`（cron）可自动跟踪上游 GitHub release 并落盘，见
  `php-server/package/sources.json`

#### 4. 去中心化镜像分发（主源宕机照常工作）
- GitHub Actions 每 30 分钟把主源数据**验签后**镜像到本仓：
  `mirror-data` 分支（manifest/keybox/packages 清单）+ `mirror` release（zip/apk 本体）
- 客户端取数顺序：**jsDelivr → raw.githubusercontent → 自建服务器**，
  镜像 URL 在镜像发布时已改写为自包含地址
- 主源只剩 `acreport`（封禁上报）一个轻量职责；主源被攻击时客户端进入
  「降级在线」：功能照常，封禁状态冻结在本地最后已知结果
- `mirror_urls=off` 可完全关闭镜像；`mirror_url_list="..."` 可自定义

#### 5. 反挂检查（公平性保障）
- 本地识别作弊工具（GG 修改器、幸运破解器等）与调试残留，**只在本地判定**
- 上报内容：设备码（单向哈希）+ 命中的规则 id，没有任何个人信息
- 设备令牌（首次联系下发一次，服务端只存哈希）防止「知道设备码就伪造封禁」
- 封禁流程：检测 → 3 天宽限（每天提醒一次）→ 上报 → 服务端确认后本地锁定
- 三级限流（IP / 设备码 / expire 频次），v2.8.0 起上报走 POST，令牌不进访问日志

#### 6. 模块自更新
- 每轮巡检对比 GitHub release 与服务端清单，验签后经 `ksud module install` 更新
- 包内版本不低于云端时不打扰（防回滚）

#### 7. WebUI
状态总览、keybox 自检报告、组件管理、一键整改（补丁对齐 / 风险隐藏 / FuseFixer 配置 /
MT 卸载）、配置编辑、日志查看。

### 信任模型

```
上游公开源 ──拉取/校验──▶ 自建服务器 ──Ed25519 签名──▶ GitHub 镜像（Actions 再次验签）
                                 │                            │
                                 └──────── 签名数据 ──────────┴──▶ 客户端（内置公钥验签）
```

- 信任根 = 客户端内置的公钥（`pubkey.b64`）。内容对了才用，跟谁给的无关 ——
  这就是敢用免费公共 CDN 的原因。
- 私钥只在服务器上（`keys/`，不进仓库、不进 web 目录）。
- 镜像 workflow 的公钥固定在仓库变量 `MIRROR_PUBKEY_B64`，不来自服务器响应，
  防「假清单带假公钥」。

### 自建

1. 服务端：`php-server/` 目录（PHP 8 + sodium + zip），把 `public/index.php` 放到
   `api/kernelsu/module/` 下，配好 `config.php`，宝塔/ cron 定时跑 `update.sh`。
2. 客户端：改 `common.sh` / `action.sh` 顶部的 `BASE_URL` 与 `GITHUB_REPO`，
   替换 `pubkey.b64` 为你自己的公钥，然后 `build.ps1` 打包。
3. 镜像：fork 后在仓库 Settings → Variables 配置 `MIRROR_SOURCE` 与
   `MIRROR_PUBKEY_B64`，`.github/workflows/mirror.yml` 即可开始工作。

### 配置（`/data/adb/yypm/config.prop`）

| 键 | 默认 | 说明 |
|---|---|---|
| `auto_fetch` | on | 自动拉取/注入 keybox 总开关 |
| `check_interval` | 3600 | 巡检周期（秒） |
| `net_retry` | 3 | 网络失败重试次数 |
| `anti_cheat` | on | 反挂检查开关 |
| `security_patch` | on | 安全补丁 prop 对齐 |
| `risk_autohide` | on | 风险应用自动隐藏 |
| `abnormal_auto` | on | 异常环境自动清理 |
| `mirror_urls` | on | 去中心化镜像开关 |
| `mirror_url_list` | 内置 | 自定义镜像列表（空格分隔） |

### 免责声明

- 本项目仅供学习与研究。keybox 的分发与使用需自行承担合规责任。
- 因使用本模块导致的任何问题（设备异常、账号封禁、数据丢失）作者不承担责任。
- 公平性封禁（设备号）是本系统对作弊行为的唯一反制手段，范围不会扩大。

---

## English

yypm is a KernelSU module that keeps a **valid, server-signed keybox** installed for
TrickyStore / TEESimulator-RS so the device passes hardware-backed Play Integrity.

**Security statement.** This module does not and *cannot* execute anything remotely.
The server only serves **data**, and every payload (keybox, manifests, module zip,
component packages) is accepted only after an **Ed25519 signature check** against a
public key bundled in the client. There is no command channel in the protocol at all.
For fairness, the worst thing the server can do is **ban a cheating device's code**
(a one-way hash of device properties — not personal info); a banned device simply stops
receiving service from this module. Nothing else on the device is affected.

Highlights:

- keybox fetch → verify (Ed25519 + sha256) → atomic inject, with a local verified pool
  and automatic rollback
- automatic rectification for common integrity-check findings (security-patch prop mode,
  risk-app auto-hiding, FuseFixer/HMA-uidfake auto-install, one-tap LSPosed scoping)
- signed component distribution channel (KSU modules + APKs) with upstream release
  tracking
- decentralized mirrors via GitHub Actions (jsDelivr / raw / release assets) — the
  module keeps working even if the self-hosted server is down or attacked
- local-only anti-cheat scan; reports contain only a device code hash and rule ids
  (device tokens prevent ban forgery; POST-based reporting keeps tokens out of access logs)

Self-hosting: put `php-server/` behind any PHP 8 host, point the client's `BASE_URL`
at it, replace `pubkey.b64`, and optionally configure the `MIRROR_SOURCE` /
`MIRROR_PUBKEY_B64` repository variables to enable the mirror workflow.

Use at your own risk.

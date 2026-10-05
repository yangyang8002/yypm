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
- **对抗逐项开关（v2.8.8）**：对抗页每个可自动化功能都有独立开关 —— **开 = 开机与巡检
  自动执行、切换立即生效；关 = 只留手动按钮**。覆盖：风险应用隐藏 / 异常痕迹清理 /
  安全补丁对齐 / HMA 隐藏配置 / FuseFixer 配置 / 检测前预备 / SUSFS 加固。
  手动按钮不受开关拦截（如「自动配置 HMA」走 force，关了自动照样能手动跑）
- **侧信道延迟自检（v2.8.8/v2.8.9 两路）**：① in-process 对 `stat()` 系统调用计时（每路径 2000 次
  取最优均值），给出基线 vs `/data/adb` 叠层路径的延迟增量 —— 只读测量不写任何东西，
  帮你判断本机侧信道信号强度（同类工具宣称 ~20µs 级）；② `faccessat` vs `fchownat` hook
  计时（v2.8.9，复刻看雪 thread-288928 银行 App 的检测算法：以 App 视角双基准各采
  10000 次、排序逐对比较，异常对 > 7000 判内核 hook 暴露；真机验证 PASS = 未暴露）
  —— 压低手段为内核级（SUSFS 隐藏 + 换带 SUSFS 的新版内核），用户态模块改不了 syscall 路径
- **安全补丁级别**：自动写入 `security_patch.txt`（`system=prop` 模式），attestation
  始终回答系统当前属性值，OTA 后不再出现跨组件日期错位；他人的固定日期文件会被
  备份（`.bak`）后替换，`security_patch=off` 可整体关闭
- **风险应用自动隐藏**：检测到 Scene/Shizuku/NP 管理器等风险应用已安装时，自动并入
  HMA-OSS 查询级隐藏名单（只对检测器隐藏查询结果，应用本体照常可用；
  `risk_autohide=off` 可关）
- **异常痕迹清理（非破坏式）**：只清理空的残留目录；有内容的一律保留并报告，
  绝不自动删除 —— MT 管理器目录的根治办法是去 MT「设置 → 主目录」自行改位置
  （`abnormal_auto=off` 可关）
- **FuseFixer / HMA-OSS**：服务器自动跟踪上游 release，验签后**自动安装**（APK 已装
  判定三级：pm path → pm list → cmd package path）；FuseFixer 的 LSPosed 启用 +
  勾选系统框架由「FuseFixer 自动配置」开关开机自动直写（幂等：只 UPDATE enabled /
  INSERT OR IGNORE scope，写不进如实报错，绝不清库），WebUI 也有手动按钮
- **检测前预备（v2.8.7，v2.8.8 起可开机自动执行；v2.8.9 手动预备带检测窗口守护）**：
  跑检测器前一键收敛到「检测视图
  干净」状态 —— 结束隐藏名单内应用进程 + drop_caches + 非破坏清目录 + 报告已知
  文件痕迹（只报告，绝不删）；
- **检测窗口守护（v2.8.9，只跟手动预备走）**：真机实证根因 —— 隐藏名单里的
  「系统绑定服务」（如无障碍）force-stop 后系统几秒内重绑、应用自家看门狗 ~30 秒
  自启，进程一复活春秋 (2)「隐藏应用列表生效」就漏。守护 = 检测窗口内把隐藏名单
  应用被系统绑定的服务**临时停绑**（原值原子落盘）+ **禁用压死**（pm disable-user，
  看门狗 receiver/service 全哑火）+ 轮询压制（谁复活掐谁）；检测器出现后活满 60 秒
  或退出（连续 3 次落空 + 15 秒宽限）自动**原样恢复**（无障碍原值写回 + pm enable
  解禁，真机验证：春秋报告只剩第 26 项）。安全兜底：检测器 600 秒不来也恢复、
  开机自愈（service.sh）、下次预备自愈；绝不卸载、绝不动用户无障碍开关的最终状态

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
状态总览（启动走本地缓存，秒开 + 版本号常驻）、keybox 自检报告、组件管理、
一键整改（补丁对齐 / 风险隐藏 / FuseFixer 配置 / 检测前预备）、配置编辑、日志查看。
更新检查带 release 说明展示，非镜像更新装完自动提供重启入口。

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
| `security_patch` | on | 安全补丁 prop 对齐（对抗页开关） |
| `risk_autohide` | on | 风险应用自动隐藏（对抗页开关） |
| `abnormal_auto` | on | 异常环境自动清理（对抗页开关） |
| `hma_auto` | on | HMA 隐藏自动配置（对抗页开关；手动按钮走 force 不受限） |
| `ff_lspd_auto` | on | FuseFixer LSPosed 自动配置（v2.8.8） |
| `detect_prep_auto` | on | 检测前预备开机执行（v2.8.8） |
| `susfs_auto` | on | SUSFS 自动加固（v2.8.8） |
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
  query-level risk-app hiding, FuseFixer/HMA-OSS auto-install with 3-tier installed
  detection, pre-check prep that stops/frops/report — never deletes content; cleanup is
  non-destructive by design)
- per-item automation toggles (v2.8.8): every automatable countermeasure has its own
  switch — on = runs at boot + applies immediately on toggle, off = manual buttons only
  (manual actions bypass the auto gate via `force`, so a switch never bricks a button);
  covers risk-app hiding, trace cleanup, security-patch, HMA config, FuseFixer LSPosed
  scoping, pre-check prep and SUSFS hardening
- detection-window guardian (v2.8.9, manual prep only): on-device root cause — hidden
  apps' system-bound services (e.g. accessibility) get rebound by the system within seconds
  after force-stop, and their own watchdogs self-restart in ~30s, so any live process
  resurfaces as detector item (2). The guard temporarily unbinds those services (atomic
  save of the original value), disables those packages (pm disable-user — watchdog
  receivers/services all go quiet), and suppresses any resurrection during the window;
  after the detector runs 60s (or exits, 3-consecutive-miss + 15s grace) it restores
  everything exactly (original accessibility strings written back, packages re-enabled).
  Verified on-device: the detector report drops to only item 26. Boot self-heal included.
- side-channel latency self-check (v2.8.8): in-process `stat()` timing (best-of-3 batches
  × 2000 calls per path) reporting the baseline vs `/data/adb` overlay delta — read-only
  measurement (similar tools advertise ~20µs)
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

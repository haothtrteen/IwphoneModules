# Shell Manager

**简体中文** | [English](README_EN.md)

**免 root 的 Android 模块管理器** —— 不刷机、不解锁 Bootloader，通过系统自带的「无线调试」取得 shell 权限，
再用一套自带运行时 + 沙箱 + 写前快照的框架，来跑各种**免 root 模块**。

> 定位介于 Shizuku / APatch 与模块框架之间：不只是「给 App 提权」，
> 而是提供一套能长期运行、可管理、**可回滚**的模块运行时 —— 并且从配对到部署全程不需要电脑。

---

## 它解决什么问题

Android 上想做系统级调整（省电、性能调度、动画调速、隐私开关），传统路径是 Root + Magisk 模块。
但 Root 门槛高、有风险、影响保修。免 root 方案（Shizuku / APatch）能拿到 shell 权限，
却**没有一个好用的模块生态** —— 脚本散落各处，没有统一的生命周期管理，改坏了也回不去。

本项目把三件事合到一起：

| 能力 | 说明 |
|---|---|
| **自持 adb** | 应用内捆绑 adb 二进制，自己配对、自己连接、自己拉起框架 —— 全程不需要电脑 |
| **模块运行时** | 一套 shell 框架：启停 / 冲突检测 / 沙箱记账 / 配置 / 日志 / 开机自启 |
| **兜底机制** | 写前快照：模块动手前记下原值，App 上一键还原到改动之前 |

---

## 主要功能

### 引导流程（全程手机内完成）

```
① 配对设备        通知栏输入配对码（端口由 mDNS 自动发现，不用手抄）
② 部署框架        App 内置框架包，一键部署 / 修复 / 重置
③ 设置访问密钥    自己设一把密钥（WebUI 鉴权，APatch 式）
   ↓
框架运行 → 装模块 → 管理
```

### 界面

- **主题**：深色 / 浅色 / **跟随系统**（浅色为独立配色，不是简单反色）
- **语言**：简体中文 / English / 跟随系统 —— 覆盖导航、主页、设置、引导、关于
- **首次引导**：三页 —— 这是什么 → 风险告知 → **首次激活向导**
  （活清单：申请通知/存储权限、配对设备、部署框架、设置访问密钥，逐项查真实状态）
- **关于**：项目地址与作者，可一键打开

### 模块管理

- **启停**：常驻模块的守卫循环、锁与进程树管理
- **配置**：模块声明 `config.prop`，App 自动生成配置页；改完最迟一个周期生效
- **动作**：支持 `action.sh`（Magisk 式「动作」按钮）
- **冲突检测**：模块声明独占资源（`settings`/`setprop`/`svc`…），冲突时拒启
- **日志**：框架日志、模块 stdout/stderr、模块自写日志，统一查看
- **安装**：从手机存储导入 `.iwp` / Magisk 式模块 zip，安装前做包内容审计

### 兼容层（Magisk / KernelSU / AxManager 式模块）

这三类框架的模块结构一致（`module.prop` + `service.sh` + `action.sh`），安装时自动适配：

| 原框架概念 | 本框架的处理 |
|---|---|
| `module.prop` | 自动生成等价元信息（含 `runtime=0` 标记常驻） |
| `service.sh` | 生成兼容入口，接到本框架的启动流程 |
| `post-fs-data.sh` | 启动时尽力执行（免 root 无挂载前阶段，语义差异已在文档说明） |
| `action.sh` / `uninstall.sh` | 原样支持 |
| `disable` 旗标 | 兼容入口启动时检查 |
| `MODDIR` / `AXERONDIR` 环境变量 | 自动导出 |
| `webroot/` 每模块 WebUI | 框架按 `/mod/<模块名>/` 提供，App 内 WebView 打开并注入 KernelSU 同构的 `ksu` 桥 |
| BusyBox applet 假设 | 框架自带 BusyBox（358 applet），模块 PATH 优先指向它 |

**明确不支持**：systemless 挂载、Zygisk / 内核类模块、需要 `su` 的模块 —— 这些在免 root 环境物理上做不到。
安装时会**预检**并给出判定（预计兼容 / 需要 Root / 无法判断）与原因。

### 兜底：写前快照与一键还原

免 root 玩机最怕的不是「没效果」，而是**改坏了回不去**。框架在沙箱的写操作拦截点上多了

**一步**：首次写某系统资源前，记录它的原值。

```
$IWPHONE_ROOT/modsnap/<模块名>.snap
settings put global window_animation_scale '1.0'   # [global.window_animation_scale]
```

每行本身就是一条可直接执行的还原命令。App 里点「还原」会先展示清单
（**当前值 → 还原值**），确认后先停模块再还原 —— 常驻模块的守卫循环会把值改回去，
不停模块等于白还原。

**卸载模块不会删除快照**：模块可以卸载，但它改过的设置仍能还原
（设置 → 历史快照，含已卸载模块的「孤儿快照」）。

---

## 架构

```
┌─────────────────────────── App（Flutter + Kotlin）───────────────────────────┐
│  界面：主页 / 模块 / 日志 / 设置                                              │
│  Kotlin 侧：自持 adb · 配对（NSD + 通知输码）· 框架部署 · 开机自启 · WebView   │
└───────────────────────────────────┬──────────────────────────────────────────┘
                    本机 adb（127.0.0.1:5555）
                                    │
┌───────────────────────────────────▼──────────────────────────────────────────┐
│  框架（以 shell 身份运行，/data/local/tmp/iwphone_modrunner_v3_slim）           │
│  守护进程 · 模块锁 · 沙箱（记账 + 写前快照）· 冲突检测 · WebUI（Python 运行时）  │
└───────────────────────────────────┬──────────────────────────────────────────┘
                    模块以 shell 身份运行，沙箱注入其 shell
                                    │
┌───────────────────────────────────▼──────────────────────────────────────────┐
│  模块（work/<模块名>/）：原生 iwphone 模块 / Magisk 式模块（兼容层适配）        │
└──────────────────────────────────────────────────────────────────────────────┘
```

### 三个关键设计

**1. 自持 adb，摆脱电脑**
App 用 `jniLibs` 技巧自带 adb 二进制（避免 `noexec` 限制），密钥存在应用私有目录。
配对用 mDNS 发现配对端口 + 通知栏输入配对码；连接端口固定为 `persist.adb.tcp.port=5555`，
跨重启保持，配合 `BOOT_COMPLETED` + JobScheduler 兜底实现开机自启。

**2. 沙箱两层拦截**
模块对系统配置的写操作用两层拦下来做记账与快照：

| 层 | 拦什么 | 拦不到什么 |
|---|---|---|
| shell 函数包装 | 裸命令名（`settings`、`svc`、`cmd`…） | 走 PATH 解析的写法 |
| PATH 包装脚本（`sbxbin/`） | `env` / `sh -c` / `command` / 变量拼路径 | 绝对路径、native 二进制、`service call` |

拦不到的写法**不会记账、也没有快照** —— 这一点在文档里如实标注，安装预检也会给出提示。

**3. 访问密钥（WebUI 鉴权）**
框架 WebUI 上挂着 `/api/shell`（以 shell 身份执行命令），而它监听 `127.0.0.1` ——
**同设备上任何有网络权限的应用都能访问回环口**。所以：

- 密钥**可选**：不设也能正常用（服务端放行），但回环口对同设备其它应用开放；
  设了才收紧。首次启动时给一次建议性提示，可点「暂不设置」永久关掉
- 密钥由用户自己设（APatch 式，≥8 位），经 `adb push` 下发为 `state/webui_token`（600、shell 属主）
- 服务端按 mtime 读取 → **改密钥不用重启 WebUI**
- App 进程读不到该文件（600），只能经 adb 读写 —— 「拿到密钥」天然依赖「已完成配对」

---

## 目录结构

```
README.md / LICENSE          仓库说明与许可证（GPL-3.0）
framework/                   框架源码（可读、可改、可重新打包）
  ├── Main.sh iwphone.sh     守护进程与命令文件
  ├── core.sh env.sh         模块生命周期 / 全局变量
  ├── sandbox.sh             运行时记账沙箱 + 写前快照
  ├── conflict.sh            独占资源冲突检测
  ├── compat.sh              Magisk / KernelSU / AxManager 兼容层
  ├── mod_install/run/stop   安装、执行、停止
  ├── restore_snapshot.sh    快照还原
  ├── module/                内置模块（.iwp）
  ├── webui/                 内置 WebUI（Python）+ 前端页面
  └── tools/                 运行时构建、framework.bin 打包
lib/                         Flutter 侧
  screens/                   主页 / 模块 / 安装 / 配置 / 快照 / 日志 / 设置 / 终端 / 自启 / 资源
  services/                  WebUI 客户端 · 自启通道 · 密钥管理 · 系统信息 · shell 执行
  widgets/                   通用组件（快照清单、密钥对话框、导航栏…）
  models/ theme/             数据模型与主题
android/app/src/main/kotlin/ Kotlin 侧（10 个文件）
  AdbBootstrap.kt            自持 adb：配对 / 连接 / 固定端口 / 部署框架 / 下发密钥
  AutostartChannel.kt        Flutter ↔ 原生桥（约 30 个方法）
  PairingNsd.kt               mDNS 发现配对端口
  PairingNotify.kt/.Receiver  通知栏输入配对码
  ModuleWebUIActivity.kt     模块自带 WebUI（注入 ksu 桥）
  BootReceiver / AutostartJobService   开机自启与兜底
doc/
  iwphone_module_dev.md      **模块开发指南**（13 章：从最小模块到兼容层、快照、鉴权）
  iwphone_conflict_v1.md     冲突检测设计
android/app/src/main/assets/
  framework.bin             App 内置的框架包（框架脚本 + Python 运行时 + BusyBox，约 14 MB）
                            ⚠ 由 framework/ 打包而来，重新生成：
                              cd framework && sh tools/build_framework_bin.sh
```

---

## 构建

```bash
# 环境：Flutter 3.x + JDK 17/21 + Android SDK
flutter pub get
flutter build apk --release
```

产物在 `build/app/outputs/flutter-apk/app-release.apk`（约 36 MB）。

> **改动了 `framework/` 就要重新打包内置资产**，否则 App 里跑的还是旧框架：
> ```bash
> cd framework && sh tools/build_framework_bin.sh
> ```
> 打包需要 `framework/webui/runtime/`（约 36MB 的 Python 运行时，不入仓库），
> 生成方式见 [framework/README.md](framework/README.md)。

> 应用**零第三方 Flutter 依赖**：文件选择、WebView、通知输入框等都用原生能力实现，
> 减少供应链风险与体积。国内建议先配好 pub / Gradle 镜像。

---

## 已知限制

诚实列出当前边界：

- **绝对路径调用拦不到**：模块若用 `/system/bin/settings …`、native 二进制或 `service call`，
  不会记账、也没有写前快照（安装预检会提示）
- **快照粒度**：`settings` / `appops` 是真实快照；`svc` / `pm` 是「反向动词」推断，不是状态快照
- **兼容性预检是静态扫描**：能提示「可能要 root」，但不能保证；注释里的关键词也会命中（偏保守）
- **不支持 systemless 挂载 / Zygisk / 内核类模块**：免 root 环境物理上做不到
- **i18n 已全量覆盖界面文案**：导航、主页、模块、安装、日志、终端、资源占用、历史快照、
  框架配置、模块配置、开机自启与设置均已提供中英文两套文案；
  框架与 WebUI 返回的运行时消息（如模块 stdout、后端报错原文）仍按原样展示
- **验证覆盖**：核心链路在小米 22011211C（MIUI + Android 14）上验证过；
  其它 ROM / Android 版本（尤其 15/16 的前台服务与无线调试行为）未验证
- **无在线模块仓库**：模块需从手机存储导入，没有在线分发与更新检查

---

## 开发状态

**已验证**（真机端到端跑通）：配对 → 部署框架 → 启停模块 → 配置下发 →
兼容层适配（Magisk 式样例）→ 写前快照生成与一键还原 → 沙箱绕过实测
（7 种写法拦 5 种，绝对路径类拦不到）。

**代码完成、待真机验证**（最近一轮改动，尚未在设备上跑过）：

- 安装前的包内容审计（挡 zip 路径穿越 / 逃逸软链）
- 孤儿快照（卸载保留快照 + 历史快照页）
- WebUI 访问密钥（APatch 式自设密钥）

这三项已通过语法检查与跨文件引用核对，但**没有经过真机验证**，
使用前请自行确认；发现问题欢迎提 Issue。

## Roadmap

- [ ] 沙箱试用：装完真跑 N 秒，用实际写操作结果给出兼容性实证判定（替代纯静态预检）
- [ ] 在线模块仓库与更新检查
- [ ] 快照增强：`svc` / `pm` 改为真实状态快照
- [ ] 多设备 / 多 ROM 兼容性矩阵
- [x] 界面英文化（全部页面文案，见 `lib/i18n/app_strings.dart`）

---

## 许可证

本项目采用 **GNU General Public License v3.0**（见 [LICENSE](LICENSE)）。

选 GPL-3.0 的原因很直接：`assets/framework.bin` 里打包了 **BusyBox**（取自 Magisk 项目，
GPL-3.0），公开分发含 GPL 组件的二进制时有一致的许可要求。与其在混合许可上纠结，
不如整个项目统一到 GPL-3.0 —— 这也是 Magisk 等同类项目的选择。

```
Copyright (C) 2026 haothtrteen

This program is free software: you can redistribute it and/or modify
it under the terms of the GNU General Public License as published by
the Free Software Foundation, either version 3 of the License, or
(at your option) any later version.
```

> 如果你希望自己的代码以更宽松的方式被使用（例如允许闭源集成），
> 可以改成 MIT + 公开构建不含 BusyBox 的方案 —— 具体见 `doc/` 里的说明。

### 第三方组件

| 组件 | 出处 | 许可 |
|---|---|---|
| BusyBox（`framework.bin` 内） | Magisk 项目 | GPL-3.0 |
| adb（`jniLibs/libadb.so`） | AOSP / platform-tools | Apache-2.0 |
| Python 运行时（`framework.bin` 内） | python-build-standalone | PSF License |

### 致敬与参考

- **Magisk** —— BusyBox 二进制、模块格式设计（`module.prop` / `service.sh` / `action.sh`）
- **Shizuku** —— 自持 adb、配对流程、WebUI JS 桥的思路
- **APatch** —— 「用户自设密钥」的鉴权交互
- **KernelSU** —— 模块 WebUI（`webroot/` + `ksu` API）规范
- **AxManager** —— 免 root 插件体系与 BusyBox standalone 模式

## 免责声明

本项目通过 ADB 权限进行系统级操作，**可能影响设备稳定性**。请自行评估风险，
在了解每个模块做什么之后再安装。作者不对设备损坏、数据丢失或保修问题负责。

# Shell Manager v1.2.3

免 root 的 Android 模块管理器：不刷机、不解锁 Bootloader，通过系统自带的无线调试取得 shell 权限，
再用一套自带运行时 + 沙箱 + 写前快照的框架来跑各种免 root 模块。**从配对到部署全程在手机内完成，不需要电脑。**

---

## 安装

- 系统要求：**Android 11 及以上**（无线调试与配对码机制从 11 开始提供）
- 直接安装本页附件里的 `ShellManager-v1.2.3.apk`
- 若提示「未知来源」，请在系统设置里允许该来源安装

首次使用三步（App 内有引导）：

```
① 配对设备    通知栏输入配对码（配对端口由 mDNS 自动发现）
② 部署框架    点一下即可，App 内置框架包
③ 设置访问密钥 自己设一把（至少 8 位），用来挡住同设备其它应用
```

---

## 主要功能

**自持 adb** —— 应用内捆绑 adb，自己配对、自己连接、固定 tcp 端口、开机自启（含 JobScheduler 兜底）。

**模块管理** —— 启停、配置（模块声明 `config.prop` 即自动生成配置页）、动作按钮（`action.sh`）、
冲突检测（独占资源声明）、日志三分离、从手机存储导入安装。

**兼容层** —— Magisk / KernelSU / AxManager 式模块可直接安装：自动适配 `module.prop`、
`service.sh`、`post-fs-data.sh`、`action.sh`、`disable` 旗标、`MODDIR`/`AXERONDIR` 环境变量；
`webroot/` 每模块 WebUI 在 App 内打开并注入 KernelSU 同构的 `ksu` 桥；自带 BusyBox（358 applet）。
安装时会给兼容性**预检**（预计兼容 / 需要 Root / 无法判断）并说明原因。

**写前快照与一键还原** —— 模块**首次写入**某系统资源前自动记录原值，
App 里点「还原」会先展示清单（当前值 → 还原值），确认后先停模块再还原。
**卸载模块不会删快照**，设置 → 历史快照可还原已卸载模块留下的改动。

**安全** —— WebUI 访问密钥（服务端对未设密钥**一律拒绝**）；沙箱两层拦截
（函数包装 + PATH 包装脚本，覆盖 `env`/`sh -c`/`command`/变量拼路径等写法）；
安装前审计包内条目，挡 zip 路径穿越与逃逸符号链接。

---

## 已知限制

- **绝对路径调用拦不到**：模块若用 `/system/bin/settings …`、native 二进制或 `service call`，
  沙箱不记账、也没有写前快照（安装预检会提示）
- **快照粒度**：`settings` / `appops` 是真实快照；`svc` / `pm` 是反向动词推断，不是状态快照
- **不支持** systemless 挂载、Zygisk、内核类模块 —— 免 root 环境物理上做不到
- **兼容性预检是静态扫描**，注释里的关键词也会命中（偏保守）
- 界面文案目前为中文硬编码
- **验证覆盖**：核心链路在小米 22011211C（MIUI + Android 14）上验证过；
  其它 ROM / Android 版本未验证。最近一轮改动（包内容审计、孤儿快照、访问密钥）
  已通过语法检查与真机部署链路验证，但完整交互流程仍在验证中

---

## 风险提示

本项目通过 ADB 权限进行系统级操作，**可能影响设备稳定性**。请自行评估风险，
了解每个模块做什么之后再安装。作者不对设备损坏、数据丢失或保修问题负责。

---

## 开源

- 源码：https://github.com/haothtrteen/IwphoneModules
- 许可证：GPL-3.0（`assets/framework.bin` 内含 BusyBox，取自 Magisk 项目）
- 致谢：Magisk、Shizuku、APatch、KernelSU、AxManager

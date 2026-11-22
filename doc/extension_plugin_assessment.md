# 扩展插件可行性评估（v1.3.34）

起因：用户问「其它 vFlow 功能是不是因为打包进 APK 会变大才没搬？可以考虑做成扩展插件，
需要时运行时从 GitHub 下载、在程序内运行」。

**结论：体积只是次要原因，主要卡点是依赖策略、权限敏感性和「插件没有稳定 ABI」。
可以做扩展插件，但不该照搬 vFlow 的 Kotlin 模块模型；最贴合现有架构的是把 `.iwp`
扩成「动作插件」。本次只做了评估，未实现。**

---

## 1. 为什么没全搬（按权重排序）

| 原因 | 说明 |
|---|---|
| **第三方依赖硬约束** | vFlow 的 OCR 依赖 Google ML Kit（`text-recognition-chinese:16.0.1`），还有 PPOCR 原生库分支。项目约定零第三方依赖，这不是"体积大一点"的问题，是依赖策略本身冲突。 |
| **模块不是独立的** | vFlow 的 171 个模块都继承它的 `BaseModule`，依赖 `ExecutionContext`、`VariableResolver`、`VTypeRegistry`、`AiModuleMetadata` 等一整套自有类型。**单独拷一个文件过来编译不过**，要连执行引擎一起搬。 |
| **权限与审核敏感** | 读通知、短信、位置、悬浮窗、无障碍里的一部分能力，都涉及特殊权限。全塞进主 APK 会让权限面和运行风险显著变大。 |
| **体积** | 纯 Kotlin 模块代码本身只占几百 KB；真正大的是 ML Kit / PPOCR 的模型与 native so（10~30 MB 量级）。所以"体积"是结果，不是根因。 |
| **维护面** | 171 个模块对应 171 套参数、输出、异常与权限组合，全内嵌等于把另一个项目的维护负担接过来。 |

---

## 2. 三种运行时插件方案

### 2.1 Dex / APK 热加载（技术上可行，但不推荐作为第一步）

`DexClassLoader` 可以在运行时加载外部 dex。现实约束：

- Android 10+ 禁止从**可写目录**直接加载 dex；要放进 `codeCacheDir` 之类受保护位置，
  并对文件做严格权限收紧。
- 插件必须实现**我们自己定义的稳定接口**。vFlow 的模块类不适用——它们依赖 vFlow 的
  core 类型，而我们没有那套类型。
- 安全模型必须做对：校验签名或至少 SHA-256 + 可信来源，**否则等于给任意代码开了
  一个"用 Shell Manager 身份执行"的入口**。而本 App 持有 adb 配对、WebUI token、授权表，
  这个身份价值很高。
- 一旦加载进来就是同进程代码，权限边界为零；插件崩溃会拖垮主进程。

能做，但要先定义 ABI、签名校验、版本兼容、沙箱边界。不是"下载个 dex 调一下"的事。

### 2.2 Lua / JS 脚本插件

vFlow 自己有 `JsModule` / `LuaModule`，靠 Rhino / LuaJ 这类第三方引擎。
引入引擎就破了零依赖约束；自己写一个够用的解释器，工作量不比正经插件框架小。
**不建议。**

### 2.3 把 `.iwp` 扩展成动作插件（推荐）

我们已经有一套模块分发机制，顺着它扩展成本最低：

```
.iwp
├── iwphone.prop          # 元信息
├── main.sh               # 已有：模块生命周期
├── automation.json       # 已有：模块自带的自动化流程
└── actions.json          # 新增：本模块提供哪些动作 + 参数 schema
```

工作流引擎遇到未知 `moduleId` 时，不再直接报"未知模块"，而是查模块目录里的
`actions.json`，把步骤派发给该模块：

- **shell 型动作**：模块脚本自己实现（例如 `action_image_ocr.sh`），走框架 `/api/shell`，
  和现有 `module.run` 同一条链路；
- **App 型动作**：模块声明需要的能力（`ui.text` / `notification.read` 等），
  由 App 内置的处理器执行 —— 这样插件不用碰 Android API，也就不存在同进程任意代码问题。

好处：
1. 完全复用已有的下载/安装/卸载/只读标记机制（`AdbBootstrap.importPackageBytes`）；
2. 插件是 shell 脚本 + JSON，不需要动态加载代码，安全风险大幅降低；
3. 用户能在「模块」页看到装了什么、随时卸掉；
4. 与「自动化可打包成 iwphone 模块」的设计一脉相承。

代价：插件不能做需要新 Android 权限的事（那些必须内嵌或做成伴生 App）。

### 2.4 伴生 App

重能力（OCR、读短信等）做成独立 App，通过我们已有的 `BrokerProvider` / `BrokerShell`
提供受控能力。隔离最好，但要用户多装一个 App，且授权链路更长。

---

## 3. 从 GitHub 运行时下载：可行，但有两个现实问题

技术上没问题：`HttpClient` / `HttpURLConnection` 拉 `actions.json` 与包体到 `filesDir`，
校验 SHA-256，再走现有安装链路。

现实问题：

1. **网络可达性**：`raw.githubusercontent.com` 在国内经常很慢或不稳定，
   GitHub Release 附件基本下不动（此前实测过）。要么配镜像，要么把模块索引放 CDN。
   但走第三方镜像又引入"镜像篡改"的信任问题——所以**哈希校验不能省**。
2. **必须用户确认**：安装外部模块属于高危操作，沿用现有 `showConfirmDialog`，
   明确告诉用户"将安装来自 <来源> 的模块，它提供 N 个动作"。
   不能后台静默下载就装上。

建议的索引格式（最小）：

```json
{
  "schema": 1,
  "actions": [
    {
      "id": "ext.image.ocr",
      "name": "图片 OCR",
      "version": 1,
      "sha256": "…",
      "url": "https://…/ocr-1.iwp",
      "capabilities": ["shell"],
      "risk": "normal"
    }
  ]
}
```

`capabilities` 只声明"要什么能力"，不声明"能拿到什么权限"；App 侧白名单校验，
不在白名单的声明直接拒绝安装。

---

## 4. 建议的推进顺序

1. **现在**：4 个轻量动作内嵌（已完成，见 `plugin_system_rollout.md §10.9`）。
2. **下一步**：扩展 `.iwp` 支持 `actions.json`，先支持 shell 型动作；
   加模块索引 + 哈希校验 + 用户确认。
3. **再往后**：如果确实需要同进程 Kotlin 插件，再定义稳定 ABI 与签名校验，
   并对齐 Android 10+ 的 dex 加载限制。
4. **重能力**：走伴生 App 或外部 OCR 二进制，单独评估。

在此之前，"下载即运行任意 dex"不做 —— 本 App 的身份太敏感，风险收益不成比例。

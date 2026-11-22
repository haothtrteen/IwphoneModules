# 模块携带自动化（automation.json）

> 一句话：在 `.iwp` 包里放一份 `automation.json`，模块装好后它的自动化流程就直接出现在
> App 的「自动化」页里 —— 不用改代码、不用额外安装步骤、旧模块完全不受影响。

## 1. 为什么放在模块包里

`mod_install.sh` 是**整包 `unzip`** 到 `work/<模块名>/` 的，所以包里任何文件装完就已经
在模块目录里了。App 只需要读 `work/*/automation.json`，不需要为了自动化单独设计安装协议，
也不会出现「模块装了、自动化没装」这种半截状态。

模块被卸载 → 目录消失 → 自动化自然也跟着消失，不会留下孤儿配置。

## 2. 包结构

```
my_module.iwp                (zip)
├── iwphone.prop             必需：模块元信息
├── main.sh                  入口（纯自动化模块可以只 echo 一行就 exit 0）
└── automation.json          可选：本文档描述的内容
```

`automation.json` 缺失时一切照旧 —— 这是**纯增量约定**，老模块不需要任何改动。

## 3. automation.json 格式

```json
{
  "schema": 1,
  "name": "示例模块",
  "workflows": [
    {
      "id": "wifi_off_in_settings",
      "name": "进设置页后关 WiFi",
      "trigger": "window_change",
      "stopOnError": true,
      "steps": [
        { "moduleId": "adb.tap", "params": { "x": 540, "y": 1180 } },
        { "moduleId": "logic.delay", "params": { "ms": 600 } },
        { "moduleId": "adb.key", "params": { "code": 3 } }
      ]
    }
  ]
}
```

| 字段 | 必填 | 说明 |
|---|---|---|
| `schema` | 否 | 目前只有 1，留给未来结构变更 |
| `name` | 否 | 展示用名字，App 里显示的是模块名 |
| `workflows[]` | 是 | 流程数组；也接受顶层直接写数组 |
| `workflows[].id` | 是 | 模块内唯一即可，App 侧会拼成 `m_<模块名>_<id>` 保证全局唯一 |
| `workflows[].name` | 否 | 缺省用 id |
| `workflows[].trigger` | 否 | 见第 4 节，缺省 `manual` |
| `workflows[].stopOnError` | 否 | 缺省 `true`：某步失败就停 |
| `workflows[].steps[]` | 是 | 见第 5 节 |

## 4. trigger：什么时候执行

这里是**人话到事件**的映射，写 key 就行，不要写 `monitor:framework@STOPPED` 这类原始过滤器。

| key | 含义 | 依赖 |
|---|---|---|
| `manual` | 不自动触发，用户在页面点「运行」 | 无 |
| `framework_down` | iwphone 守护进程掉线 / 崩溃 / 未启动 | 框架监视器 |
| `framework_up` | 守护进程重新拉起成功 | 框架监视器 |
| `adb_down` | 自持 adb 通道断开 | adb 监视器 |
| `module_exit` | 任一模块进程消失（事件 `reason` 带模块名） | 模块监视器 |
| `window_change` | 前台界面切换（**任意**应用） | **无障碍服务** |
| `a11y_ready` | 无障碍服务被系统重新绑定 | **无障碍服务** |
| `app_foreground:<包名>` | **指定应用**进入前台 | **无障碍服务** |
| `notif_post:<包名>` | **指定应用**发出通知 | **通知使用权** |

应用级触发器说明：

- 包名留空表示任意应用（`notif_post:` = 任何通知）；
- 指定包名时按**精确匹配**，`notif_post:com.a` 不会命中 `notif:com.abc`；
- 同一应用内部切页面、弹对话框不算「到前台」（包名没变）；
- 常驻通知（音乐、下载、前台服务）与分组摘要不算「来了通知」，
  同一个包 1.5 秒内的重复回调会被合并 —— 否则一条微信能触发好几次；
- 两项权限都是系统级 SPECIAL 权限，用户得手动开：
  设置 → 无障碍 / 设置 → 通知使用权。没开时触发器**静默不触发**，
  App 的自动化页会在用到时给出提示条。

未登记的 key 会被当成裸事件前缀处理（`e.id.startsWith(key)`），留给实验性用法；
正式发布请用上表的 key。

> 触发器只是「候选」。用户必须在 App 里**武装**这个流程，它才会真正挂上监听 ——
> 装个模块不能悄悄让手机开始自己点屏幕。

## 5. steps：做什么

`moduleId` 与 App 可视化编辑器里的积木一一对应（`lib/services/module_catalog.dart`）：

| moduleId | 参数 | 说明 |
|---|---|---|
| `adb.tap` | `x`, `y` | 点击坐标 |
| `adb.swipe` | `x1`,`y1`,`x2`,`y2`,`duration` | 滑动 |
| `adb.text` | `text` | 输入文本（空格写 `%s`） |
| `adb.key` | `code` | 按键，4=返回 3=Home 26=电源 |
| `adb.start` | `package` | 启动应用 |
| `adb.stop` | `package` | 强制停止应用 |
| `adb.screencap` | `path` | 截图到 `/sdcard/...` |
| `adb.raw` | `cmd` | 原始 shell 命令（高危，用户侧二次确认） |
| `module.run` | `module`, `op` | 启停其它模块（`run`/`stop`/`install`/`uninstall`） |
| `logic.delay` | `ms` | 等待，上限 60 秒 |
| `flow.run` | `workflow` | 调用另一个流程（递归上限 6 层） |
| `system.toast` | `message` | 弹出一条短提示 |
| `ui.text` | `filter`, `max` | 读取当前界面控件文字，`filter` 是正则、留空=全部 |
| `ui.find` | `text`, `viewId`, `match`, `click`, `max` | 按文字/控件 ID 查找；`click=true` 时点中心点 |
| `ui.waitText` | `text`, `viewId`, `match`, `appear`, `timeoutMs`, `intervalMs` | 轮询等待文字出现/消失 |

所有 `adb.*` 动作都走 `input` / `am` / `screencap`，**不依赖无障碍**。
`ui.*` 三个动作依赖**无障碍服务已开启**（系统设置 → 无障碍 → Shell Manager），
没开时步骤直接返回失败原因，不会静默跳过。

`match` 支持 `contains`（默认，忽略大小写）/ `exact` / `starts_with` / `regex`。
`ui.*` 读的是**无障碍控件树上的文字**（text / content-desc / view-id），
不是 OCR——Canvas 绘制、图片、验证码这类像素文字读不到。这是零第三方依赖下的明确边界。

## 6. 只读与归属

模块带来的流程在 App 里标为只读：

- 不能就地编辑 —— 改了下次更新模块就被覆盖，用户会以为改动丢了；
- 可以「复制为我的一份」，转成本地工作流后随意改；
- 可以武装 / 运行 / 解除。

## 7. 从 App 反向导出

自动化页 →「可视化工作流」→ 任一流程 → 菜单「导出为模块」：

```
iwphone.prop   PackageName=<名字> / version / versionCode / author / description
main.sh        echo 一行后 exit 0（无常年驻进程）
automation.json 该流程
README.txt
```

生成的 `.iwp` 推到设备的 `/data/local/tmp/iwphone/module/`，到「模块」页安装即可。

## 8. 安全边界

- 模块**不能**自己武装自己 —— 必须由用户在 App 里点；
- `adb.raw` 属高危动作，用户在编辑器里添加时会被要求确认；
- `exclusive=` 冲突声明仍由 `mod_install.sh` 静态提取，与自动化无关；
- 自动化执行走单线程队列，同一时刻只有一个流程在跑，不会出现两套点击交叉。

## 9. 验证要点

1. `unzip -l my_module.iwp` 确认 `automation.json` 在包根目录（不要套一层文件夹）；
2. 安装后 `cat /data/local/tmp/iwphone/work/<模块>/automation.json` 能看到内容；
3. App 自动化页出现该流程，来源显示 `iwphone 模块 · <模块>`；
4. 武装后把触发条件制造出来（例如停掉框架），看流程是否执行、事件流里是否留痕；
5. JSON 写错时 App 会在该区域显示「解析失败」，不会静默吞掉。

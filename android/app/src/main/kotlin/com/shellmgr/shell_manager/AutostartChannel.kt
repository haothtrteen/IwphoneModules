package com.shellmgr.shell_manager

import android.content.Intent
import android.net.Uri
import android.os.Build
import android.provider.Settings
import androidx.core.app.ActivityCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel

/**
 * 「开机自启」的 Flutter ↔ 原生桥。
 *
 * 与既有的 `shellmgr/storage` 通道独立，职责单一。
 *
 * ## 线程注意
 *
 * MethodChannel 的 handler 默认跑在**平台主线程**上。而本通道的大多数操作
 * （配对、固定端口、执行一次自启）都要起 adb 进程并等它返回，耗时可达数秒 ——
 * 直接在主线程做会卡住 UI，甚至触发 ANR。
 *
 * 因此凡涉及 adb 的调用一律丢到后台线程，完成后再回调 [MethodChannel.Result]。
 * MethodChannel 的结果回调允许从任意线程调用。
 */
class AutostartChannel(private val activity: FlutterActivity) {

    companion object {
        const val CHANNEL = "shellmgr/autostart"
        const val REQ_NOTIFY = 1002

        // MIUI / HyperOS 的自启动管理页；不同版本 action 不同，逐个尝试
        private val MIUI_AUTOSTART_ACTIONS = listOf(
            "miui.intent.action.OP_AUTO_START",
            "miui.intent.action.APP_PERM_EDITOR",
        )
    }

    /** 通知权限申请的挂起结果（等 onRequestPermissionsResult 回填）。 */
    private var pendingNotifyResult: MethodChannel.Result? = null

    fun register(messenger: BinaryMessenger) {
        MethodChannel(messenger, CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "getStatus" -> result.success(status())

                "frameworkInstalled" -> runAsync(result) {
                    mapOf("installed" to AdbBootstrap.isFrameworkInstalled(activity))
                }

                // 部署/修复框架：推送内置包并解压。耗时可达一两分钟（12MB 传输 + 解压），
                // 必须在后台线程；界面侧应有明确的「进行中」提示。
                "deployFramework" -> runAsync(result) {
                    val r = AdbBootstrap.deployFramework(activity)
                    mapOf("ok" to r.ok, "msg" to r.message)
                }

                // 完全卸载（adb 直连备用通道）：WebUI 不可用时由这里执行 uninstall.sh。
                // 脚本会先停守护与模块再删目录，耗时可达数十秒，必须走后台线程。
                "uninstallFramework" -> runAsync(result) {
                    val r = AdbBootstrap.uninstallFramework(activity)
                    mapOf("ok" to r.ok, "msg" to r.message)
                }

                "setEnabled" -> {
                    val v = call.argument<Boolean>("value") ?: false
                    AutostartPrefs.setEnabled(activity, v)
                    // 打开开关时顺手把任务排上，用户在本次开机内就能看到效果
                    if (v) AutostartScheduler.schedule(activity, delayMs = 0L)
                    result.success(mapOf("ok" to true))
                }

                "requestNotification" -> requestNotification(result)

                "pair" -> {
                    val port = call.argument<String>("port") ?: ""
                    val code = call.argument<String>("code") ?: ""
                    runAsync(result) {
                        val r = AdbBootstrap.pair(activity, port, code)
                        mapOf("ok" to r.ok, "msg" to r.message)
                    }
                }

                "ensurePort" -> runAsync(result) {
                    val r = AdbBootstrap.ensureFixedPort(activity)
                    mapOf("ok" to r.ok, "msg" to r.message)
                }

                "runNow" -> runAsync(result) {
                    val r = AdbBootstrap.startFramework(activity)
                    if (!r.skipped) AutostartPrefs.recordResult(activity, r.ok, r.message)
                    mapOf(
                        "ok" to r.ok,
                        "msg" to r.message,
                        "skipped" to r.skipped,
                    )
                }

                "openAutostartSettings" -> result.success(openAutostartSettings())

                // 配对流程入口：请求通知权限（若未授予）→ 发出「输入配对码」通知。
                // 端口不用用户填 —— 用户提交配对码时再用 mDNS 扫（那时配对界面必然开着）。
                "startPairingFlow" -> {
                    val granted = AutostartNotify.hasPermission(activity) ||
                        Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU
                    if (!granted) {
                        // 让 Dart 侧先走通知权限申请，用户授权后再来一次
                        result.success(mapOf("ok" to false, "needPermission" to true))
                    } else {
                        PairingNotify.postWaiting(activity)
                        result.success(mapOf("ok" to true, "needPermission" to false))
                    }
                }

                // 打开系统的开发者选项页（用户在这里开无线调试、拿配对码）
                "openWirelessDebug" -> result.success(openWirelessDebug())

                // 把 App 缓存里的模块包导入设备 module/ 目录（自服务安装的传输环节）
                "importPackage" -> runAsync(result) {
                    val path = call.argument<String>("path") ?: ""
                    val name = call.argument<String>("name") ?: ""
                    val r = AdbBootstrap.importPackage(activity, path, name)
                    mapOf("ok" to r.ok, "msg" to r.message)
                }

                // ---- 界面偏好：主题 / 语言 / 首次引导 ----
                "loadUiPrefs" -> result.success(UiPrefs.snapshot(activity))

                "saveUiPrefs" -> {
                    call.argument<String>("themeMode")?.let { UiPrefs.setThemeMode(activity, it) }
                    call.argument<String>("locale")?.let { UiPrefs.setLocale(activity, it) }
                    call.argument<Boolean>("onboardingDone")?.let {
                        UiPrefs.setOnboardingDone(activity, it)
                    }
                    call.argument<Boolean>("tokenPromptDismissed")?.let {
                        UiPrefs.setTokenPromptDismissed(activity, it)
                    }
                    result.success(UiPrefs.snapshot(activity))
                }

                // 打开外部链接（关于页的项目地址用）。
                // 刻意不走 url_launcher —— 项目约定零第三方依赖，一个 Intent 就够。
                "openUrl" -> {
                    val url = call.argument<String>("url") ?: ""
                    result.success(openUrl(url))
                }

                // ---- WebUI 访问密钥（APatch 式：用户自己设）----
                // 设备上是否已设密钥（决定 WebUI 现在能不能用）
                "webuiTokenSet" -> runAsync(result) {
                    mapOf("set" to AdbBootstrap.isWebuiTokenSet(activity))
                }
                // 设置密钥：校验 → 暂存 → push 到设备 → 600 → 复核；成功同时存本地
                "setWebuiToken" -> runAsync(result) {
                    val token = call.argument<String>("token") ?: ""
                    val r = AdbBootstrap.setWebuiToken(activity, token)
                    if (r.ok) AutostartPrefs.setWebuiToken(activity, token.trim())
                    mapOf("ok" to r.ok, "msg" to r.message)
                }
                // App 本地缓存的密钥（启动时用来配 HTTP 客户端的 X-Token）
                "loadWebuiToken" -> result.success(
                    mapOf("token" to AutostartPrefs.webuiToken(activity)),
                )
                "clearWebuiToken" -> {
                    AutostartPrefs.setWebuiToken(activity, "")
                    result.success(mapOf("ok" to true))
                }

                // 打开模块自带 WebUI（KernelSU 式 webroot，App 内 WebView 展示）
                "openModuleWebUI" -> {
                    val name = call.argument<String>("name") ?: ""
                    val url = "http://127.0.0.1:8537/mod/" +
                        java.net.URLEncoder.encode(name, "UTF-8") + "/index.html"
                    try {
                        activity.startActivity(
                            Intent(activity, ModuleWebUIActivity::class.java).apply {
                                putExtra(ModuleWebUIActivity.EXTRA_MODULE, name)
                                putExtra(ModuleWebUIActivity.EXTRA_URL, url)
                                // 页面本身也要过鉴权：带上密钥（查询串 + 桥里的头）
                                putExtra(
                                    ModuleWebUIActivity.EXTRA_TOKEN,
                                    AutostartPrefs.webuiToken(activity),
                                )
                            },
                        )
                        result.success(mapOf("ok" to true))
                    } catch (e: Exception) {
                        result.success(mapOf("ok" to false, "msg" to e.message))
                    }
                }

                "openAutostartSettings" -> result.success(openAutostartSettings())

                else -> result.notImplemented()
            }
        }
    }

    // ---------------- 各方法实现 ----------------

    /** 当前状态快照，供设置页一次性渲染。 */
    private fun status(): Map<String, Any?> {
        val last = AutostartPrefs.lastResult(activity)
        return mapOf(
            "enabled" to AutostartPrefs.isEnabled(activity),
            "provisioned" to AdbBootstrap.isProvisioned(activity),
            "notifyGranted" to AutostartNotify.hasPermission(activity),
            "lastTime" to (last?.first ?: 0L),
            "lastOk" to (last?.second ?: false),
            "lastMsg" to (last?.third ?: ""),
            "port" to AdbBootstrap.CONNECT_PORT,
            "portFixed" to AdbBootstrap.isPortFixed(activity),
            "frameDir" to AdbBootstrap.FRAME_DIR,
        )
    }

    private fun requestNotification(result: MethodChannel.Result) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) {
            // 13 以下无需运行时申请
            result.success(true)
            return
        }
        if (AutostartNotify.hasPermission(activity)) {
            result.success(true)
            return
        }
        pendingNotifyResult = result
        ActivityCompat.requestPermissions(
            activity,
            arrayOf(android.Manifest.permission.POST_NOTIFICATIONS),
            REQ_NOTIFY,
        )
    }

    /** 打开系统的开发者选项页（无线调试入口在这里）。 */
    private fun openWirelessDebug(): Boolean = try {
        activity.startActivity(
            Intent(Settings.ACTION_APPLICATION_DEVELOPMENT_SETTINGS).apply {
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            },
        )
        true
    } catch (_: Exception) {
        false
    }

    /**
     * 跳系统的「自启动管理」。
     *
     * MIUI/HyperOS 默认**拦截 BOOT_COMPLETED**，不开这个权限的话
     * 广播收不到、自启必然失效 —— 且没有任何报错，用户只会觉得「没生效」。
     * 所以这里主动把用户送到设置页，而不是让他自己找。
     */
    private fun openAutostartSettings(): Boolean {        val pkg = activity.packageName

        for (action in MIUI_AUTOSTART_ACTIONS) {
            try {
                activity.startActivity(
                    Intent(action).apply {
                        setPackage("com.miui.securitycenter")
                        putExtra("extra_pkgname", pkg)
                        addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                    },
                )
                return true
            } catch (_: Exception) {
                // 换下一个 action
            }
        }

        // 兜底：应用详情页（用户可在这里找到「自启动」入口）
        return try {
            activity.startActivity(
                Intent(
                    Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
                    android.net.Uri.parse("package:$pkg"),
                ),
            )
            true
        } catch (_: Exception) {
            false
        }
    }

    // ---------------- 工具 ----------------

    /** 把耗时调用丢到后台线程，完成后回填结果。 */
    private fun runAsync(
        result: MethodChannel.Result,
        block: () -> Map<String, Any?>,
    ) {
        Thread {
            val payload = try {
                block()
            } catch (e: Exception) {
                mapOf(
                    "ok" to false,
                    "msg" to "未预期异常：${e.javaClass.simpleName}: ${e.message}",
                )
            }
            // Result 回调可从任意线程调用
            result.success(payload)
        }.start()
    }

    /** 由 MainActivity 转发；返回 true 表示已消费该次回调。 */
    fun onRequestPermissionsResult(
        requestCode: Int,
        grantResults: IntArray,
    ): Boolean {
        if (requestCode != REQ_NOTIFY) return false
        val granted = grantResults.isNotEmpty() &&
            grantResults[0] == android.content.pm.PackageManager.PERMISSION_GRANTED
        pendingNotifyResult?.success(granted)
        pendingNotifyResult = null
        return true
    }

    /**
     * 用系统浏览器打开链接。
     *
     * 只放行 http/https —— 这是从 UI 传进来的字符串，虽然当前来源可信，
     * 但限制 scheme 能避免以后有人不小心把 file:// 之类传进来。
     */
    private fun openUrl(url: String): Boolean {
        if (!url.startsWith("https://") && !url.startsWith("http://")) return false
        return try {
            val intent = Intent(Intent.ACTION_VIEW, Uri.parse(url)).apply {
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            }
            activity.startActivity(intent)
            true
        } catch (_: Exception) {
            false
        }
    }
}

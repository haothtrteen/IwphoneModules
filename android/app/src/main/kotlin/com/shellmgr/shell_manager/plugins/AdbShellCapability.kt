package com.shellmgr.shell_manager.plugins

import android.content.Context
import com.shellmgr.shell_manager.AdbBootstrap

/**
 * adb shell 执行模式（不依赖无障碍）。
 *
 * 把常用 UI 操作封装成命名方法，底层全部走 `adb shell input/am/screencap`，
 * 由已配对的 shell(2000) 执行 —— 与 AccessibilityCapability 完全独立：
 * - 无需用户在系统设置里开启无障碍服务；
 * - 不受无障碍保活 / ROM 限制影响；
 * - 代价：只能操作当前前台界面，不能像无障碍那样读 UI 节点树做内容匹配。
 *
 * action 格式：`adb:<方法> <参数>`，例如
 *   adb:tap 500 1000
 *   adb:swipe 500 1500 500 500 300
 *   adb:text hello
 *   adb:key 4
 *   adb:start com.termux
 *   adb:screencap /sdcard/iwphone/shot.png
 */
class AdbShellCapability : Capability {
    override val id = "adb_shell"
    override val displayName = "adb shell 模式"

    override fun availability(ctx: Context): Availability {
        if (!AdbBootstrap.isProvisioned(ctx)) return Availability.NEED_GRANT
        return if (AdbBootstrap.probeTransportAlive(ctx)) {
            Availability.AVAILABLE
        } else {
            Availability.NEED_GRANT
        }
    }

    override fun getRequiredPermissions(req: ActionRequest?): List<PermissionSpec> =
        listOf(PermissionSpec(
            id = "shell",
            type = PermissionType.SPECIAL,
            description = "需完成 adb 配对（shell 权限），无需无障碍",
        ))

    override fun execute(ctx: Context, req: ActionRequest): ActionResult {
        val d = PermissionGateway.check(ctx, this, req)
        if (!d.allowed) return ActionResult(false, d.reason)

        val raw = req.args["cmd"] ?: req.action
        val cmd = buildCommand(raw) ?: return ActionResult(false, "不支持的 adb 动作: $raw")
        val r = AdbBootstrap.run(
            ctx,
            listOf("-s", AdbBootstrap.currentTarget(), "shell", cmd),
            timeoutMs = req.timeoutMs,
        )
        return ActionResult(
            ok = r.ok,
            message = r.message,
            data = mapOf("cmd" to cmd, "code" to if (r.ok) "OK" else "ERROR"),
        )
    }

    /**
     * 把命名动作翻译成 shell 命令。
     * 参数做白名单校验（数字 / 包名 / 路径），避免注入任意命令：
     * 高危的 raw 命令必须显式用 shell: 前缀（走 ShellCapability 的 highRisk 流程）。
     */
    fun buildCommand(raw: String): String? {
        val parts = raw.trim().split(Regex("\\s+"))
        if (parts.isEmpty()) return null
        val method = parts[0].removePrefix("adb:")
        val args = parts.drop(1)
        return when (method) {
            "tap" -> if (args.size == 2 && args.all { it.isInt() })
                "input tap ${args[0]} ${args[1]}" else null
            "swipe" -> if (args.size == 4 && args.all { it.isInt() })
                "input swipe ${args[0]} ${args[1]} ${args[2]} ${args[3]}" else null
            "swipeDuration" -> if (args.size == 5 && args.all { it.isInt() })
                "input swipe ${args[0]} ${args[1]} ${args[2]} ${args[3]} ${args[4]}" else null
            "text" -> if (args.isNotEmpty())
                "input text ${args.joinToString(" ")}" else null
            "key" -> if (args.size == 1 && args[0].isInt())
                "input keyevent ${args[0]}" else null
            "start" -> if (args.size == 1 && args[0].isPackage())
                "am start -n ${args[0]}/.MainActivity" else null
            "startService" -> if (args.size == 1 && args[0].isPackage())
                "am startservice -n ${args[0]}/.MainService" else null
            "stop" -> if (args.size == 1 && args[0].isPackage())
                "am force-stop ${args[0]}" else null
            "screencap" -> if (args.size == 1 && args[0].isSafePath())
                "screencap -p ${args[0]}" else null
            "input" -> if (args.isNotEmpty())
                "input ${args.joinToString(" ")}" else null
            else -> null
        }
    }

    private fun String.isInt(): Boolean = toIntOrNull() != null
    private fun String.isPackage(): Boolean = matches(Regex("[A-Za-z0-9_.]+"))
    private fun String.isSafePath(): Boolean =
        matches(Regex("(/sdcard|/data/local/tmp)/[A-Za-z0-9_./-]+"))

    companion object {
        /** 供 AutomationRegistry 判断是否走 adb 模式。 */
        const val PREFIX = "adb:"
    }
}

package com.shellmgr.shell_manager.plugins

import android.content.Context
import com.shellmgr.shell_manager.AdbBootstrap
import org.json.JSONObject

/**
 * shell 能力：复用现有 AdbBootstrap 的 adb 通道执行 shell 命令。
 *
 * 这是 C1 能力，所有高危动作要求二次确认（highRisk=true），
 * 判定由 PermissionGateway 统一处理，执行走已有的 AdbBootstrap.run。
 */
class ShellCapability : Capability {
    override val id = "shell"
    override val displayName = "Shell（adb 配对）"

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
            description = "需完成 adb 配对并保持连接",
        ))

    override fun execute(ctx: Context, req: ActionRequest): ActionResult {
        val decision = PermissionGateway.check(ctx, this, req)
        if (!decision.allowed) return ActionResult(false, decision.reason)
        // needUserConfirm 由调用方（UI / 自动化执行器）负责弹窗，这里不自行弹
        if (decision.needUserConfirm && req.highRisk) {
            return ActionResult(false, "HIGH_RISK_NEED_CONFIRM")
        }

        val cmd = req.args["cmd"] ?: return ActionResult(false, "缺少 cmd 参数")
        if (cmd.length > 4096) return ActionResult(false, "命令过长")
        val r = AdbBootstrap.run(
            ctx,
            listOf("-s", AdbBootstrap.currentTarget(), "shell", cmd),
            timeoutMs = req.timeoutMs,
        )
        return ActionResult(
            ok = r.ok,
            message = r.message,
            data = mapOf("code" to if (r.ok) "OK" else "ERROR"),
        )
    }
}

/** 只读能力：探测 WebUI 是否在线（不做任何写操作）。 */
class WebUiCapability : Capability {
    override val id = "webui"
    override val displayName = "框架 WebUI"

    override fun availability(ctx: Context): Availability {
        val token = com.shellmgr.shell_manager.AutostartPrefs.webuiToken(ctx)
        if (token.isEmpty()) return Availability.NEED_GRANT
        return Availability.AVAILABLE
    }

    override fun getRequiredPermissions(req: ActionRequest?): List<PermissionSpec> =
        listOf(PermissionSpec(
            id = "webui_token",
            type = PermissionType.SPECIAL,
            description = "需设置 WebUI 访问密钥",
        ))

    override fun execute(ctx: Context, req: ActionRequest): ActionResult {
        val decision = PermissionGateway.check(ctx, this, req)
        if (!decision.allowed) return ActionResult(false, decision.reason)
        return ActionResult(true, "webui token ready")
    }
}

/** 无障碍能力（C2）：事件监听已实现，用户手动开启后生效。 */
class AccessibilityCapability : Capability {
    override val id = "accessibility"
    override val displayName = "无障碍服务"

    override fun availability(ctx: Context): Availability =
        if (IwphoneAccessibilityService.isEnabled(ctx)) Availability.AVAILABLE
        else Availability.NEED_GRANT

    override fun getRequiredPermissions(req: ActionRequest?): List<PermissionSpec> =
        listOf(PermissionSpec(
            id = "overlay",
            type = PermissionType.SPECIAL,
            description = "系统设置 → 无障碍 → 已安装服务 → 开启",
            runtimePermissions = listOf(android.Manifest.permission.BIND_ACCESSIBILITY_SERVICE),
        ))

    override fun execute(ctx: Context, req: ActionRequest): ActionResult {
        val d = PermissionGateway.check(ctx, this, req)
        return if (d.allowed) ActionResult(true, "accessibility ready") else ActionResult(false, d.reason)
    }
}

/** 通知使用权（C2 的另一半）：只读通知内容，用于「某应用发通知」触发器。 */
class NotificationCapability : Capability {
    override val id = "notification"
    override val displayName = "通知使用权"

    override fun availability(ctx: Context): Availability =
        if (IwphoneNotificationListener.isEnabled(ctx)) Availability.AVAILABLE
        else Availability.NEED_GRANT

    override fun getRequiredPermissions(req: ActionRequest?): List<PermissionSpec> =
        listOf(PermissionSpec(
            id = "notification_listener",
            type = PermissionType.SPECIAL,
            description = "系统设置 → 通知使用权 → 允许 IWPhone",
        ))

    override fun execute(ctx: Context, req: ActionRequest): ActionResult {
        val d = PermissionGateway.check(ctx, this, req)
        return if (d.allowed) ActionResult(true, "notification access ready")
        else ActionResult(false, d.reason)
    }
}

/** 外部依赖能力：Shizuku 只探测与引导，不引入客户端库。 */
class ShizukuCapability : Capability {
    override val id = "shizuku"
    override val displayName = "Shizuku（可选）"

    override fun availability(ctx: Context): Availability {
        val installed = try {
            ctx.packageManager.getPackageInfo("moe.shizuku.privileged.api", 0) != null
        } catch (_: Exception) {
            false
        }
        return if (installed) Availability.AVAILABLE else Availability.EXTERNAL_DEP
    }

    override fun getRequiredPermissions(req: ActionRequest?): List<PermissionSpec> = emptyList()
    override fun execute(ctx: Context, req: ActionRequest): ActionResult =
        ActionResult(false, "Shizuku 仅为可选外部依赖，当前未启用")
}

/** 能力注册表。 */
class CapabilityRegistry {
    private val items = LinkedHashMap<String, Capability>()

    fun register(c: Capability) {
        if (!items.containsKey(c.id)) items[c.id] = c
    }

    fun get(id: String): Capability? = items[id]
    fun all(): List<Capability> = items.values.toList()

    fun availabilitySnapshot(ctx: Context): List<Triple<String, String, String>> =
        items.values.map { c ->
            Triple(c.id, c.displayName, c.availability(ctx).name)
        }
}

package com.shellmgr.shell_manager.plugins

import android.content.Context
import com.shellmgr.shell_manager.AdbBootstrap
import com.shellmgr.shell_manager.BrokerPrompt

/**
 * 统一权限网关（P1）。
 *
 * 设计取舍：**不替换** BrokerProvider / BrokerShell 已验证的授权逻辑，
 * 而是提供一层可供新插件使用的判定入口，并在判定时复用同一套事实源：
 * - shell 能力是否可用 → AdbBootstrap.isProvisioned + transport
 * - 悬浮窗 → BrokerPrompt.canOverlay
 * - 高危动作 → needUserConfirm（由调用方弹 BrokerPrompt 确认）
 *
 * 这样新增插件不会绕过既有权限边界，老通道行为零变化。
 */
object PermissionGateway {
    private val shellPermissions = listOf(
        PermissionSpec(
            id = "shell",
            type = PermissionType.SPECIAL,
            description = "需完成 adb 配对，由框架以 shell 身份代执行",
        ),
    )

    private val overlayPermission = PermissionSpec(
        id = "overlay",
        type = PermissionType.SPECIAL,
        description = "显示在其他应用上层，用于即时授权弹窗",
        runtimePermissions = listOf(android.Manifest.permission.SYSTEM_ALERT_WINDOW),
    )

    /** 判定某能力在执行某动作前是否具备条件。 */
    fun check(ctx: Context, capability: Capability, req: ActionRequest): GrantDecision {
        if (capability.availability(ctx) == Availability.NEED_GRANT) {
            val missing = capability.getRequiredPermissions(req).filter { !isGranted(ctx, it) }
            if (missing.isNotEmpty()) {
                return GrantDecision(false, "缺少权限：${missing.joinToString { it.id }}",
                    needUserConfirm = true, missing = missing)
            }
        }
        if (capability.availability(ctx) == Availability.EXTERNAL_DEP) {
            return GrantDecision(false, "需要外部依赖，未安装或未启用")
        }
        if (capability.availability(ctx) == Availability.UNSUPPORTED) {
            return GrantDecision(false, "当前设备不支持该能力")
        }
        if (req.highRisk) {
            // 高危动作不直接拒绝，但要求调用方先弹确认框
            return GrantDecision(true, "高危动作需二次确认", needUserConfirm = true)
        }
        return GrantDecision(true)
    }

    fun isGranted(ctx: Context, spec: PermissionSpec): Boolean = when (spec.id) {
        "shell" -> AdbBootstrap.isProvisioned(ctx) && AdbBootstrap.probeTransportAlive(ctx)
        "overlay" -> BrokerPrompt.canOverlay(ctx)
        else -> spec.runtimePermissions.all { p ->
            ctx.checkSelfPermission(p) == android.content.pm.PackageManager.PERMISSION_GRANTED
        }
    }
}

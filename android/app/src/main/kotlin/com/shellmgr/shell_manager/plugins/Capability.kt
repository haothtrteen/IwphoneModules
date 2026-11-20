package com.shellmgr.shell_manager.plugins

import android.content.Context

/** 能力可用性（对齐 vFlow 的权限模型 + 外部依赖场景）。 */
enum class Availability {
    AVAILABLE,       // 已具备
    NEED_GRANT,      // 需用户授权（RUNTIME 或 SPECIAL）
    UNSUPPORTED,     // 设备/系统不支持
    EXTERNAL_DEP,    // 需外部依赖（Shizuku / 虚拟屏）
}

/** 权限类型（对齐 vFlow PermissionType）。 */
enum class PermissionType { RUNTIME, SPECIAL }

/** 权限声明：id / 类型 / 说明 / 运行时权限组。 */
data class PermissionSpec(
    val id: String,
    val type: PermissionType,
    val description: String,
    val runtimePermissions: List<String> = emptyList(),
)

data class ActionRequest(
    val action: String,
    val args: Map<String, String> = emptyMap(),
    val timeoutMs: Long = 15_000,
    val highRisk: Boolean = false,
)

data class ActionResult(
    val ok: Boolean,
    val message: String = "",
    val data: Map<String, String> = emptyMap(),
)

/**
 * 能力契约。
 *
 * ★ 借鉴 vFlow：`getRequiredPermissions(req)` 按请求动态声明权限，
 * 同一能力不同动作可能需要不同权限（如 shell 的普通查询 vs 高危写操作）。
 */
interface Capability {
    val id: String
    val displayName: String
    fun availability(ctx: Context): Availability
    fun getRequiredPermissions(req: ActionRequest?): List<PermissionSpec>
    fun execute(ctx: Context, req: ActionRequest): ActionResult
}

/** 权限判定结果。 */
data class GrantDecision(
    val allowed: Boolean,
    val reason: String = "",
    val needUserConfirm: Boolean = false,
    val missing: List<PermissionSpec> = emptyList(),
)

package com.shellmgr.shell_manager.plugins

import android.content.Context

/**
 * 监视器契约。
 *
 * 借鉴 vFlow 的 ListeningTriggerHandler：宿主统计订阅者，
 * 首个订阅才 startListening，最后退订才 stopListening，
 * 避免"装了模块就常驻监听所有系统事件"。
 */
interface MonitorPlugin {
    val id: String
    val subject: String
    val defaultIntervalMs: Long
    /** 依赖的能力 id；缺失时宿主把状态置 SUSPENDED（用 DEGRADED 表示）。 */
    val requiredCapability: String? get() = null

    fun onRegister(ctx: Context, bus: PlatformEventBus)
    fun probe(ctx: Context): ProbeResult
    fun startListening(ctx: Context)
    fun stopListening(ctx: Context)
    fun recover(ctx: Context, from: MonitorState): RecoveryResult?
    fun onUnregister(ctx: Context)
}

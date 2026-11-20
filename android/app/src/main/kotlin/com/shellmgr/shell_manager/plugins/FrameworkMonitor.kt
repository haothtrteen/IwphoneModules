package com.shellmgr.shell_manager.plugins

import android.content.Context
import com.shellmgr.shell_manager.AdbBootstrap

/** 框架守护进程监视器：复用 AdbBootstrap 的只读探测，不碰状态、不重复拉起。 */
class FrameworkMonitor : MonitorPlugin {
    override val id = "framework"
    override val subject = "iwphone framework"
    override val defaultIntervalMs = 15_000L

    override fun onRegister(ctx: Context, bus: PlatformEventBus) {}

    override fun probe(ctx: Context): ProbeResult {
        val deployed = AdbBootstrap.frameworkState(ctx)
        return when (deployed) {
            AdbBootstrap.FW_STATE_INSTALLED -> {
                val running = AdbBootstrap.probeFrameworkRunning(ctx)
                if (running) {
                    ProbeResult(MonitorState.RUNNING, "Main.sh 存活")
                } else {
                    ProbeResult(MonitorState.DEGRADED, "框架已部署但 Main.sh 未运行")
                }
            }
            AdbBootstrap.FW_STATE_MISSING -> ProbeResult(MonitorState.ERROR, "框架未部署")
            else -> ProbeResult(MonitorState.UNKNOWN, "adb 不可用，无法判定")
        }
    }

    override fun startListening(ctx: Context) {}
    override fun stopListening(ctx: Context) {}

    override fun recover(ctx: Context, from: MonitorState): RecoveryResult? {
        // 只尝试拉起，不重新部署（部署是显式操作，避免半死连接上误操作）
        return if (AdbBootstrap.startFramework(ctx).ok) {
            RecoveryResult(true, "框架已拉起")
        } else {
            RecoveryResult(false, "框架拉起失败，需检查 adb / 无线调试")
        }
    }

    override fun onUnregister(ctx: Context) {}
}

/** adb transport 监视器：探测当前连接是否真的可用。 */
class AdbMonitor : MonitorPlugin {
    override val id = "adb"
    override val subject = "adb transport"
    override val defaultIntervalMs = 20_000L

    override fun onRegister(ctx: Context, bus: PlatformEventBus) {}
    override fun probe(ctx: Context): ProbeResult {
        val alive = AdbBootstrap.probeTransportAlive(ctx)
        return if (alive) {
            ProbeResult(MonitorState.RUNNING, "transport 可用")
        } else {
            ProbeResult(MonitorState.DEGRADED, "transport 不可用")
        }
    }
    override fun startListening(ctx: Context) {}
    override fun stopListening(ctx: Context) {}
    override fun recover(ctx: Context, from: MonitorState): RecoveryResult? {
        val r = AdbBootstrap.ensureTransportSmart(ctx)
        return RecoveryResult(r.ok, r.message)
    }
    override fun onUnregister(ctx: Context) {}
}

package com.shellmgr.shell_manager.plugins

import android.content.Context
import com.shellmgr.shell_manager.AdbBootstrap

/**
 * 模块监视器：逐个探测已安装模块的锁文件。
 *
 * 不依赖 WebUI（WebUI 挂了也能报模块状态），直接走 adb shell 读
 * /data/local/tmp/iwphone/locks/{名}/pid，与框架 core.sh 的 is_locked 语义一致。
 * 状态按模块分别发布：monitor:module:<名>。
 */
class ModuleMonitor : MonitorPlugin {
    override val id = "modules"
    override val subject = "iwphone modules"
    override val defaultIntervalMs = 10_000L

    private var known = emptyList<String>()

    override fun onRegister(ctx: Context, bus: PlatformEventBus) {}

    override fun probe(ctx: Context): ProbeResult {
        if (!AdbBootstrap.probeTransportAlive(ctx)) {
            return ProbeResult(MonitorState.UNKNOWN, "adb 不可用")
        }
        // 一次命令拿到所有模块名：work/*/main.sh 的父目录名
        val ls = AdbBootstrap.run(
            ctx,
            listOf("-s", AdbBootstrap.currentTarget(), "shell",
                "ls -d /data/local/tmp/iwphone/work/*/main.sh 2>/dev/null"),
            timeoutMs = 10_000,
        )
        val names: List<String> = if (ls.ok) {
            ls.message.lines()
                .mapNotNull { it.trim().substringAfterLast("/work/").substringBefore("/") }
                .distinct()
                .sorted()
        } else {
            emptyList()
        }

        val newSet = names.toSet()
        if (newSet != known.toSet()) {
            known.forEach { n ->
                PlatformEventBus.publish(PlatformEvent(
                    id = "monitor:module:$n", reason = "module removed",
                ))
            }
            known = names
        }

        var running = 0
        var failed = 0
        names.forEach { n ->
            val r = AdbBootstrap.run(
                ctx,
                listOf("-s", AdbBootstrap.currentTarget(), "shell",
                    "p=\$(cat /data/local/tmp/iwphone/locks/$n/pid 2>/dev/null); " +
                        "[ -n \"\$p\" ] && kill -0 \$p 2>/dev/null && echo RUN || echo STOP"),
                timeoutMs = 8_000,
            )
            val state = if (r.ok && r.message.trim() == "RUN") {
                running++
                MonitorState.RUNNING
            } else {
                failed++
                MonitorState.STOPPED
            }
            PlatformEventBus.publish(PlatformEvent(
                id = "monitor:module:$n",
                kind = PlatformEvent.KIND_STATE,
                to = state.name,
                reason = if (state == MonitorState.RUNNING) "pid alive" else "no live pid",
            ))
        }
        return if (names.isEmpty()) {
            ProbeResult(MonitorState.UNKNOWN, "未发现模块")
        } else if (failed > 0) {
            val total = names.size
            ProbeResult(MonitorState.DEGRADED, "$running 运行中 / $failed 停止（共 $total）")
        } else {
            ProbeResult(MonitorState.RUNNING, "$running 个模块运行中")
        }
    }

    override fun startListening(ctx: Context) {}
    override fun stopListening(ctx: Context) {}
    override fun recover(ctx: Context, from: MonitorState): RecoveryResult? = null
    override fun onUnregister(ctx: Context) {}
}

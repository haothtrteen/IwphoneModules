package com.shellmgr.shell_manager

import android.app.job.JobInfo
import android.app.job.JobParameters
import android.app.job.JobScheduler
import android.app.job.JobService
import android.content.ComponentName
import android.content.Context

/**
 * 调度开机自启任务。
 *
 * ## 为什么用 JobScheduler 而不是直接在广播里干活
 *
 * `BOOT_COMPLETED` 的广播接收器只有约 **10 秒**窗口（超时会被判 ANR）。
 * 而自启要做的事是：启动 adb 客户端 → 建连 → 取 shell 身份 → 下发两条启动命令
 * → 再跑一次进程检查。冷启动时 adb 首次拉起自己的 server 就要 1～2 秒，
 * 整体在低端机或 MIUI 上很容易顶破 10 秒。
 *
 * `JobService` 的执行窗口长得多（分钟级），且**不需要任何第三方依赖**
 * （WorkManager 是额外依赖，项目约定零第三方）。
 *
 * `setPersisted(true)` 让任务本身跨重启保留 —— 与 [BootReceiver] 形成双保险：
 * 广广播没收到（例如 MIUI 拦截）时，持久化的 job 仍有机会被系统重新调度。
 * 两条路径都触发也无妨：[AdbBootstrap.startFramework] 是幂等的。
 */
object AutostartScheduler {

    private const val JOB_ID = 0x1001

    fun schedule(ctx: Context, delayMs: Long = 0L) {
        val js = ctx.getSystemService(JobScheduler::class.java) ?: return
        val comp = ComponentName(ctx, AutostartJobService::class.java)

        // 先取消，避免同一时刻堆积多个实例
        js.cancel(JOB_ID)

        val builder = JobInfo.Builder(JOB_ID, comp)
            .setPersisted(true)          // 跨重启保留
            .setMinimumLatency(delayMs)  // 立刻可跑
            // 兜底截止时间：即便系统想做延迟调度，也必须在此时限内执行，
            // 保证开机后一定会跑一次（而不是被无限推迟到 Doze 窗口）
            .setOverrideDeadline(delayMs + 60_000L)

        try {
            js.schedule(builder.build())
        } catch (_: Exception) {
            // 极少数 ROM 拒绝 persisted job，降级为普通 job 重试一次
            try {
                js.schedule(
                    JobInfo.Builder(JOB_ID, comp)
                        .setMinimumLatency(delayMs)
                        .setOverrideDeadline(delayMs + 60_000L)
                        .build(),
                )
            } catch (_: Exception) {
            }
        }
    }
}

/**
 * 实际执行自启的任务。
 *
 * 流程：重认证（连 127.0.0.1:5555 并取 shell）→ 拉起框架与非必须的 WebUI
 * → 记录结果 → 发通知。结果同时落到 SharedPreferences，设置页可直接展示。
 */
class AutostartJobService : JobService() {

    override fun onStartJob(params: JobParameters?): Boolean {
        // 返回 true 表示「我自己在别的线程干活，干完会调 jobFinished」
        Thread {
            val ctx = applicationContext
            var ok = false
            var msg = ""
            var skipped = false
            try {
                // 用户可能在开机后自己关掉了开关
                if (!AutostartPrefs.isEnabled(ctx)) {
                    skipped = true
                    msg = "自启开关已关闭，跳过"
                } else {
                    val r = AdbBootstrap.startFramework(ctx)
                    ok = r.ok
                    skipped = r.skipped
                    msg = r.message
                }
            } catch (e: Exception) {
                ok = false
                msg = "未预期异常：${e.javaClass.simpleName}: ${e.message}"
            }

            if (!skipped) {
                AutostartPrefs.recordResult(ctx, ok, msg)
                AutostartNotify.post(ctx, ok, msg)
            }

            try {
                jobFinished(params, false)
            } catch (_: Exception) {
            }
        }.start()
        return true
    }

    override fun onStopJob(params: JobParameters?): Boolean {
        // 被系统中断就放弃，不要求重排（下次开机/下次打开 App 会再触发）
        return false
    }
}

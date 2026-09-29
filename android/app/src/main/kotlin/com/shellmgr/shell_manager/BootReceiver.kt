package com.shellmgr.shell_manager

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent

/**
 * 开机广播接收器。
 *
 * 职责非常单一：**只负责把任务丢给 [AutostartScheduler]，自己不做任何耗时操作。**
 *
 * 原因：`BOOT_COMPLETED` 的接收器运行在应用主线程上，只有约 10 秒窗口，
 * 超时会被判 ANR。而在广播里直接跑 adb、连网、等待进程启动，
 * 冷启动场景下很可能顶破这个窗口 —— 所以真正的活在 [AutostartJobService] 里干。
 *
 * 只监听 `BOOT_COMPLETED`，不监听 `LOCKED_BOOT_COMPLETED`：
 * 后者在用户解锁前触发，此时应用私有目录（直接加密存储）还读不到，
 * 自启开关与 adb 密钥都在里面 —— 提前跑必然失败。
 */
class BootReceiver : BroadcastReceiver() {

    override fun onReceive(context: Context, intent: Intent?) {
        val action = intent?.action ?: return
        val accepted = action == Intent.ACTION_BOOT_COMPLETED ||
            // 少数 ROM（含部分 MIUI/HyperOS 版本）用这个私有 action
            action == "android.intent.action.QUICKBOOT_POWERON" ||
            action == "com.htc.intent.action.QUICKBOOT_POWERON"
        if (!accepted) return

        val ctx = context.applicationContext
        if (!AutostartPrefs.isEnabled(ctx)) return

        // 开机瞬间系统繁忙，留 10 秒错峰；JobScheduler 的 overrideDeadline 保证不会拖太久
        AutostartScheduler.schedule(ctx, delayMs = 10_000L)
    }
}

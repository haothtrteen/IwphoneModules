package com.shellmgr.shell_manager

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.os.Build
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import androidx.core.app.RemoteInput

/**
 * 配对流程的通知。
 *
 * ## 为什么要做成「通知里输配对码」
 *
 * 配对的标准流程是：开发者选项 → 无线调试 → 使用配对码配对设备 →
 * 把 6 位码填给发起方。这个流程必然要把 App 切到后台去开系统设置。
 *
 * 如果要求用户切回 App 再填码，一来一回很折腾；而且配对端口只在
 * 配对界面打开期间存在，时机很紧。把输入框**直接放在通知里**，
 * 用户开着配对界面就能顺手提交，是最短路径 —— Shizuku 也是这么做的。
 *
 * 实现要点：通知里的文本输入用的是 [RemoteInput]（和通知快捷回复同一机制），
 * 要求 PendingIntent 是 **FLAG_MUTABLE**（系统要往里塞输入结果）。
 */
object PairingNotify {

    private const val CHANNEL_ID = "pairing"
    private const val CHANNEL_NAME = "设备配对"
    private const val NOTIFY_WAITING = 0x2001
    private const val NOTIFY_RESULT = 0x2002

    /** 通知里输入框的 key，接收端靠它取配对码。 */
    const val EXTRA_PAIRING_CODE = "pairing_code"

    /** 是否已获得通知权限（Android 13+ 需要运行时申请）。 */
    fun hasPermission(ctx: Context): Boolean = AutostartNotify.hasPermission(ctx)

    private fun ensureChannel(ctx: Context) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val mgr = ctx.getSystemService(NotificationManager::class.java) ?: return
        if (mgr.getNotificationChannel(CHANNEL_ID) != null) return
        val ch = NotificationChannel(
            CHANNEL_ID,
            CHANNEL_NAME,
            NotificationManager.IMPORTANCE_HIGH,   // 配对有时效性，要能立刻看到
        ).apply {
            description = "输入配对码完成 ADB 配对"
        }
        mgr.createNotificationChannel(ch)
    }

    private fun mutableFlags(): Int {
        val update = PendingIntent.FLAG_UPDATE_CURRENT
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            update or PendingIntent.FLAG_MUTABLE   // RemoteInput 必须可变
        } else {
            update
        }
    }

    /**
     * 发出「等待配对码」的通知，带输入框。
     *
     * 用户填好码点发送后，[PairingReceiver] 会收到：
     * 先用 mDNS 找配对端口，再执行配对，成功后顺手把 5555 固定下来。
     */
    fun postWaiting(ctx: Context) {
        if (!hasPermission(ctx)) return
        ensureChannel(ctx)

        val remoteInput = RemoteInput.Builder(EXTRA_PAIRING_CODE)
            .setLabel("输入 6 位配对码")
            .build()

        val submit = Intent(ctx, PairingReceiver::class.java).apply {
            action = PairingReceiver.ACTION_SUBMIT
        }
        val pi = PendingIntent.getBroadcast(ctx, 0, submit, mutableFlags())

        val action = NotificationCompat.Action.Builder(
            R.drawable.ic_stat_autostart,
            "输入配对码",
            pi,
        ).addRemoteInput(remoteInput)
            .setAllowGeneratedReplies(false)
            .build()

        // 点通知本体回到 App（万一用户想在页面上看进度/手动填）
        val tap = PendingIntent.getActivity(
            ctx, 1,
            Intent(ctx, MainActivity::class.java).apply {
                flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP
            },
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M)
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
            else PendingIntent.FLAG_UPDATE_CURRENT,
        )

        val n = NotificationCompat.Builder(ctx, CHANNEL_ID)
            .setSmallIcon(R.drawable.ic_stat_autostart)
            .setContentTitle("等待配对码")
            .setContentText(
                "请在系统「无线调试 → 使用配对码配对设备」界面获取配对码，" +
                    "打开该界面后本应用会自动找到配对端口。",
            )
            .setStyle(
                NotificationCompat.BigTextStyle().bigText(
                    "1. 打开 开发者选项 → 无线调试\n" +
                        "2. 点「使用配对码配对设备」（保持该界面打开）\n" +
                        "3. 在下方输入框填入配对码并发送\n\n" +
                        "配对端口会自动发现，无需手动填写。",
                ),
            )
            .addAction(action)
            .setContentIntent(tap)
            .setOngoing(true)          // 配对没完成前别被划掉
            .setOnlyAlertOnce(true)
            .setPriority(NotificationCompat.PRIORITY_HIGH)
            .build()

        NotificationManagerCompat.from(ctx).notify(NOTIFY_WAITING, n)
    }

    /** 配对结束，撤掉等待通知并发结果。 */
    fun postResult(ctx: Context, ok: Boolean, message: String) {
        // 等待通知先撤掉（无论成败，这个流程已经结束了）
        NotificationManagerCompat.from(ctx).cancel(NOTIFY_WAITING)

        if (!AutostartNotify.hasPermission(ctx)) return
        ensureChannel(ctx)

        val n = NotificationCompat.Builder(ctx, CHANNEL_ID)
            .setSmallIcon(R.drawable.ic_stat_autostart)
            .setContentTitle(if (ok) "配对成功" else "配对未成功")
            .setContentText(message)
            .setStyle(NotificationCompat.BigTextStyle().bigText(message))
            .setAutoCancel(true)
            .setPriority(NotificationCompat.PRIORITY_DEFAULT)
            .build()

        NotificationManagerCompat.from(ctx).notify(NOTIFY_RESULT, n)
    }

    /** 清掉配对相关通知（比如用户在 App 里手动取消了流程）。 */
    fun cancelAll(ctx: Context) {
        val mgr = NotificationManagerCompat.from(ctx)
        mgr.cancel(NOTIFY_WAITING)
        mgr.cancel(NOTIFY_RESULT)
    }
}

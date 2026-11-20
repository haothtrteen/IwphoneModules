package com.shellmgr.shell_manager.plugins

import android.app.Notification
import android.content.Context
import android.provider.Settings
import android.service.notification.NotificationListenerService
import android.service.notification.StatusBarNotification
import java.util.concurrent.ConcurrentHashMap

/**
 * 通知监听服务（应用级触发器的数据源）。
 *
 * 权限模型与无障碍不同：通知使用权是**独立**的一项授权
 * （设置 → 通知与状态栏 → 通知使用权），没授权时本服务根本不会被绑定，
 * 也就不会有任何事件 —— 所以 UI 必须显式提示去开，而不是静默失败。
 *
 * 设计取舍：
 * - 只发事件、不做动作（与无障碍服务同一分层）；
 * - **常驻通知**（音乐播放器、下载进度、前台服务）不算「来了通知」，直接丢掉；
 * - 分组摘要（GROUP_SUMMARY）也丢掉，否则一条微信会触发两次；
 * - 同一个包 1.5 秒内只发一次：同一条通知的更新会反复回调，
 *   不收敛的话配一个「微信来通知就点一下」会连点好几次。
 */
class IwphoneNotificationListener : NotificationListenerService() {

    private val lastFiredAt = ConcurrentHashMap<String, Long>()

    override fun onListenerConnected() {
        super.onListenerConnected()
        android.util.Log.i(TAG, "notification listener connected")
        PlatformEventBus.publish(PlatformEvent(
            id = "capability:notification",
            kind = PlatformEvent.KIND_STATE,
            to = "RUNNING",
            reason = "notification listener connected",
        ))
    }

    override fun onListenerDisconnected() {
        super.onListenerDisconnected()
        PlatformEventBus.publish(PlatformEvent(
            id = "capability:notification",
            kind = PlatformEvent.KIND_STATE,
            to = "STOPPED",
            reason = "notification listener disconnected",
        ))
    }

    override fun onNotificationPosted(sbn: StatusBarNotification?) {
        val n = sbn ?: return
        val pkg = n.packageName ?: return

        // 自己的通知（自动化执行提示）不该反过来触发自动化
        if (pkg == packageName) return
        // 常驻通知 / 分组摘要不算「新通知」
        if (n.isOngoing) return
        if ((n.notification.flags and Notification.FLAG_GROUP_SUMMARY) != 0) return

        val now = System.currentTimeMillis()
        val last = lastFiredAt[pkg] ?: 0L
        if (now - last < 1500L) return
        lastFiredAt[pkg] = now

        val title = runCatching {
            n.notification.extras.getCharSequence(Notification.EXTRA_TITLE)?.toString()
        }.getOrNull().orEmpty()
        val text = runCatching {
            n.notification.extras.getCharSequence(Notification.EXTRA_TEXT)?.toString()
        }.getOrNull().orEmpty()

        PlatformEventBus.publish(PlatformEvent(
            id = "notif:$pkg",
            kind = PlatformEvent.KIND_STATE,
            reason = title.ifEmpty { pkg },
            payload = mapOf(
                "package" to pkg,
                "title" to title,
                "text" to text,
                "key" to (n.key ?: ""),
            ),
        ))
        // 这个功能的失败模式是「什么都没发生」，留一条日志便于 adb 侧确认投递到了
        android.util.Log.d(TAG, "notif:$pkg title=${title.take(40)}")
    }

    companion object {
        private const val TAG = "IwphoneNotif"
        /**
         * 通知使用权是否已授予。
         *
         * `enabled_notification_listeners` 是 `pkg/cls:pkg/cls` 的扁平串；
         * 只要有一段以本包名开头就算开过（具体是哪个 Service 由系统绑定）。
         */
        fun isEnabled(ctx: Context): Boolean {
            val raw = try {
                Settings.Secure.getString(ctx.contentResolver, "enabled_notification_listeners")
            } catch (_: Exception) {
                null
            } ?: return false
            return raw.split(':').any { it.startsWith(ctx.packageName + "/") }
        }
    }
}

package com.shellmgr.shell_manager

import android.Manifest
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import androidx.core.content.ContextCompat

/**
 * 开机自启的持久化状态。
 *
 * 用最普通的 SharedPreferences —— 数据量极小（几个布尔与时间戳），
 * 没必要引入 DataStore 之类的依赖，也符合项目「零第三方依赖」的约定。
 */
object AutostartPrefs {

    private const val FILE = "autostart"
    private const val KEY_ENABLED = "enabled"
    private const val KEY_LAST_TIME = "last_time"
    private const val KEY_LAST_OK = "last_ok"
    private const val KEY_LAST_MSG = "last_msg"
    private const val KEY_WEBUI_TOKEN = "webui_token"
    private const val KEY_DEPLOY_STAMP = "fw_deploy_stamp"

    /**
     * 上次部署框架时本 App 的安装时间戳（毫秒）。
     *
     * 用来判断「App 升级后要不要把内置框架重新铺一遍」。0 表示从未记录过。
     */
    fun deployStamp(ctx: Context): Long = sp(ctx).getLong(KEY_DEPLOY_STAMP, 0L)

    fun setDeployStamp(ctx: Context, value: Long) {
        sp(ctx).edit().putLong(KEY_DEPLOY_STAMP, value).apply()
    }

    private fun sp(ctx: Context) = ctx.getSharedPreferences(FILE, Context.MODE_PRIVATE)

    /**
     * WebUI 访问密钥（用户自己设的那把）。
     *
     * 存在应用私有 SharedPreferences 里：同设备其它应用读不到（除非 root）。
     * 密钥本身也在设备侧有一份（见 AdbBootstrap.WEBUI_TOKEN_FILE）——
     * 两边必须一致，App 这份是为了每次请求带 X-Token 头。
     */
    fun webuiToken(ctx: Context): String =
        sp(ctx).getString(KEY_WEBUI_TOKEN, "").orEmpty()

    fun setWebuiToken(ctx: Context, value: String) {
        sp(ctx).edit().putString(KEY_WEBUI_TOKEN, value).apply()
    }

    /** 用户是否开启了「开机自启」。 */
    fun isEnabled(ctx: Context): Boolean = sp(ctx).getBoolean(KEY_ENABLED, false)

    fun setEnabled(ctx: Context, value: Boolean) {
        sp(ctx).edit().putBoolean(KEY_ENABLED, value).apply()
    }

    /** 记录一次自启尝试的结果，供设置页展示。 */
    fun recordResult(ctx: Context, ok: Boolean, message: String) {
        sp(ctx).edit()
            .putLong(KEY_LAST_TIME, System.currentTimeMillis())
            .putBoolean(KEY_LAST_OK, ok)
            .putString(KEY_LAST_MSG, message)
            .apply()
    }

    /** 上次自启结果；从未执行过时返回 null。 */
    fun lastResult(ctx: Context): Triple<Long, Boolean, String>? {
        val t = sp(ctx).getLong(KEY_LAST_TIME, 0L)
        if (t <= 0L) return null
        return Triple(
            t,
            sp(ctx).getBoolean(KEY_LAST_OK, false),
            sp(ctx).getString(KEY_LAST_MSG, "") ?: "",
        )
    }
}

/**
 * 自启结果通知。
 *
 * 用户明确要求「成功重认证并拉起框架后通知用户」—— 因为是后台静默完成，
 * 没有任何界面可见，不通知的话用户无法确认到底有没有生效。
 */
object AutostartNotify {

    private const val CHANNEL_ID = "autostart"
    private const val CHANNEL_NAME = "开机自启"
    private const val NOTIFY_ID = 0x1001

    /** 是否已获得通知权限（Android 13+ 需要运行时申请）。 */
    fun hasPermission(ctx: Context): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) return true
        return ContextCompat.checkSelfPermission(
            ctx,
            Manifest.permission.POST_NOTIFICATIONS,
        ) == PackageManager.PERMISSION_GRANTED
    }

    private fun ensureChannel(ctx: Context) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val mgr = ctx.getSystemService(NotificationManager::class.java) ?: return
        if (mgr.getNotificationChannel(CHANNEL_ID) != null) return
        val ch = NotificationChannel(
            CHANNEL_ID,
            CHANNEL_NAME,
            NotificationManager.IMPORTANCE_DEFAULT,
        ).apply {
            description = "开机后自动重认证并拉起 iwphone 框架的结果"
            setShowBadge(true)
        }
        mgr.createNotificationChannel(ch)
    }

    /**
     * 发送一条自启结果通知。
     *
     * 无通知权限时静默跳过（结果已落 SharedPreferences，设置页仍可查看）。
     * 点击通知回到 App，便于失败时直接排查。
     */
    fun post(ctx: Context, ok: Boolean, message: String) {
        if (!hasPermission(ctx)) return
        ensureChannel(ctx)

        val tapIntent = Intent(ctx, MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP
        }
        val flags = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        } else {
            PendingIntent.FLAG_UPDATE_CURRENT
        }
        val pi = PendingIntent.getActivity(ctx, 0, tapIntent, flags)

        val n = NotificationCompat.Builder(ctx, CHANNEL_ID)
            .setSmallIcon(R.drawable.ic_stat_autostart)
            .setContentTitle(if (ok) "框架已自动启动" else "自动启动未成功")
            .setContentText(message)
            .setStyle(NotificationCompat.BigTextStyle().bigText(message))
            .setContentIntent(pi)
            .setAutoCancel(true)
            .setPriority(NotificationCompat.PRIORITY_DEFAULT)
            .build()

        try {
            NotificationManagerCompat.from(ctx).notify(NOTIFY_ID, n)
        } catch (_: SecurityException) {
            // 极少数 ROM 上即便检查过权限仍会抛，忽略
        }
    }
}

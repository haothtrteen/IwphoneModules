package com.shellmgr.shell_manager

import android.content.Context
import android.graphics.Color
import android.graphics.drawable.GradientDrawable
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import android.util.TypedValue
import android.view.Gravity
import android.view.View
import android.view.WindowManager
import android.widget.CheckBox
import android.widget.ImageView
import android.widget.LinearLayout
import android.widget.TextView
import java.util.Locale
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

/**
 * 「请求即确认」的即时授权弹窗（Magisk 式）。
 *
 * ## 为什么是悬浮窗，不是 Activity
 *
 * Android 10 起禁止后台进程启动 Activity。broker 是被动被调起的 ContentProvider，
 * 请求进来时本应用几乎必然在后台（用户正用着发起请求的那个应用），
 * `startActivity` 会被系统静默丢弃，弹窗根本出不来。
 *
 * Magisk / Shizuku 用的是 **SYSTEM_ALERT_WINDOW 悬浮窗**：它不是 Activity，
 * 属于系统明确允许的后台显示界面通道。所以这里用
 * `TYPE_APPLICATION_OVERLAY` 画一个对话框，provider 的 Binder 线程等用户点完
 * 再继续执行或拒绝 —— 和 su 命令卡住等用户点「允许」是同一个体验。
 *
 * ## 降级
 *
 * 悬浮窗权限要用户在系统设置里手动开，不能默认就有。没开时 [ask] 返回
 * `NO_UI`，调用方回落到原来的「待授权列表 + NEED_APPROVAL」，功能不中断。
 *
 * ## 并发与骚扰控制
 *
 * - 同一 (uid, 包名) 只弹一次，后来的调用共用同一个决定；
 * - 最多 3 个弹窗并存，超出的直接返回 BUSY；
 * - 拒绝 / 超时后 60 秒内不再弹；
 * - 45 秒无人处理自动按拒绝处理，避免 Binder 线程被永久占住。
 */
object BrokerPrompt {

    enum class Decision {
        /** 允许并写入授权表，长期有效。 */
        ALLOW_ALWAYS,

        /** 只放行这一次，不落盘。 */
        ALLOW_ONCE,

        /** 本次拒绝，60 秒冷却。 */
        DENY,

        /** 记住拒绝，写入 denied 表，以后不再弹。 */
        DENY_ALWAYS,

        TIMEOUT,
        NO_UI,
        BUSY,
        COOLDOWN,
    }

    fun canOverlay(ctx: Context): Boolean =
        Build.VERSION.SDK_INT < Build.VERSION_CODES.M || Settings.canDrawOverlays(ctx)

    private const val MAX_CONCURRENT = 3
    private const val TIMEOUT_MS = 45_000L
    private const val DENY_COOLDOWN_MS = 60_000L

    private class Pending(
        val pkg: String,
        val uid: Int,
        val sig: String,
        val latch: CountDownLatch = CountDownLatch(1),
        @Volatile var decision: Decision = Decision.TIMEOUT,
        @Volatile var view: View? = null,
        @Volatile var wm: WindowManager? = null,
    )

    private val lock = Any()
    private val pending = HashMap<String, Pending>()
    private val recentDeny = ConcurrentHashMap<String, Long>()

    /**
     * 弹窗并等待用户决定。**运行在 provider 的 Binder 线程上**，会阻塞调用方
     * （这正是「请求即确认」想要的效果：命令不会在授权前偷偷执行）。
     */
    fun ask(ctx: Context, pkg: String, uid: Int, sig: String): Decision {
        if (!canOverlay(ctx)) return Decision.NO_UI

        val now = System.currentTimeMillis()
        if (now - (recentDeny[pkg] ?: 0L) < DENY_COOLDOWN_MS) {
            return Decision.COOLDOWN
        }

        val key = "$uid/$pkg"
        val (p, created) = synchronized(lock) {
            val existing = pending[key]
            if (existing != null) {
                existing to false
            } else {
                if (pending.size >= MAX_CONCURRENT) return Decision.BUSY
                val np = Pending(pkg, uid, sig)
                pending[key] = np
                np to true
            }
        }

        if (created) show(ctx, p)

        val done = p.latch.await(TIMEOUT_MS, TimeUnit.MILLISECONDS)
        if (created) {
            if (!done) resolve(p, Decision.TIMEOUT)
            synchronized(lock) { pending.remove(key) }
        }

        val d = if (done) p.decision else Decision.TIMEOUT
        if (d == Decision.DENY || d == Decision.DENY_ALWAYS ||
            d == Decision.TIMEOUT || d == Decision.NO_UI
        ) {
            recentDeny[pkg] = System.currentTimeMillis()
        }
        return d
    }

    /** 用户点了按钮（或添加悬浮窗失败）时回填决定并关掉弹窗。 */
    private fun resolve(p: Pending, d: Decision) {
        p.decision = d
        p.latch.countDown()
        val view = p.view ?: return
        val wm = p.wm ?: return
        Handler(Looper.getMainLooper()).post {
            try {
                wm.removeViewImmediate(view)
            } catch (_: Exception) {
            }
        }
    }

    // ------------------------------------------------------------------
    // 悬浮窗界面（程序化构建，项目不含 layout 资源、也不引第三方 UI 库）
    // ------------------------------------------------------------------

    private fun show(ctx: Context, p: Pending) {
        val app = ctx.applicationContext
        val wm = app.getSystemService(Context.WINDOW_SERVICE) as WindowManager
        Handler(Looper.getMainLooper()).post {
            val root = buildView(app, p)
            val type = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY
            } else {
                @Suppress("DEPRECATION")
                WindowManager.LayoutParams.TYPE_PHONE
            }
            val lp = WindowManager.LayoutParams(
                WindowManager.LayoutParams.MATCH_PARENT,
                WindowManager.LayoutParams.WRAP_CONTENT,
                type,
                WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE or
                    WindowManager.LayoutParams.FLAG_DIM_BEHIND,
                android.graphics.PixelFormat.TRANSLUCENT,
            ).apply {
                gravity = Gravity.CENTER
                dimAmount = 0.55f
            }
            try {
                wm.addView(root, lp)
                p.view = root
                p.wm = wm
            } catch (_: Exception) {
                // 少数 ROM 会拦悬浮窗（即便 canDrawOverlays 返回 true）
                resolve(p, Decision.NO_UI)
            }
        }
    }

    private fun buildView(ctx: Context, p: Pending): View {
        val c = copy(ctx)
        val dp = { v: Int -> TypedValue.applyDimension(
            TypedValue.COMPLEX_UNIT_DIP, v.toFloat(), ctx.resources.displayMetrics
        ).toInt() }

        val card = LinearLayout(ctx).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(dp(20), dp(18), dp(20), dp(16))
            background = GradientDrawable().apply {
                setColor(Color.parseColor("#FFFFFF"))
                cornerRadius = dp(16).toFloat()
                setStroke(1, Color.parseColor("#E3E3E8"))
            }
            elevation = dp(8).toFloat()
        }

        // 标题行：图标 + 「shell 权限请求」
        val head = LinearLayout(ctx).apply { orientation = LinearLayout.HORIZONTAL }
        val icon = ImageView(ctx).apply {
            try {
                setImageDrawable(ctx.packageManager.getApplicationIcon(p.pkg))
            } catch (_: Exception) {
                setImageResource(android.R.drawable.sym_def_app_icon)
            }
        }
        head.addView(icon, LinearLayout.LayoutParams(dp(36), dp(36)))
        val title = TextView(ctx).apply {
            text = c.title
            setTextColor(Color.parseColor("#1A1A1F"))
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 16f)
            setTypeface(null, android.graphics.Typeface.BOLD)
            setPadding(dp(12), 0, 0, 0)
            gravity = Gravity.CENTER_VERTICAL
        }
        head.addView(title, LinearLayout.LayoutParams(0, dp(36), 1f))
        card.addView(head)

        card.addView(space(ctx, dp(12)))

        val label = BrokerStore.labelOf(ctx, p.pkg)
        card.addView(line(ctx, c.requester, label, primary = true))
        card.addView(line(ctx, c.pkgLabel, p.pkg))
        card.addView(line(ctx, c.uidLabel, p.uid.toString()))
        card.addView(line(ctx, c.sigLabel, p.sig.take(16)))

        card.addView(space(ctx, dp(10)))
        card.addView(TextView(ctx).apply {
            text = c.warning
            setTextColor(Color.parseColor("#A32D2D"))
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 12f)
            setLineSpacing(dp(3).toFloat(), 1f)
        })

        card.addView(space(ctx, dp(8)))
        val remember = CheckBox(ctx).apply {
            text = c.remember
            isChecked = true
            setTextColor(Color.parseColor("#4A4A52"))
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 12f)
        }
        card.addView(remember)

        card.addView(space(ctx, dp(6)))
        val row = LinearLayout(ctx).apply { orientation = LinearLayout.HORIZONTAL }
        val deny = button(ctx, c.deny, "#FCEBEB", "#A32D2D") {
            resolve(p, if (remember.isChecked) Decision.DENY_ALWAYS else Decision.DENY)
        }
        val allow = button(ctx, c.allow, "#E1F5EE", "#0F6E56") {
            resolve(p, if (remember.isChecked) Decision.ALLOW_ALWAYS else Decision.ALLOW_ONCE)
        }
        row.addView(deny, LinearLayout.LayoutParams(0, dp(42), 1f))
        row.addView(View(ctx), LinearLayout.LayoutParams(dp(10), dp(42)))
        row.addView(allow, LinearLayout.LayoutParams(0, dp(42), 1f))
        card.addView(row)

        card.addView(space(ctx, dp(6)))
        card.addView(TextView(ctx).apply {
            text = c.timeoutHint
            setTextColor(Color.parseColor("#8A8A92"))
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 11f)
            gravity = Gravity.CENTER
        })

        // 卡片外层留白，避免贴边
        return LinearLayout(ctx).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(dp(24), 0, dp(24), 0)
            addView(card, LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.MATCH_PARENT,
                LinearLayout.LayoutParams.WRAP_CONTENT,
            ))
        }
    }

    private fun line(ctx: Context, k: String, v: String, primary: Boolean = false): View =
        LinearLayout(ctx).apply {
            orientation = LinearLayout.HORIZONTAL
            val key = TextView(ctx).apply {
                text = k
                setTextColor(Color.parseColor("#6B6B73"))
                setTextSize(TypedValue.COMPLEX_UNIT_SP, 12f)
            }
            addView(key, LinearLayout.LayoutParams(
                TypedValue.applyDimension(
                    TypedValue.COMPLEX_UNIT_DIP, 68f, ctx.resources.displayMetrics
                ).toInt(),
                LinearLayout.LayoutParams.WRAP_CONTENT,
            ))
            val value = TextView(ctx).apply {
                text = v
                setTextColor(Color.parseColor(if (primary) "#1A1A1F" else "#4A4A52"))
                setTextSize(TypedValue.COMPLEX_UNIT_SP, 12f)
                if (primary) setTypeface(null, android.graphics.Typeface.BOLD)
            }
            addView(value, LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f))
        }

    private fun button(
        ctx: Context,
        text: String,
        bg: String,
        fg: String,
        onClick: () -> Unit,
    ): TextView = TextView(ctx).apply {
        this.text = text
        setTextColor(Color.parseColor(fg))
        setTextSize(TypedValue.COMPLEX_UNIT_SP, 13f)
        gravity = Gravity.CENTER
        background = GradientDrawable().apply {
            setColor(Color.parseColor(bg))
            cornerRadius = TypedValue.applyDimension(
                TypedValue.COMPLEX_UNIT_DIP, 10f, ctx.resources.displayMetrics
            )
        }
        isClickable = true
        isFocusable = true
        setOnClickListener { onClick() }
    }

    private fun space(ctx: Context, h: Int): View =
        View(ctx).apply {
            layoutParams = LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.MATCH_PARENT, h
            )
        }

    // ------------------------------------------------------------------
    // 文案：跟随应用内语言设置；system 模式按系统 locale 判定
    // ------------------------------------------------------------------

    private data class Copy(
        val title: String,
        val requester: String,
        val pkgLabel: String,
        val uidLabel: String,
        val sigLabel: String,
        val warning: String,
        val remember: String,
        val allow: String,
        val deny: String,
        val timeoutHint: String,
    )

    private fun copy(ctx: Context): Copy {
        val en = when (UiPrefs.locale(ctx)) {
            "en" -> true
            "zh" -> false
            else -> Locale.getDefault().language.lowercase(Locale.ROOT) != "zh"
        }
        return if (en) Copy(
            title = "Shell access request",
            requester = "App",
            pkgLabel = "Package",
            uidLabel = "UID",
            sigLabel = "Signature",
            warning = "Allowing this lets the app run any command as shell (uid 2000). " +
                "Only approve apps you trust.",
            remember = "Remember this choice",
            allow = "Allow",
            deny = "Deny",
            timeoutHint = "Auto-denied after 45 seconds without a response",
        ) else Copy(
            title = "Shell 权限请求",
            requester = "应用",
            pkgLabel = "包名",
            uidLabel = "UID",
            sigLabel = "签名",
            warning = "允许后该应用将以 shell（uid 2000）身份执行任意命令，等同 adb shell 权限。请只授权你信任的应用。",
            remember = "记住此选择",
            allow = "允许",
            deny = "拒绝",
            timeoutHint = "45 秒内未处理将自动拒绝",
        )
    }
}

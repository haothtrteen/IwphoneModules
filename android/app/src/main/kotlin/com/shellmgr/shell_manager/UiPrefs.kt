package com.shellmgr.shell_manager

import android.content.Context

/**
 * 界面偏好：主题模式、语言、是否已完成首次引导。
 *
 * 单独放一个文件而不是塞进 AutostartPrefs —— 那个名字只讲开机自启，
 * 把界面偏好混进去会让人误以为改主题和自启有关。
 *
 * 同样是零依赖的 SharedPreferences。
 */
object UiPrefs {

    private const val FILE = "ui_prefs"
    private const val KEY_THEME = "theme_mode"        // system | light | dark
    private const val KEY_LOCALE = "locale"           // system | zh | en
    private const val KEY_ONBOARDING = "onboarding_done"
    private const val KEY_TOKEN_PROMPT = "token_prompt_dismissed"
    private const val KEY_PIN_PORT = "pin_adb_port"

    private fun sp(ctx: Context) = ctx.getSharedPreferences(FILE, Context.MODE_PRIVATE)

    fun themeMode(ctx: Context): String = sp(ctx).getString(KEY_THEME, "system") ?: "system"

    fun setThemeMode(ctx: Context, value: String) {
        sp(ctx).edit().putString(KEY_THEME, value).apply()
    }

    fun locale(ctx: Context): String = sp(ctx).getString(KEY_LOCALE, "system") ?: "system"

    fun setLocale(ctx: Context, value: String) {
        sp(ctx).edit().putString(KEY_LOCALE, value).apply()
    }

    fun onboardingDone(ctx: Context): Boolean = sp(ctx).getBoolean(KEY_ONBOARDING, false)

    fun setOnboardingDone(ctx: Context, value: Boolean) {
        sp(ctx).edit().putBoolean(KEY_ONBOARDING, value).apply()
    }

    /** 用户是否点过「暂不设置」把首页的密钥提示关掉。 */
    fun tokenPromptDismissed(ctx: Context): Boolean =
        sp(ctx).getBoolean(KEY_TOKEN_PROMPT, false)

    fun setTokenPromptDismissed(ctx: Context, value: Boolean) {
        sp(ctx).edit().putBoolean(KEY_TOKEN_PROMPT, value).apply()
    }

    /**
     * 是否固定 adb 端口（默认开启）。
     *
     * 开启时配对成功后会 `adb tcpip 5555`，把 `persist.adb.tcp.port` 写死，
     * 重启后 adbd 自动监听 5555，App 无需重新配对即可连接。
     *
     * 关掉它的代价很直接：重启后 adbd 回到动态端口，**必须重新配对**才能用，
     * 开机自启也因此失效。给在意"调试端口不该长期常开"的人留的开关。
     */
    fun pinPort(ctx: Context): Boolean = sp(ctx).getBoolean(KEY_PIN_PORT, true)

    fun setPinPort(ctx: Context, value: Boolean) {
        sp(ctx).edit().putBoolean(KEY_PIN_PORT, value).apply()
    }

    fun snapshot(ctx: Context): Map<String, Any> = mapOf(
        "pinPort" to pinPort(ctx),
        "themeMode" to themeMode(ctx),
        "locale" to locale(ctx),
        "onboardingDone" to onboardingDone(ctx),
        "tokenPromptDismissed" to tokenPromptDismissed(ctx),
    )
}

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

    fun snapshot(ctx: Context): Map<String, Any> = mapOf(
        "themeMode" to themeMode(ctx),
        "locale" to locale(ctx),
        "onboardingDone" to onboardingDone(ctx),
        "tokenPromptDismissed" to tokenPromptDismissed(ctx),
    )
}

package com.shellmgr.shell_manager

import android.annotation.SuppressLint
import android.app.Activity
import android.os.Bundle
import android.webkit.JavascriptInterface
import android.webkit.WebView
import android.webkit.WebViewClient
import org.json.JSONObject

/**
 * 模块自带 WebUI 的展示页（KernelSU 式 webroot）。
 *
 * ## 为什么这样实现
 *
 * 模块自带的 `webroot/index.html` 由框架的 WebUI 服务在
 * `http://127.0.0.1:8537/mod/<模块名>/` 下提供 —— 和特权 API 同源同服务，
 * 所以模块页面里 `fetch('/api/shell?…')` 天然可用、且是同一套鉴权。
 *
 * 为了兼容按 KernelSU WebUI 规范写的模块（直接调 `ksu.exec(...)`），
 * 这里通过 `addJavascriptInterface` 注入一个 `ksu` 桥：
 * 桥内部转发到 WebUI 的 `/api/shell`，返回 KernelSU 同构的
 * `{errno, stdout, stderr}` JSON —— 模块代码不需要任何改动。
 *
 * 用 android.webkit 而非第三方 webview 插件，维持项目零第三方依赖。
 */
class ModuleWebUIActivity : Activity() {

    companion object {
        const val EXTRA_MODULE = "module"
        const val EXTRA_URL = "url"

        /** WebUI 访问密钥：页面本身与桥里的特权调用都要过鉴权。 */
        const val EXTRA_TOKEN = "token"
    }

    private lateinit var web: WebView

    /** 本次打开携带的访问密钥（空串 = 未设置，页面会拿到 403）。 */
    private var token: String = ""

    @SuppressLint("SetJavaScriptEnabled")
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        val module = intent.getStringExtra(EXTRA_MODULE).orEmpty()
        val url = intent.getStringExtra(EXTRA_URL).orEmpty()
        token = intent.getStringExtra(EXTRA_TOKEN).orEmpty()
        title = module

        web = WebView(this)
        setContentView(web)

        with(web.settings) {
            javaScriptEnabled = true
            domStorageEnabled = true
            // 页面全在 127.0.0.1，没有跨文件需求，文件访问保持关闭
            allowFileAccess = false
        }
        web.webViewClient = WebViewClient()
        web.addJavascriptInterface(Bridge(), "ksu")
        // 页面请求也要带密钥（服务端不再允许空密钥放行）
        val fullUrl = if (token.isNotEmpty() && !url.contains("token=")) {
            url + (if (url.contains("?")) "&" else "?") +
                "token=" + java.net.URLEncoder.encode(token, "UTF-8")
        } else {
            url
        }
        web.loadUrl(fullUrl)
    }

    /** 系统返回键先退 WebView 历史，再关页面。 */
    @Deprecated("Deprecated in Java")
    override fun onBackPressed() {
        if (this::web.isInitialized && web.canGoBack()) {
            web.goBack()
        } else {
            super.onBackPressed()
        }
    }

    /**
     * KernelSU WebUI 的 JS 桥。
     *
     * `exec` 有两种调用形态：
     *  - 同步：`JSON.parse(ksu.exec(cmd))` → `{errno, stdout, stderr}`
     *  - 回调：`ksu.exec(cmd, "{}", "回调函数名")` → 完成后调用该全局函数
     *   （KernelSU 的原生实现是同步阻塞调用，这里为了不卡 WebView 线程，
     *    回调形态走异步 + evaluateJavascript 回填）
     */
    inner class Bridge {

        private fun httpPost(url: String): String = try {
            val conn = java.net.URL(url).openConnection() as java.net.HttpURLConnection
            conn.requestMethod = "POST"
            conn.connectTimeout = 5_000
            conn.readTimeout = 60_000
            conn.doOutput = true
            conn.setRequestProperty("Content-Length", "0")
            // 特权接口需要密钥；模块页面无需关心，桥替它带上
            if (token.isNotEmpty()) {
                conn.setRequestProperty("X-Token", token)
            }
            conn.inputStream.bufferedReader().use { it.readText() }
        } catch (e: Exception) {
            JSONObject()
                .put("ok", false)
                .put("msg", "请求失败：${e.message}")
                .toString()
        }

        private fun toKsuResult(response: String): String = try {
            val o = JSONObject(response)
            JSONObject()
                .put("errno", if (o.optBoolean("ok")) 0 else 1)
                .put("stdout", o.optString("msg"))
                .put("stderr", "")
                .toString()
        } catch (_: Exception) {
            JSONObject()
                .put("errno", -1).put("stdout", "").put("stderr", "响应解析失败")
                .toString()
        }

        /** 同步执行：返回 `{errno, stdout, stderr}` JSON 字符串。 */
        @JavascriptInterface
        fun exec(cmd: String): String {
            val url = "http://127.0.0.1:8537/api/shell?cmd=" +
                java.net.URLEncoder.encode(cmd, "UTF-8")
            return toKsuResult(httpPost(url))
        }

        /** KernelSU 兼容形态：执行后回调全局函数。 */
        @JavascriptInterface
        fun execCallback(cmd: String, callback: String) {
            val webRef = web
            Thread {
                val result = exec(cmd)
                runOnUiThread {
                    webRef.evaluateJavascript(
                        "javascript:(window['$callback']||function(){})($result)",
                        null,
                    )
                }
            }.start()
        }

        @JavascriptInterface
        fun toast(msg: String) {
            runOnUiThread {
                android.widget.Toast.makeText(
                    this@ModuleWebUIActivity,
                    msg,
                    android.widget.Toast.LENGTH_SHORT,
                ).show()
            }
        }

        /** KernelSU WebUI 会调用的全屏切换；这里保留 API 形状即可。 */
        @JavascriptInterface
        fun fullScreen(enable: Boolean) {
            runOnUiThread {
                if (enable) {
                    window.decorView.systemUiVisibility =
                        android.view.View.SYSTEM_UI_FLAG_FULLSCREEN
                } else {
                    window.decorView.systemUiVisibility = 0
                }
            }
        }
    }
}

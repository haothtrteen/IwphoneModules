package com.shellmgr.shell_manager

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import androidx.core.app.RemoteInput
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

/**
 * 接收通知里输入的配对码，完成配对。
 *
 * ## 流程（收到配对码之后）
 *
 * 1. **先扫端口**：配对端口只在配对界面打开期间存在，用户既然能提交配对码，
 *    说明界面大概率还开着 —— 这时候用 mDNS 扫 `_adb-tls-pairing._tcp` 最容易命中。
 *    （这也是把「端口发现」推迟到这一步的原因：不用在后台一直扫，省电也不怕进程被杀）
 * 2. 扫到端口 → `adb pair 127.0.0.1:<端口> <配对码>`
 * 3. 成功 → 顺手 `adb tcpip 5555` 把固定端口写进 persist 属性
 * 4. 发结果通知；App 页面回到前台后轮询 `isProvisioned` 即可感知
 *
 * ## 线程
 *
 * 扫描（等 mDNS 回调）+ 配对（起 adb 进程）都要几秒，**不能在 onReceive 主线程做**。
 * 用 `goAsync()` 拿到 [PendingResult] 交给后台线程，做完再 finish ——
 * 这是广播里做异步工作的标准姿势，也保住了进程的优先级不被立刻降级。
 */
class PairingReceiver : BroadcastReceiver() {

    companion object {
        const val ACTION_SUBMIT = "com.shellmgr.shell_manager.action.PAIRING_SUBMIT"
        private const val SCAN_TIMEOUT_MS = 15_000L
    }

    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != ACTION_SUBMIT) return

        val bundle = RemoteInput.getResultsFromIntent(intent)
        val code = bundle?.getCharSequence(PairingNotify.EXTRA_PAIRING_CODE)
            ?.toString()?.trim().orEmpty()

        val ctx = context.applicationContext
        if (code.isEmpty()) {
            PairingNotify.postResult(ctx, false, "没有收到配对码，请重新输入")
            return
        }

        val pending = goAsync()
        Thread {
            var ok = false
            var msg = ""
            try {
                // 1) 找配对端口（此时配对界面应该还开着）
                var port: Int? = null
                val latch = CountDownLatch(1)
                PairingNsd.findPairingPort(ctx, SCAN_TIMEOUT_MS) { p ->
                    port = p
                    latch.countDown()
                }
                latch.await(SCAN_TIMEOUT_MS + 2_000, TimeUnit.MILLISECONDS)

                if (port == null) {
                    ok = false
                    msg = "没有发现配对服务。请确认「使用配对码配对设备」界面仍然开着，再提交一次。"
                } else {
                    // 2) 配对
                    val r = AdbBootstrap.pair(ctx, port.toString(), code)
                    ok = r.ok
                    msg = r.message

                    // 3) 配对成功 → 立刻固定端口，整套自启链路就齐了
                    if (ok) {
                        val fixed = AdbBootstrap.ensureFixedPort(ctx)
                        msg = if (fixed.ok) {
                            "配对成功，并已固定 ADB 端口 ${AdbBootstrap.CONNECT_PORT}。" +
                                "之后每次开机 App 都会自动重连。"
                        } else {
                            "配对成功，但固定端口失败：${fixed.message}"
                        }
                    }
                }
            } catch (e: Exception) {
                ok = false
                msg = "配对异常：${e.javaClass.simpleName}: ${e.message}"
            }

            PairingNotify.postResult(ctx, ok, msg)
            try {
                pending.finish()
            } catch (_: Exception) {
            }
        }.start()
    }
}

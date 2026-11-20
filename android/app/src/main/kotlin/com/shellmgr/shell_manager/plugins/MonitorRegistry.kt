package com.shellmgr.shell_manager.plugins

import android.content.Context
import android.os.Handler
import android.os.Looper
import java.util.concurrent.ConcurrentHashMap

/**
 * 监视器注册与调度。
 *
 * - 订阅计数：首个订阅才 startListening，最后退订才 stopListening
 *   （借鉴 vFlow ListeningTriggerHandler）；
 * - 防抖：连续 N 次同向探测才改变状态；
 * - 节流：COOLING / MAX_REACHED 两态防高频事件刷屏；
 * - 熔断：10 分钟内同一对象恢复超过 10 次则停用该监视器。
 */
class MonitorRegistry(private val ctx: Context) {
    private val plugins = ConcurrentHashMap<String, MonitorPlugin>()
    private val states = ConcurrentHashMap<String, MonitorState>()
    private val subscribers = ConcurrentHashMap<String, Int>()
    private val failStreak = ConcurrentHashMap<String, Int>()
    private val recoverCount = ConcurrentHashMap<String, Pair<Int, Long>>()
    private val main = Handler(Looper.getMainLooper())
    private val tickers = ConcurrentHashMap<String, Runnable>()

    /**
     * 探测线程。
     *
     * ★ 为什么不在主线程探测：probe 里是实打实的 adb 调用（起进程、等输出，
     * 200ms~2s 不等）。以前监视器只在事件日志页打开时被订阅，卡一下没人注意；
     * 现在武装的自动化会**长期**订阅监视器，主线程每 15 秒卡一次是不能接受的。
     */
    private val io = java.util.concurrent.Executors.newSingleThreadExecutor { r ->
        Thread(r, "iwphone-monitor").apply { isDaemon = true }
    }

    /** 防重入：上一次探测还没回来就不再排新的。 */
    private val inflight = ConcurrentHashMap<String, Boolean>()

    fun register(p: MonitorPlugin) {
        if (plugins.containsKey(p.id)) return
        plugins[p.id] = p
        states[p.id] = MonitorState.UNKNOWN
        subscribers[p.id] = 0
        p.onRegister(ctx, PlatformEventBus)
        PlatformEventBus.publish(PlatformEvent(
            id = "monitor:${p.id}", reason = "registered", from = null, to = "UNKNOWN",
        ))
    }

    fun unregister(id: String) {
        val p = plugins.remove(id) ?: return
        stopListening(id)
        tickers.remove(id)?.let { main.removeCallbacks(it) }
        p.onUnregister(ctx)
        states.remove(id)
        subscribers.remove(id)
        PlatformEventBus.publish(PlatformEvent(id = "monitor:$id", reason = "unregistered"))
    }

    /** 订阅监视器：首个订阅才真正开始监听与轮询。 */
    fun subscribe(id: String): Boolean {
        if (!plugins.containsKey(id)) return false
        val n = (subscribers[id] ?: 0) + 1
        subscribers[id] = n
        if (n == 1) {
            plugins[id]?.startListening(ctx)
            startTicker(id)
        }
        return true
    }

    fun unsubscribe(id: String) {
        val n = (subscribers[id] ?: 0) - 1
        if (n <= 0) {
            subscribers[id] = 0
            stopListening(id)
        } else {
            subscribers[id] = n
        }
    }

    private fun stopListening(id: String) {
        plugins[id]?.stopListening(ctx)
        tickers.remove(id)?.let { main.removeCallbacks(it) }
    }

    private fun startTicker(id: String) {
        if (tickers.containsKey(id)) return
        val p = plugins[id] ?: return
        val tick = object : Runnable {
            override fun run() {
                if ((subscribers[id] ?: 0) > 0) {
                    // 丢到探测线程跑，探测没回来就跳过这一轮，不堆积
                    if (inflight.putIfAbsent(id, true) == null) {
                        io.execute {
                            try {
                                probe(id)
                            } catch (_: Exception) {
                            } finally {
                                inflight.remove(id)
                            }
                        }
                    }
                    main.postDelayed(this, p.defaultIntervalMs)
                } else {
                    tickers.remove(id)
                }
            }
        }
        tickers[id] = tick
        main.postDelayed(tick, p.defaultIntervalMs)
    }

    /**
     * 探测一次并推进状态机。
     * @param force 手动触发（忽略防抖），供 UI「立即刷新」使用
     */
    fun probe(id: String, force: Boolean = false): MonitorState {
        val p = plugins[id] ?: return MonitorState.UNKNOWN
        val r = try {
            p.probe(ctx)
        } catch (e: Exception) {
            ProbeResult(MonitorState.UNKNOWN, "probe error: ${e.message}")
        }
        val old = states[id] ?: MonitorState.UNKNOWN
        val new = if (force) r.state else debounce(id, old, r.state)
        if (new != old) transition(p, old, new, r.reason)
        return new
    }

    /** 连续 3 次同向才切换；RUNNING→DEGRADED 立即降级，恢复需 2 次确认。 */
    private fun debounce(id: String, old: MonitorState, proposed: MonitorState): MonitorState {
        if (old == proposed) return old
        if (proposed == MonitorState.DEGRADED || proposed == MonitorState.ERROR) return proposed
        if (old == MonitorState.DEGRADED && proposed == MonitorState.RUNNING) {
            val n = (failStreak[id] ?: 0) + 1
            failStreak[id] = n
            return if (n >= 2) { failStreak.remove(id); proposed } else old
        }
        val n = (failStreak[id] ?: 0) + 1
        failStreak[id] = n
        return if (n >= 3) { failStreak.remove(id); proposed } else old
    }

    private fun transition(p: MonitorPlugin, old: MonitorState, new: MonitorState, reason: String) {
        states[p.id] = new
        PlatformEventBus.publish(PlatformEvent(
            id = "monitor:${p.id}", kind = PlatformEvent.KIND_STATE,
            from = old.name, to = new.name, reason = reason,
            severity = when (new) {
                MonitorState.ERROR, MonitorState.MAX_REACHED -> PlatformEvent.SEVERITY_ERROR
                MonitorState.DEGRADED, MonitorState.COOLING -> PlatformEvent.SEVERITY_WARN
                else -> PlatformEvent.SEVERITY_INFO
            },
        ))

        // 恢复策略：ERROR 时尝试一次，10 分钟内超 10 次则熔断
        if (new == MonitorState.ERROR && !isCircuitBroken(p.id)) {
            val r = try {
                p.recover(ctx, old)
            } catch (e: Exception) {
                RecoveryResult(false, "recover error: ${e.message}")
            } ?: RecoveryResult(true, "无需恢复")
            PlatformEventBus.publish(PlatformEvent(
                id = "monitor:${p.id}", kind = PlatformEvent.KIND_ACTION,
                reason = r.message,
                severity = if (r.ok) PlatformEvent.SEVERITY_INFO else PlatformEvent.SEVERITY_WARN,
            ))
            if (!r.ok) bumpRecover(p.id)
        }
    }

    private fun isCircuitBroken(id: String): Boolean {
        val (n, ts) = recoverCount[id] ?: return false
        return if (System.currentTimeMillis() - ts > 600_000L) {
            recoverCount.remove(id)
            false
        } else {
            n >= 10
        }
    }

    private fun bumpRecover(id: String) {
        val (n, ts) = recoverCount[id] ?: Pair(0, System.currentTimeMillis())
        val base = if (System.currentTimeMillis() - ts > 600_000L) 0 else n
        recoverCount[id] = Pair(base + 1, System.currentTimeMillis())
    }

    fun state(id: String): MonitorState = states[id] ?: MonitorState.UNKNOWN
    fun all(): Map<String, MonitorState> = states.toMap()
    fun pluginIds(): List<String> = plugins.keys().toList()
}

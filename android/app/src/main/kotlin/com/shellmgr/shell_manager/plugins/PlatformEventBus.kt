package com.shellmgr.shell_manager.plugins

import android.os.Handler
import android.os.Looper
import java.util.concurrent.CopyOnWriteArrayList

/**
 * 统一事件总线（即时、无 replay、无 sticky）。
 *
 * 借鉴 vFlow ServiceStateBus 的语义，但**不引入 kotlinx.coroutines**——
 * 本项目约定零第三方依赖，用 JDK 的 CopyOnWriteArrayList + Handler 实现：
 * - 事件不缓存、不粘滞：晚订阅者收不到历史事件；
 * - 按 id 前缀过滤订阅；
 * - 发布线程不阻塞订阅回调（统一切到主线程执行）。
 */
data class PlatformEvent(
    val id: String,
    val kind: String = KIND_STATE,
    val from: String? = null,
    val to: String? = null,
    val reason: String = "",
    val severity: String = SEVERITY_INFO,
    val ts: Long = System.currentTimeMillis(),
    val payload: Map<String, String> = emptyMap(),
) {
    companion object {
        const val KIND_STATE = "state"
        const val KIND_ACTION = "action"
        const val KIND_AUDIT = "audit"
        const val KIND_ERROR = "error"

        const val SEVERITY_INFO = "info"
        const val SEVERITY_WARN = "warn"
        const val SEVERITY_ERROR = "error"
    }
}

fun interface EventSubscriber {
    fun onEvent(e: PlatformEvent)
}

private data class Subscription(val prefix: String, val subscriber: EventSubscriber)

object PlatformEventBus {
    private val subscriptions = CopyOnWriteArrayList<Subscription>()
    private val main = Handler(Looper.getMainLooper())

    /** 订阅；prefix 为空表示订阅全部。返回取消订阅的句柄。 */
    fun subscribe(prefix: String = "", subscriber: EventSubscriber): () -> Unit {
        val s = Subscription(prefix, subscriber)
        subscriptions.add(s)
        return { subscriptions.remove(s) }
    }

    /**
     * 发布事件：回调统一切主线程，发布方不等待。
     * 无订阅者时直接丢弃 —— 事件是即时的，不做缓存。
     */
    fun publish(e: PlatformEvent) {
        val targets = subscriptions.filter { it.prefix.isEmpty() || e.id.startsWith(it.prefix) }
        if (targets.isEmpty()) return
        main.post {
            targets.forEach { s ->
                try {
                    s.subscriber.onEvent(e)
                } catch (_: Exception) {
                    // 单个订阅者异常不能影响其它订阅者
                }
            }
        }
    }

    /** 便捷发布：只给 id / reason，其余用默认值。 */
    fun post(id: String, reason: String, severity: String = PlatformEvent.SEVERITY_INFO) {
        publish(PlatformEvent(id = id, reason = reason, severity = severity))
    }

    fun subscriberCount(): Int = subscriptions.size
}

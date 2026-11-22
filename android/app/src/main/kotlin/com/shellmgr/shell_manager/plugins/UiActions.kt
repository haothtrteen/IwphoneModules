package com.shellmgr.shell_manager.plugins

import android.graphics.Rect
import android.view.accessibility.AccessibilityNodeInfo
import java.util.ArrayDeque

/**
 * 从无障碍控件树里读文字 / 找控件。
 *
 * 这是 vFlow `find_element` / `ui_selector` / `find_until` 的最小可用版本：
 * 只做「读节点 → 匹配 → 给坐标」，不做变量系统与 GKD selector 语法。
 *
 * ★ 为什么走无障碍节点而不是 OCR：
 *   vFlow 的 OCR 用 Google ML Kit（text-recognition-chinese），是第三方依赖，
 *   与本项目「零第三方依赖」硬约束冲突。而绝大多数 App 的按钮/标题文字
 *   本来就在控件树上，读节点更准、更快、也不需要联网模型。
 *   图片里的字（验证码、Canvas 绘制）读不到，这是诚实的边界。
 *
 * 同进程调用：无障碍服务与工作流执行线程都在 App 进程内，直接取
 * [IwphoneAccessibilityService.instance]，不另开 Binder 通道。
 */

/** 一个可读节点的快照。只保留够用的字段，不持有 AccessibilityNodeInfo 引用。 */
data class UiNode(
    val text: String,
    val desc: String,
    val viewId: String,
    val cls: String,
    val x: Int,
    val y: Int,
    val clickable: Boolean,
) {
    /** 给结果/日志用的单行描述。 */
    fun label(): String = buildString {
        val t = text.ifEmpty { desc }.replace('\n', ' ').take(40)
        if (t.isNotEmpty()) append(t)
        val id = viewId.substringAfterLast('/')
        if (id.isNotEmpty()) {
            if (isNotEmpty()) append(' ')
            append('#').append(id)
        }
        if (isEmpty()) append(cls.substringAfterLast('.'))
        append(" @").append(x).append(',').append(y)
    }
}

data class WaitResult(
    val matched: Boolean,
    val node: UiNode?,
    val timedOut: Boolean,
)

object UiActions {

    const val MATCH_CONTAINS = "contains"
    const val MATCH_EXACT = "exact"
    const val MATCH_STARTS = "starts_with"
    const val MATCH_REGEX = "regex"

    fun isEnabled(): Boolean = IwphoneAccessibilityService.instance != null

    /** 匹配模式：默认包含（忽略大小写）；正则写错按不匹配处理，绝不抛异常打断工作流。 */
    private fun matches(value: String, pattern: String, mode: String): Boolean {
        if (pattern.isEmpty()) return false
        return when (mode) {
            MATCH_EXACT -> value == pattern
            MATCH_STARTS -> value.startsWith(pattern, ignoreCase = true)
            MATCH_REGEX -> try {
                Regex(pattern).containsMatchIn(value)
            } catch (_: Exception) {
                false
            }
            else -> value.contains(pattern, ignoreCase = true)
        }
    }

    /**
     * BFS 扫当前活跃窗口的控件树。
     *
     * 上限是硬性的：有些 WebView / 列表能挂几千个节点，不设边界会把后台线程拖死。
     * 同时用 identityHashCode 去重，防止畸形控件树成环。
     */
    fun dump(maxNodes: Int = 300, maxDepth: Int = 16): List<UiNode> {
        val svc = IwphoneAccessibilityService.instance ?: return emptyList()
        val root = try {
            svc.rootInActiveWindow
        } catch (_: Exception) {
            null
        } ?: return emptyList()

        val out = ArrayList<UiNode>()
        val queue = ArrayDeque<Pair<AccessibilityNodeInfo, Int>>()
        queue.addLast(root to 0)
        val seen = HashSet<Int>()
        val rect = Rect()

        try {
            while (queue.isNotEmpty() && out.size < maxNodes) {
                val (node, depth) = queue.removeFirst()
                if (!seen.add(System.identityHashCode(node))) continue

                val visible = try { node.isVisibleToUser } catch (_: Exception) { true }
                val text = (node.text ?: "").toString()
                val desc = (node.contentDescription ?: "").toString()
                val id = (node.viewIdResourceName ?: "").toString()
                val cls = (node.className ?: "").toString()

                if (visible && (text.isNotEmpty() || desc.isNotEmpty() || id.isNotEmpty())) {
                    val hasBounds = try {
                        node.getBoundsInScreen(rect)
                        true
                    } catch (_: Exception) {
                        false
                    }
                    if (hasBounds) {
                        out.add(UiNode(
                            text = text,
                            desc = desc,
                            viewId = id,
                            cls = cls,
                            x = rect.centerX(),
                            y = rect.centerY(),
                            clickable = try { node.isClickable } catch (_: Exception) { false },
                        ))
                    }
                }

                if (depth < maxDepth) {
                    val count = try { node.childCount } catch (_: Exception) { 0 }
                    for (i in 0 until count) {
                        val child = try { node.getChild(i) } catch (_: Exception) { null }
                        if (child != null) queue.addLast(child to depth + 1)
                    }
                }
            }
        } finally {
            try {
                root.recycle()
            } catch (_: Exception) {
            }
        }
        return out
    }

    /** 按文本（或 content-desc）与 view-id 组合查找；两个条件都填时要求同时满足。 */
    fun find(
        text: String,
        viewId: String,
        matchMode: String,
        maxNodes: Int = 300,
    ): UiNode? {
        val nodes = dump(maxNodes)
        for (n in nodes) {
            val textOk = text.isEmpty() || matches(n.text, text, matchMode) ||
                matches(n.desc, text, matchMode)
            if (!textOk) continue
            if (viewId.isEmpty() || matches(n.viewId, viewId, matchMode)) return n
        }
        return null
    }

    /**
     * 轮询等待文字出现 / 消失。
     *
     * 注意这里刻意不把「没找到」当成错误：调用方要看 [WaitResult.timedOut] 才知道
     * 是条件满足了，还是等超时了。
     */
    fun waitFor(
        text: String,
        viewId: String,
        matchMode: String,
        timeoutMs: Long,
        intervalMs: Long,
        appear: Boolean,
        maxNodes: Int = 300,
    ): WaitResult {
        val deadline = System.currentTimeMillis() + timeoutMs
        var lastHit: UiNode? = null
        while (true) {
            val hit = find(text, viewId, matchMode, maxNodes)
            lastHit = hit
            if (appear && hit != null) return WaitResult(true, hit, false)
            if (!appear && hit == null) return WaitResult(true, lastHit, false)

            if (System.currentTimeMillis() >= deadline) {
                return WaitResult(false, lastHit, true)
            }
            try {
                Thread.sleep(intervalMs.coerceIn(50, 5_000))
            } catch (_: InterruptedException) {
                return WaitResult(false, lastHit, true)
            }
        }
    }
}

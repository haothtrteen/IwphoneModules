package com.shellmgr.shell_manager

import android.content.Context
import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import android.os.Handler
import android.os.Looper

/**
 * 用 mDNS 发现 ADB 无线配对服务，拿到**配对端口**。
 *
 * ## 为什么端口要靠发现，而连接端口却可以写死 5555
 *
 * 「无线调试」的**连接**端口是动态的（而且不重启也会变），但它有两条出路：
 * legacy 的 5555 可以由 `adb tcpip 5555` 写进 persist 属性，跨重启保持 ——
 * 这是 App 平时自连用的通道。
 *
 * 而**配对**端口只在「使用配对码配对设备」界面打开期间存在，
 * 关掉就没了，没法固定 —— 只能在那几秒里发现它。
 *
 * 系统在这段时间会通过 mDNS 广播 `_adb-tls-pairing._tcp` 服务，
 * 用 [NsdManager] 订阅即可拿到端口。这也是 Shizuku 的做法。
 *
 * 用法（回调可能在主线程触发）：
 * ```
 * PairingNsd.findPairingPort(context) { port ->
 *     // port == null 表示超时没发现（多半是配对界面没开着）
 * }
 * ```
 */
object PairingNsd {

    /** ADB 无线配对服务的 mDNS 类型（系统约定）。 */
    private const val PAIRING_SERVICE_TYPE = "_adb-tls-pairing._tcp"

    /** ADB 无线调试「连接」服务的 mDNS 类型（动态端口，用于首次建立 transport）。 */
    private const val CONNECT_SERVICE_TYPE = "_adb-tls-connect._tcp"

    /**
     * 发现配对端口。
     *
     * [onResult] 一定被回调一次：拿到端口回传端口值，超时/失败回传 null。
     * 发现成功后立即停止扫描（端口已经到手，没有继续扫的必要）。
     */
    fun findPairingPort(
        context: Context,
        timeoutMs: Long = 12_000,
        onResult: (Int?) -> Unit,
    ) = findPort(context, PAIRING_SERVICE_TYPE, timeoutMs, onResult)

    /**
     * 发现无线调试的**连接端口**（`_adb-tls-connect._tcp`）。
     *
     * 配对只代表「adbd 记住了本机公钥」，并不会建立 transport；
     * 首次使用必须连上这个动态端口，才能执行 `adb tcpip 5555` 把端口固定下来。
     */
    fun findConnectPort(
        context: Context,
        timeoutMs: Long = 12_000,
        onResult: (Int?) -> Unit,
    ) = findPort(context, CONNECT_SERVICE_TYPE, timeoutMs, onResult)

    private fun findPort(
        context: Context,
        serviceType: String,
        timeoutMs: Long,
        onResult: (Int?) -> Unit,
    ) {
        val nsd = context.getSystemService(NsdManager::class.java)
        if (nsd == null) {
            onResult(null)
            return
        }

        // resolved / finished 保证 onResult 只回调一次，
        // 以及超时后不再处理迟到的发现结果
        var finished = false
        var listenerRef: NsdManager.DiscoveryListener? = null

        val main = Handler(Looper.getMainLooper())
        fun finish(port: Int?) {
            if (finished) return
            finished = true
            main.post {
                listenerRef?.let {
                    try {
                        nsd.stopServiceDiscovery(it)
                    } catch (_: Exception) {
                        // 没开始成功/已停止都会抛，忽略
                    }
                }
                onResult(port)
            }
        }

        val listener = object : NsdManager.DiscoveryListener {
            override fun onDiscoveryStarted(serviceType: String?) {}
            override fun onDiscoveryStopped(serviceType: String?) {}
            override fun onServiceLost(serviceInfo: NsdServiceInfo?) {}
            override fun onStartDiscoveryFailed(serviceType: String?, errorCode: Int) = finish(null)
            override fun onStopDiscoveryFailed(serviceType: String?, errorCode: Int) {}

            override fun onServiceFound(serviceInfo: NsdServiceInfo) {
                if (finished) return
                // 拿端口必须 resolve —— found 里只有服务名
                nsd.resolveService(serviceInfo, object : NsdManager.ResolveListener {
                    override fun onResolveFailed(info: NsdServiceInfo?, errorCode: Int) {
                        // 单个服务解析失败不放弃，继续等其它广播
                    }

                    override fun onServiceResolved(info: NsdServiceInfo?) {
                        if (finished) return
                        val port = info?.port ?: 0
                        finish(if (port in 1..65535) port else null)
                    }
                })
            }
        }
        listenerRef = listener

        try {
            nsd.discoverServices(serviceType, NsdManager.PROTOCOL_DNS_SD, listener)
        } catch (_: Exception) {
            finish(null)
            return
        }

        // 配对界面关掉服务就没了，扫不到也别拖着一颗定时器
        main.postDelayed({ finish(null) }, timeoutMs)
    }
}

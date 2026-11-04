package com.shellmgr.shell_manager

import android.content.Context
import android.content.Intent
import android.os.Process

/**
 * 重启本 App。
 *
 * 安装完成后框架状态变了（新守护、新密钥、新版本标记），最干净的收尾是
 * 让进程整体重来一遍：main() 会重新探测框架、重新装载密钥，不需要在各页面
 * 里到处手工 setState。
 *
 * 做法与 Magisk 安装完的「重启」按钮同理，只是重启的是本 App 而非系统。
 */
object AppRestarter {
    fun restart(ctx: Context) {
        val intent = ctx.packageManager.getLaunchIntentForPackage(ctx.packageName)
            ?: return
        intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TASK)
        ctx.startActivity(intent)
        // 杀掉当前进程，避免旧状态（已配置的 HTTP 客户端、缓存的框架状态）残留
        Process.killProcess(Process.myPid())
    }
}

package com.shellmgr.shell_manager

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.provider.Settings
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * Flutter ↔ 原生的桥：仅承担「所有文件访问」权限的查询与申请。
 *
 * 为什么必须落到原生：
 *   Android 11+ 的 MANAGE_EXTERNAL_STORAGE **无法通过运行时弹窗授予**，
 *   只能跳系统设置页（Settings.ACTION_MANAGE_APP_ALL_FILES_ACCESS_PERMISSION），
 *   这属于平台能力，纯 Dart 做不到。
 *   这里用 Flutter 内置的 MethodChannel 实现，不引入任何第三方插件，
 *   保持项目「零第三方依赖」的约定。
 *
 * 各版本策略：
 *   - API 30+ (Android 11+)  → 检查/申请 MANAGE_EXTERNAL_STORAGE（跳设置页）
 *   - API 23..29 (Android 6–10) → READ_EXTERNAL_STORAGE 常规运行时弹窗
 *   - API < 23                → 无需申请
 */
class MainActivity : FlutterActivity() {

    private companion object {
        const val CHANNEL = "shellmgr/storage"
        const val REQ_LEGACY_STORAGE = 1001
        const val REQ_PICK_MODULE = 1002
    }

    /** 传统路径（API ≤ 29）的异步申请结果，等待 onRequestPermissionsResult 回填。 */
    private var pendingResult: MethodChannel.Result? = null

    /** 模块包文件选择的挂起结果（onActivityResult 回填）。 */
    private var pendingPick: MethodChannel.Result? = null

    /** 「开机自启」通道（通知权限 / 自启开关 / adb 配对与拉起）。 */
    private val autostart = AutostartChannel(this)

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "getStatus" -> result.success(storageStatus())
                    "request" -> requestStorage(result)
                    "pickFile" -> {
                        pendingPick = result
                        pickFile()
                    }
                    else -> result.notImplemented()
                }
            }

        autostart.register(flutterEngine.dartExecutor.binaryMessenger)
    }

    /**
     * 当前存储权限状态。
     * 返回 "granted" / "denied" / "notRequired"。
     */
    private fun storageStatus(): String {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            return if (Environment.isExternalStorageManager()) "granted" else "denied"
        }
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) {
            return "notRequired"
        }
        val granted = ContextCompat.checkSelfPermission(
            this,
            Manifest.permission.READ_EXTERNAL_STORAGE,
        ) == PackageManager.PERMISSION_GRANTED
        return if (granted) "granted" else "denied"
    }

    /**
     * 发起授权。
     *
     * Android 11+ 跳系统设置页；低版本走常规运行时申请。
     * 两者都是异步的，此处立即回 true 表示「已把用户送进授权流程」，
     * 真实结果由 Dart 侧回到前台后再调 [storageStatus] 复查。
     */
    private fun requestStorage(result: MethodChannel.Result) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            val ok = try {
                startActivity(
                    Intent(
                        Settings.ACTION_MANAGE_APP_ALL_FILES_ACCESS_PERMISSION,
                        Uri.parse("package:$packageName"),
                    ),
                )
                true
            } catch (_: Exception) {
                // 少数 ROM 未提供该设置页，退回应用详情页让用户手动开
                try {
                    startActivity(
                        Intent(
                            Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
                            Uri.parse("package:$packageName"),
                        ),
                    )
                    true
                } catch (_: Exception) {
                    false
                }
            }
            result.success(ok)
            return
        }

        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) {
            result.success(true)
            return
        }

        pendingResult = result
        ActivityCompat.requestPermissions(
            this,
            arrayOf(Manifest.permission.READ_EXTERNAL_STORAGE),
            REQ_LEGACY_STORAGE,
        )
    }

    /**
     * 打开系统文件选择器（SAF），让用户从手机存储里选模块包。
     *
     * 选中的文件会被复制进 App 缓存目录，结果通过 [pendingPick] 回给 Dart：
     * `{ok: true, path: <缓存路径>, name: <显示名>}`。
     * 之后的「推到设备 module/ 目录」由 AdbBootstrap.importPackage 负责。
     */
    private fun pickFile() {
        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
            addCategory(Intent.CATEGORY_OPENABLE)
            type = "application/octet-stream"
            putExtra(
                Intent.EXTRA_MIME_TYPES,
                arrayOf("application/zip", "application/octet-stream"),
            )
        }
        try {
            startActivityForResult(intent, REQ_PICK_MODULE)
        } catch (e: Exception) {
            pendingPick?.success(mapOf("ok" to false, "msg" to "无法打开文件选择器：${e.message}"))
            pendingPick = null
        }
    }

    override fun onActivityResult(
        requestCode: Int,
        resultCode: Int,
        data: Intent?,
    ) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode != REQ_PICK_MODULE) return

        val result = pendingPick
        pendingPick = null
        if (result == null) return

        if (resultCode != RESULT_OK || data?.data == null) {
            result.success(mapOf("ok" to false, "msg" to "未选择文件"))
            return
        }

        try {
            val uri = data.data!!
            // 文件名从 content provider 查；查不到就用时间戳兜底
            var name = "import_${System.currentTimeMillis()}.iwp"
            contentResolver.query(uri, null, null, null, null)?.use { c ->
                val idx = c.getColumnIndex(android.provider.OpenableColumns.DISPLAY_NAME)
                if (idx >= 0 && c.moveToFirst()) {
                    c.getString(idx)?.let { name = it }
                }
            }
            // 名字兜底成 .iwp，保证 list_packages 能认出来
            if (!name.endsWith(".iwp")) {
                name = name.substringBeforeLast('.') + ".iwp"
            }

            val out = java.io.File(cacheDir, name)
            contentResolver.openInputStream(uri)!!.use { input ->
                out.outputStream().use { output -> input.copyTo(output) }
            }
            result.success(
                mapOf("ok" to true, "path" to out.absolutePath, "name" to name),
            )
        } catch (e: Exception) {
            result.success(mapOf("ok" to false, "msg" to "读取文件失败：${e.message}"))
        }
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)

        // 通知权限的申请由 AutostartChannel 自己回填
        if (autostart.onRequestPermissionsResult(requestCode, grantResults)) return

        if (requestCode != REQ_LEGACY_STORAGE) return
        val granted = grantResults.isNotEmpty() &&
            grantResults[0] == PackageManager.PERMISSION_GRANTED
        pendingResult?.success(granted)
        pendingResult = null
    }
}

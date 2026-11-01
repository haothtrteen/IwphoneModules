package com.shellmgr.shell_manager

import android.content.Context
import java.io.File
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

/**
 * 免 root 自启的 ADB 驱动层。
 *
 * ## 背景
 *
 * iwphone 框架是「以 shell 身份运行」的 shell 脚本集合，本身没有任何自启能力 ——
 * 进程随重启消失。市面上常见做法（Shizuku）在**非 root** 设备上重启后同样需要
 * 用户手动重跑 adb 命令，做不到自动重连。
 *
 * 本类利用一个随 APK 携带的、**Android NDK 编译**的 `adb` 可执行文件
 * （打包为 `jniLibs/arm64-v8a/libadb.so`，安装后解压到 `nativeLibraryDir`），
 * 由 App 自己连自己，把「重启后重新拿 shell」这一步自动化。
 *
 * ## 关键机制（均为实机验证过的结论，改动前务必理解）
 *
 * 1. **走 legacy 5555，不走无线调试。**
 *    - `adb_wifi_enabled`（无线调试开关）**重启后不保持**，且其端口动态变化；
 *      更要命的是它构成死结：开无线调试需要 shell，而重启后没 shell。
 *    - `adb tcpip 5555` 是**主机发给 adbd 的协议指令**（不是 shell 命令），
 *      它会写 `persist.adb.tcp.port=5555`，该属性**跨重启保持**，
 *      于是开机后 adbd 自动监听 `*:5555`，App 无需任何用户操作即可连上。
 *
 * 2. **密钥跨重启保持。** adbd 的已授权密钥存在系统侧，重启后依然有效，
 *    因此配对只需做一次，之后每次开机都是「静默重认证」。
 *
 * 3. **拉起框架必须带 `&`。** 实机验证：
 *    ```
 *    ❌ nohup setsid -d sh Main.sh >/dev/null 2>&1 </dev/null
 *    ✅ nohup setsid -d sh Main.sh >/dev/null 2>&1 </dev/null &
 *    ```
 *    少了 `&`，进程会在 adb 会话结束时被连带杀掉。
 *
 * 4. **不要在本类之外重启 adbd**（`adb usb` / `adb tcpip` / 开关无线调试）。
 *    adbd 退出会清理自己 spawn 的进程树 —— 即使框架已 reparent 到 init
 *    （PPID=1）、且用了 setsid + nohup，**照样会被杀掉**。
 *    所以「拉起框架后再关掉 5555 端口」是不可行的：关端口 = 重启 adbd = 框架死。
 *
 * ## 一次性配置
 *
 * 首次使用需要让 adbd 认识本 App 的密钥：[pair] 走无线调试配对
 * （用户在开发者选项里取配对码），成功后立即 [ensureFixedPort] 把 5555 固定下来。
 */
object AdbBootstrap {

    /**
     * 框架目录（shell 脚本、webui、runtime 都在这）。
     *
     * ★ 与 [IWPHONE_ROOT] 是**同一个路径**，这是刻意的：全项目只认
     *   `/data/local/tmp/iwphone/` 一个目录，代码和运行时状态同处一处。
     *   历史上有过 `iwphone_modrunner_v3_slim/iwphone_modrunner_v3` 这层嵌套，
     *   结果「手动把框架推到 iwphone/ 的人」和「App 认为该看 slim/ 的人」
     *   各说各话，一升级就报各种错。现在没有第二套路径了。
     */
    const val FRAME_DIR = "/data/local/tmp/iwphone"

    /** 框架运行时根目录（模块、锁、状态、快照都在这里，与代码同级）。 */
    const val IWPHONE_ROOT = "/data/local/tmp/iwphone"

    /**
     * 旧版布局的残留目录，部署时顺手删掉。
     *
     * 里面只有框架代码副本（无用户数据），删掉是安全的；留着会让排障时
     * 看到两套「看起来都像框架」的目录。
     */
    const val LEGACY_FRAME_PARENT = "/data/local/tmp/iwphone_modrunner_v3_slim"

    /**
     * WebUI 访问密钥文件（APatch 式：用户自己设密钥）。
     *
     * 服务端按 mtime 读取本文件做鉴权 —— 所以改密钥只需覆盖这个文件，
     * **不用重启 WebUI**。文件权限 600、属主 shell：App 进程本身读不到，
     * 只能经 adb（shell 身份）读写，天然与"已配对"这一前提绑定。
     */
    const val WEBUI_TOKEN_FILE = "$IWPHONE_ROOT/state/webui_token"

    /** 框架守护入口。 */
    const val MAIN_SH = "$FRAME_DIR/Main.sh"

    /** 框架自带的卸载脚本。 */
    const val UNINSTALL_SH = "$FRAME_DIR/uninstall.sh"

    /** WebUI 启动脚本。 */
    const val WEBUI_START = "$FRAME_DIR/webui/webui_start.sh"

    /**
     * 随 APK 内置的框架包（assets/framework.bin，约 12MB，内容是 tar.gz）。
     *
     * tar.gz 解开后的顶层目录就叫 `iwphone/`，解到 /data/local/tmp 即得到
     * `/data/local/tmp/iwphone/…`，与 [FRAME_DIR] 完全一致 ——
     * 所以直接解压就完成部署，不需要再搬一次目录。
     *
     * ★ 文件名故意叫 `.bin` 而不是 `.tar.gz`：AAPT 打包时会**解压 .gz 资产
     *   并去掉 .gz 后缀**（实测得到 assets/framework.tar，35MB 未压缩），
     *   导致 assets.open("framework.tar.gz") 找不到文件。换个扩展名就绕开了。
     *
     * 有了它，App 就能**完全脱离电脑**完成整套流程：
     * 配对 → 拿 shell → 部署框架 → 拉起框架。缺什么补什么，可反复执行（即「修复」）。
     */
    const val FW_ASSET = "framework.bin"

    /** 框架部署根目录的父级（tar 里的顶层目录名与之对应）。 */
    const val FW_ROOT_PARENT = "/data/local/tmp"

    /** 部署用临时包在设备上的位置。 */
    private const val FW_TAR_ON_DEVICE = "/data/local/tmp/.iwphone_framework.tar.gz"

    /** 固定的 ADB TCP 端口 —— 必须与 `adb tcpip` 写入的 persist 属性一致。 */
    const val CONNECT_PORT = 5555

    private const val TARGET = "127.0.0.1:$CONNECT_PORT"

    /** 访问密钥最小长度。 */
    const val MIN_TOKEN_LEN = 8

    /** 单条 adb 命令的超时。 */
    private const val CMD_TIMEOUT_MS = 20_000L

    // ---------------- 路径 ----------------

    /**
     * 随 APK 携带的 adb 可执行文件。
     *
     * 之所以能执行：`build.gradle.kts` 里开了 `jniLibs.useLegacyPackaging = true`，
     * native 库会被解压到 `nativeLibraryDir` 并带可执行位。
     * （若该开关被关掉，.so 会直接留在 APK 内映射运行，`ProcessBuilder` 会失败。）
     */
    fun adbFile(ctx: Context): File =
        File(ctx.applicationInfo.nativeLibraryDir, "libadb.so")

    /**
     * adb 的 HOME。
     *
     * 必须是 App 私有目录：adb 会在此创建 `.android/adbkey`（私钥）与 `adbkey.pub`。
     * 放在私有目录里既满足「密钥持久保存」，也避免被其他应用读取。
     */
    fun homeDir(ctx: Context): File =
        File(ctx.filesDir, "adbhome").apply { mkdirs() }

    /** App 自己的 adb 私钥。存在即代表「已生成密钥」（不代表已授权）。 */
    fun keyFile(ctx: Context): File =
        File(File(homeDir(ctx), ".android"), "adbkey")

    /** 检查用具：adb 文件与密钥是否就位。 */
    fun isProvisioned(ctx: Context): Boolean =
        adbFile(ctx).exists() && keyFile(ctx).exists()

    /**
     * 框架是否已经部署在设备上。
     *
     * 以 `Main.sh` 是否存在为准 —— 它是唯一的启动入口，
     * 其它脚本缺失时重新部署一次即可修复。
     */
    /**
     * 确保已连上 127.0.0.1:5555。
     *
     * 所有「探测设备状态」的调用都必须先走这一步：App 冷启动时 adb server
     * 的设备列表是空的，不 connect 直接 `-s` 会得到「device not found」，
     * 探测结果全部失真（会把已部署误报成未部署）。
     *
     * 幂等：已连接时 adb 返回 "already connected to …"，同样算成功。
     */
    /**
     * 确保与设备的连接**真的可用**。
     *
     * 曾经的坑：只看 `adb connect` 的返回文本判断成功，
     * 而 adb 对「条目还在但实际已断」的 transport 会说 "already connected"，
     * 于是判定成功，紧接着 push 就报
     * `error: failed to get feature set: closed`。
     *
     * 现在先 `get-state` 探活：不是 device 就 disconnect + connect 重来，
     * 连上后再确认一次。代价是多一条命令（几十毫秒），换来不会在半死的连接上操作。
     */
    private fun ensureConnected(ctx: Context): Boolean {
        // 1) 探活
        if (transportAlive(ctx)) return true

        // 2) 清掉 adb server 里的死条目再重连
        run(ctx, listOf("disconnect", TARGET), timeoutMs = 10_000)
        val c = run(ctx, listOf("connect", TARGET), timeoutMs = 20_000)
        if (!c.message.contains("connected to", ignoreCase = true)) {
            android.util.Log.d(
                "AdbBootstrap",
                "ensureConnected: connect 失败 [${c.message.take(140)}]",
            )
            return false
        }

        // 3) 连上后再确认一次，避免"连上了但没认证"
        if (transportAlive(ctx)) return true
        android.util.Log.d("AdbBootstrap", "ensureConnected: 连上但 get-state 仍异常")
        return false
    }

    /** `adb -s <target> get-state` 是否返回 device。 */
    private fun transportAlive(ctx: Context): Boolean {
        val r = run(ctx, listOf("-s", TARGET, "get-state"), timeoutMs = 10_000)
        return r.ok && r.message.trim().equals("device", ignoreCase = true)
    }

    /**
     * 建立一条可用的 transport，并确保最终连在 127.0.0.1:5555 上。
     *
     * **首次使用的引导闭环**：
     * ```
     * 配对（adbd 记住公钥，但不会建立 transport）
     *   → 发现无线调试的动态连接端口（_adb-tls-connect._tcp）
     *   → adb connect 该端口，验证 shell 身份
     *   → adb tcpip 5555（写 persist.adb.tcp.port，前提是已有 transport）
     *   → 重新 connect 127.0.0.1:5555 并验证
     * ```
     *
     * 早期版本缺了「发现/连接动态端口」这一步：配对完直接 push / tcpip，
     * 设备列表是空的，于是报 adb: error: failed to get feature set:
     * no devices/emulators found —— 这不是 ROM 的问题，任何设备首次配置都会这样。
     */
    fun ensureTransport(ctx: Context): Result {
        if (transportAlive(ctx)) return Result(true, "已连接 $TARGET")

        // 1) 先试固定端口（可能之前已经固定过）
        val fixed = connectAndVerify(ctx, TARGET)
        if (fixed.ok) return fixed

        // 2) 发现无线调试的动态连接端口
        val port = discoverConnectPort(ctx)
        if (port == null) {
            return Result(
                false,
                "没有发现无线调试的连接端口：请确认「无线调试」开关保持打开、"
                    + "屏幕保持亮着，然后重试",
            )
        }
        val dynamic = connectAndVerify(ctx, "127.0.0.1:$port")
        if (!dynamic.ok) return dynamic

        // 3) 已经有 transport，才能把端口固定到 5555（写 persist 属性）
        val tcpip = run(ctx, listOf("tcpip", CONNECT_PORT.toString()), timeoutMs = 30_000)
        if (!tcpip.ok) {
            return Result(false, "固定端口失败：${tcpip.message}")
        }

        // 4) tcpip 会重启 adbd，等它重新在 5555 监听并连接
        val deadline = System.currentTimeMillis() + 20_000
        var last = ""
        while (System.currentTimeMillis() < deadline) {
            Thread.sleep(1_000)
            val r = connectAndVerify(ctx, TARGET)
            if (r.ok) return Result(true, "已连接 $TARGET（端口已固定为 $CONNECT_PORT）")
            last = r.message
        }
        return Result(false, "端口已切到 TCP 模式，但未能连接到 $TARGET：$last")
    }

    /** 用 mDNS 发现无线调试的动态连接端口（阻塞等待结果）。 */
    private fun discoverConnectPort(ctx: Context, timeoutMs: Long = 12_000): Int? {
        var result: Int? = null
        val latch = CountDownLatch(1)
        PairingNsd.findConnectPort(ctx, timeoutMs) { port ->
            result = port
            latch.countDown()
        }
        latch.await(timeoutMs + 2_000, TimeUnit.MILLISECONDS)
        return result
    }

    /** 连接指定 serial 并验证真的拿到了 shell 身份。 */
    private fun connectAndVerify(ctx: Context, serial: String): Result {
        val c = run(ctx, listOf("connect", serial), timeoutMs = 20_000)
        val text = c.message.trim()
        val connected = c.ok && (
            text.contains("connected to", ignoreCase = true) ||
                text.contains("already connected", ignoreCase = true)
            )
        if (!connected) return Result(false, "连接 $serial 失败：$text")

        // 连接成功 ≠ 认证通过：必须实际取一次身份
        val id = run(ctx, listOf("-s", serial, "shell", "id"), timeoutMs = 15_000)
        if (!id.ok) return Result(false, "已连接但无法执行 shell：${id.message}")
        val out = id.message
        if (!out.contains("uid=2000") && !out.contains("shell")) {
            return Result(false, "未取得 shell 身份：$out")
        }
        return Result(true, "已取得 shell 身份（$serial）")
    }

    /**
     * 完全卸载框架 —— 不经 WebUI 的备用通道。
     *
     * WebUI 未运行（守护进程已停）时 HTTP 通道不可用，但卸载不应该被卡住：
     * 这里直接以 shell 身份执行框架自带的 uninstall.sh —— 它先停 WebUI / 守护进程 /
     * 全部模块，再删运行时目录、日志与状态镜像，与 WebUI 那条路径行为一致。
     *
     * 脚本缺失（框架源文件被误删）时兜底直接删运行时目录；那种情况下已运行的模块
     * 无法优雅停止，属于尽力而为。
     */
    fun uninstallFramework(ctx: Context): Result {
        val t = ensureTransport(ctx)
        if (!t.ok) {
            return Result(false, "adb 未连接：${t.message}")
        }
        val r = run(
            ctx,
            listOf("-s", TARGET, "shell", "test -f $UNINSTALL_SH && sh $UNINSTALL_SH y"),
            timeoutMs = 60_000,
        )
        if (r.ok) return Result(true, "卸载完成")

        // 兜底：脚本不在时至少把运行时、日志与状态镜像删掉
        val fallback = run(
            ctx,
            listOf(
                "-s", TARGET, "shell",
                "rm -rf $IWPHONE_ROOT /sdcard/iwphone/logs /sdcard/iwphone/state",
            ),
            timeoutMs = 20_000,
        )
        return if (fallback.ok) {
            Result(true, "卸载完成（脚本缺失，已直接删除运行时目录）")
        } else {
            Result(false, fallback.message)
        }
    }

    fun isFrameworkInstalled(ctx: Context): Boolean {
        if (!isProvisioned(ctx)) return false
        // App 冷启动时 adb server 的设备列表是空的，不 connect 直接 -s 会
        // 「device not found」，探测结果全部失真 —— 必须先确保连接
        if (!ensureConnected(ctx)) {
            android.util.Log.d("AdbBootstrap", "isFrameworkInstalled: 未连接，无法判定")
            return false
        }
        val r = run(
            ctx,
            listOf("-s", TARGET, "shell", "test -f $MAIN_SH && echo yes"),
            timeoutMs = 10_000,
        )
        // ★ 严格判定：必须「命令成功」且「输出恰好是 yes」。
        //   早期用 contains("yes") —— 在连接失败时 adb 会输出
        //   「adb: device '…' not found」，理论上不含 yes，但实测出现过
        //   误判为已部署的情况；宽松匹配是隐患，改成精确比较。
        val installed = r.ok && r.message.trim() == "yes"
        android.util.Log.d(
            "AdbBootstrap",
            "isFrameworkInstalled: ok=${r.ok} msg=[${r.message.take(200)}] -> $installed",
        )
        return installed
    }

    /**
     * 固定端口是否已写进 persist 属性。
     *
     * 判据：`getprop persist.adb.tcp.port` == "5555"。
     * 只有它跨重启保持 —— 开机后 adbd 是否自动监听 5555 全看它，
     * 所以「自启能不能成立」本质上取决于这一项，而不是当下有没有监听。
     */
    fun isPortFixed(ctx: Context): Boolean {
        if (!isProvisioned(ctx)) return false
        if (!ensureConnected(ctx)) {
            android.util.Log.d("AdbBootstrap", "isPortFixed: 未连接，无法判定")
            return false
        }
        val r = run(
            ctx,
            listOf("-s", TARGET, "shell", "getprop persist.adb.tcp.port"),
            timeoutMs = 10_000,
        )
        android.util.Log.d(
            "AdbBootstrap",
            "isPortFixed: ok=${r.ok} msg=[${r.message.take(120)}]",
        )
        return r.ok && r.message.trim() == CONNECT_PORT.toString()
    }

    /** 设备上是否已经设置过访问密钥（文件存在且非空）。 */
    fun isWebuiTokenSet(ctx: Context): Boolean {
        if (!isProvisioned(ctx)) return false
        if (!ensureConnected(ctx)) return false
        val r = run(
            ctx,
            listOf("-s", TARGET, "shell", "test -s $WEBUI_TOKEN_FILE && echo yes"),
            timeoutMs = 10_000,
        )
        return r.ok && r.message.contains("yes")
    }

    /**
     * 下发访问密钥：把 App 缓存里的密钥文件推到设备并收紧权限。
     *
     * 走 push 而不是 `adb shell echo '…' > file`：后者会把密钥写进命令行，
     * 同设备上 `ps` 就能看到。push 出来的是文件内容，不经过参数。
     */
    fun pushWebuiToken(ctx: Context, cachePath: String): Result {
        if (!isProvisioned(ctx)) {
            return Result(false, "尚未配对：请先完成设备配对")
        }
        if (!ensureConnected(ctx)) {
            return Result(false, "未连接到 127.0.0.1:$CONNECT_PORT（请在「开机自启设置」里重新配对）")
        }
        // 刚部署完时 state/ 可能还没被框架建出来，push 到不存在的目录会失败
        run(
            ctx,
            listOf("-s", TARGET, "shell", "mkdir -p ${'$'}IWPHONE_ROOT/state"),
            timeoutMs = 10_000,
        )
        val pushed = run(
            ctx,
            listOf("push", cachePath, WEBUI_TOKEN_FILE),
            timeoutMs = 30_000,
        )
        if (!pushed.ok) {
            return Result(false, "下发密钥失败：${pushed.message}")
        }
        run(
            ctx,
            listOf(
                "-s", TARGET, "shell",
                "chmod 600 $WEBUI_TOKEN_FILE && echo ok",
            ),
            timeoutMs = 15_000,
        )
        return if (isWebuiTokenSet(ctx)) {
            Result(true, "访问密钥已生效")
        } else {
            Result(false, "密钥已推送，但设备侧校验未通过")
        }
    }

    /**
     * 设置 WebUI 访问密钥（APatch 式：用户自己输入）。
     *
     * 校验 → 暂存到缓存 → push 到设备 → 收紧权限 → 复核。
     * 密钥会写进文件内容（不经过命令行参数），避免出现在 ps 里。
     */
    fun setWebuiToken(ctx: Context, token: String): Result {
        val t = token.trim()
        if (t.length < MIN_TOKEN_LEN) {
            return Result(false, "密钥太短：至少 $MIN_TOKEN_LEN 位（这是唯一挡住本机其他应用的东西）")
        }
        if (t.any { it.isWhitespace() }) {
            return Result(false, "密钥不能包含空格或换行")
        }
        val staged = File(ctx.cacheDir, "webui_token.tmp")
        try {
            staged.writeText(t)
        } catch (e: Exception) {
            return Result(false, "暂存密钥失败：${e.message}")
        }
        val r = pushWebuiToken(ctx, staged.absolutePath)
        staged.delete()
        return r
    }

    /**
     * 把 App 缓存里的模块包导入框架的 module/ 目录（供「安装」使用）。
     *
     * 这是自服务闭环的最后一块：用户在手机存储里存的 .iwp / Magisk 式模块 zip，
     * 经 SAF 选进 App 缓存后由这里推到设备 —— 全程不需要电脑。
     */
    fun importPackage(ctx: Context, cachePath: String, fileName: String): Result {
        if (!isProvisioned(ctx)) {
            return Result(false, "尚未配对：请先完成设备配对")
        }
        if (!ensureConnected(ctx)) {
            return Result(false, "未连接到 127.0.0.1:$CONNECT_PORT")
        }

        // 只留文件名并挡掉路径穿越 —— 这个名字会成为设备上的文件名
        val safe = fileName.substringAfterLast('/').substringAfterLast('\\')
            .replace("..", "").trim()
        if (safe.isEmpty() || safe.length > 128) {
            return Result(false, "文件名不合法：$fileName")
        }

        val pushed = run(
            ctx,
            listOf("push", cachePath, "$FRAME_DIR/module/$safe"),
            timeoutMs = 120_000,
        )
        if (!pushed.ok) {
            return Result(false, "推送失败：${pushed.message}")
        }

        // push 出来的文件属主是 shell，补上与既有包一致的权限
        run(
            ctx,
            listOf(
                "-s", TARGET, "shell",
                "chmod 777 '$FRAME_DIR/module/$safe' && echo ok",
            ),
            timeoutMs = 15_000,
        )
        return Result(true, "已导入：$safe（进入列表即可安装）")
    }

    /**
     * 把 APK 内置的框架包部署到设备上。
     *
     * 流程：asset → App 缓存 → `adb push` 到 /data/local/tmp → tar 解压 → 补权限 → 清理。
     *
     * 幂等且**可反复执行**：tar 解压会覆盖同名文件，所以重复调用等价于
     * 「修复 / 重置框架」—— 脚本被改坏了、被误删了，跑一遍就好。
     * 这也是「用户不碰电脑就能一直玩下去」的关键一环。
     *
     * 文件由 shell 用户解出，属主天然是 shell —— 正合框架以 shell 身份运行的要求，
     * 不需要也不能 chown root。
     */
    fun deployFramework(ctx: Context): Result {
        if (!isProvisioned(ctx)) {
            return Result(false, "尚未配对：请先完成设备配对，拿到 shell 才能部署")
        }

        // 配对 ≠ 已连接：首次部署前必须先建 transport（发现动态端口 → 固定 5555），
        // 否则 push / shell 都会报 no devices/emulators found。
        val transport = ensureTransport(ctx)
        if (!transport.ok) {
            return Result(false, "未连接到设备：${transport.message}")
        }

        // 1) asset → 缓存文件（12MB，一次性读出写盘即可）
        val staged = File(ctx.cacheDir, "framework.tar.gz")
        try {
            ctx.assets.open(FW_ASSET).use { input ->
                staged.outputStream().use { output -> input.copyTo(output) }
            }
        } catch (e: Exception) {
            return Result(false, "读取内置框架包失败：${e.message}")
        }
        if (staged.length() == 0L) {
            return Result(false, "内置框架包为空")
        }

        // 2) push 到设备（12MB 走 localhost，通常几秒）
        val pushed = run(
            ctx,
            listOf("push", staged.absolutePath, FW_TAR_ON_DEVICE),
            timeoutMs = 120_000,
        )
        if (!pushed.ok) {
            return Result(false, "推送框架包失败：${pushed.message}")
        }

        // 3) 解压 + 补执行位 + 铺 busybox applet。tar 会覆盖同名文件 → 天然幂等
        //
        // busybox applet 链接：Magisk/KernelSU/AxManager 式脚本的命令行为
        // 普遍假设 busybox 语义（如 sed -i、awk 的某些用法）。部署时在 bin/ 下
        // 为全部 358 个 applet 建符号链接，兼容入口会把 bin 放到 PATH 最前，
        // 脚本就能优先拿到 busybox 版命令 —— 等效于 Magisk 的 standalone 效果。
        // ★ 顺序很关键：必须先 chmod 再跑 busybox。
        //   框架包可能在 Windows 上打包（NTFS 没有执行位，解出来全是 644），
        //   先跑 ./busybox --list 会 Permission denied，导致 applet 链接一个都建不出来，
        //   compat 层的 BusyBox 支持就静默失效了。
        //   busybox 段用 `;` 收尾而非 `&&` —— 它只是兼容层的增强，失败不该让整个部署失败。
        val extractCmd = "mkdir -p $FW_ROOT_PARENT && " +
            "tar xzf $FW_TAR_ON_DEVICE -C $FW_ROOT_PARENT && " +
            "rm -rf $LEGACY_FRAME_PARENT; " +
            "mkdir -p $IWPHONE_ROOT/state $IWPHONE_ROOT/modsnap && " +
            "chmod -R 777 $FRAME_DIR && " +
            "if [ -x $FRAME_DIR/bin/busybox ]; then " +
            "cd $FRAME_DIR/bin && for a in \$(./busybox --list); do ln -sf busybox \"\$a\"; done; fi; " +
            "rm -f $FW_TAR_ON_DEVICE && echo deployed"
        val extract = run(
            ctx,
            listOf("-s", TARGET, "shell", extractCmd),
            timeoutMs = 180_000,
        )
        staged.delete()

        if (!extract.ok || !extract.message.contains("deployed")) {
            return Result(false, "解压框架失败：${extract.message}")
        }

        // 4) 确认入口真的就位
        return if (isFrameworkInstalled(ctx)) {
            // 记下「这次部署对应的 App 安装时间」，下次 App 升级后据此判断要不要重铺
            AutostartPrefs.setDeployStamp(ctx, installStamp(ctx))
            Result(true, "框架已部署（可重复执行以修复/重置）")
        } else {
            Result(false, "部署命令已执行，但未检测到 $MAIN_SH")
        }
    }

    // ---------------- 执行 ----------------

    /**
     * adb 操作结果。
     *
     * [skipped] 表示「什么都没做但不算失败」—— 例如框架已在运行。
     * 调用方据此决定要不要发通知：跳过不该打扰用户。
     */
    data class Result(
        val ok: Boolean,
        val message: String,
        val skipped: Boolean = false,
    )

    /**
     * 运行一次 adb 命令。
     *
     * 输出在两个线程上并行读取 —— adb 的输出可能超过管道缓冲区（64KB），
     * 若先 `waitFor` 再读会死锁。
     */
    fun run(ctx: Context, args: List<String>, timeoutMs: Long = CMD_TIMEOUT_MS): Result {
        val adb = adbFile(ctx)
        if (!adb.exists()) {
            return Result(false, "内置 adb 不存在：${adb.absolutePath}")
        }
        if (!adb.canExecute()) {
            // 少数情况下解压出来的文件丢了可执行位，补一下
            adb.setExecutable(true, false)
            if (!adb.canExecute()) {
                return Result(false, "内置 adb 无法执行：${adb.absolutePath}")
            }
        }

        val home = homeDir(ctx)
        return try {
            val pb = ProcessBuilder(listOf(adb.absolutePath) + args)
            pb.directory(home)
            pb.redirectErrorStream(true)
            pb.environment().apply {
                put("HOME", home.absolutePath)
                put("TMPDIR", ctx.cacheDir.absolutePath)
                // 交给 adb 自己找 linker/system 工具，PATH 保持最小可用集合
                put("PATH", "/system/bin:/system/xbin")
            }

            val proc = pb.start()

            val sb = StringBuilder()
            val reader = Thread {
                try {
                    proc.inputStream.bufferedReader().forEachLine { sb.appendLine(it) }
                } catch (_: Exception) {
                    // 进程被强杀时读流会抛异常，忽略即可
                }
            }
            reader.isDaemon = true
            reader.start()

            val finished = proc.waitFor(timeoutMs, TimeUnit.MILLISECONDS)
            if (!finished) {
                proc.destroyForcibly()
                reader.join(500)
                return Result(false, "adb 超时（${timeoutMs / 1000}s）：${args.joinToString(" ")}")
            }
            reader.join(1000)

            val out = sb.toString().trim()
            val ok = proc.exitValue() == 0
            Result(ok, if (out.isEmpty()) "(无输出)" else out)
        } catch (e: Exception) {
            Result(false, "adb 执行异常：${e.javaClass.simpleName}: ${e.message}")
        }
    }

    /** 重启 adb 客户端自身（清掉可能陈旧的连接状态）。 */
    private fun resetServer(ctx: Context) {
        run(ctx, listOf("kill-server"), timeoutMs = 8000)
    }

    // ---------------- 一次性配置 ----------------

    /**
     * 用无线调试的「配对码 + 配对端口」完成配对。
     *
     * 用户操作路径：设置 → 开发者选项 → 无线调试 → 使用配对码配对设备，
     * 界面上会显示一个 6 位配对码和一个端口（**不是**那个 5555 连接端口）。
     *
     * 配对成功后 adbd 会记住本 App 的公钥；由于密钥跨重启保持，此后无需再配对。
     */
    fun pair(ctx: Context, pairPort: String, code: String): Result {
        val port = pairPort.trim()
        val pin = code.trim()
        if (port.isEmpty() || pin.isEmpty()) return Result(false, "配对端口与配对码都不能为空")
        port.toIntOrNull() ?: return Result(false, "配对端口不是数字：$port")
        if (pin.length < 4) return Result(false, "配对码看起来不对：$pin")

        resetServer(ctx)
        // adb pair 会从 stdin 读配对码
        return runWithStdin(ctx, listOf("pair", "127.0.0.1:$port"), pin)
    }

    /**
     * 把 ADB TCP 端口固定为 5555。
     *
     * 这一步是整个方案的地基：`adb tcpip` 会写 `persist.adb.tcp.port=5555`，
     * 该属性跨重启保持，开机后 adbd 会自动监听 5555。
     *
     * 注意：shell 身份是**写不了**这个属性的（SELinux `adbd_config_prop`），
     * 只有 adb 协议指令或 root 能写 —— 这正是必须由 adb 下发而非 shell 直接 setprop 的原因。
     */
    fun ensureFixedPort(ctx: Context): Result {
        // 先确保有可用 transport（首次配置时 5555 还没起来，必须走动态端口）
        val t = ensureTransport(ctx)
        if (!t.ok) return Result(false, "固定端口失败：${t.message}")

        // 已连上 5555：先确认 persist 真的写入了（跨重启才有效）
        val current = run(
            ctx,
            listOf("-s", TARGET, "shell", "getprop persist.adb.tcp.port"),
            timeoutMs = 10_000,
        )
        if (current.ok && current.message.trim() == CONNECT_PORT.toString()) {
            return Result(
                true,
                "已固定 ADB 端口为 $CONNECT_PORT（persist 属性已写入，跨重启保持）",
            )
        }

        // 属性没写 → 用现有 transport 再下发一次 tcpip
        val r = run(ctx, listOf("tcpip", CONNECT_PORT.toString()), timeoutMs = 30_000)
        if (!r.ok) {
            return Result(false, "固定端口失败：${r.message}")
        }

        // ★ 必须验证属性真的写进 persist 了，不能只看上面那句
        //   "restarting in TCP mode" —— 实测当 persist.adb.tcp.port 曾被置空时，
        //   adbd 只设运行时的 service.adb.tcp.port、不写 persist，
        //   消息照样出现，结果「本次开机能用、重启就失效」。
        //
        // tcpip 会重启 adbd，连接会断开重连，所以这里带重试轮询。
        val deadline = System.currentTimeMillis() + 15_000
        var value = ""
        while (System.currentTimeMillis() < deadline) {
            Thread.sleep(1_000)
            val conn = connectAndVerify(ctx, TARGET)
            if (!conn.ok) continue
            val v = run(
                ctx,
                listOf("-s", TARGET, "shell", "getprop persist.adb.tcp.port"),
                timeoutMs = 10_000,
            )
            if (v.ok) {
                value = v.message.trim()
                if (value == CONNECT_PORT.toString()) {
                    return Result(
                        true,
                        "已固定 ADB 端口为 $CONNECT_PORT（persist 属性已写入，跨重启保持）",
                    )
                }
            }
        }
        return Result(
            false,
            "端口已切到 TCP 模式，但 persist.adb.tcp.port 未写入（当前值=[$value]）。"
                + "重启后 5555 不会自动监听，自启将无法生效。",
        )
    }

    // ---------------- 每次开机执行 ----------------

    /**
     * 本 App 的安装时间戳。每次覆盖安装都会变，用来判断「App 是不是升级过」。
     *
     * 取不到时返回 0 —— 此时【不】触发重新部署，避免因为一次读取失败
     * 就把用户设备上的框架整个覆盖一遍。
     */
    @Suppress("DEPRECATION")
    private fun installStamp(ctx: Context): Long = try {
        ctx.packageManager.getPackageInfo(ctx.packageName, 0).lastUpdateTime
    } catch (e: Exception) {
        0L
    }

    /**
     * 框架是否需要重新铺设。
     *
     * 判据是「上次部署时的 App 安装时间」和当前不一致。这样 App 一升级，
     * 内置框架包就会重新解压一遍 —— 解决历史上反复出现的
     * 「App 是新的，设备上跑的却是几个月前那套框架」。
     */
    private fun deployStampStale(ctx: Context): Boolean {
        val stamp = installStamp(ctx)
        if (stamp == 0L) return false
        return AutostartPrefs.deployStamp(ctx) != stamp
    }

    /** 框架是否已在运行（避免重复拉起）。 */
    private fun frameworkRunning(ctx: Context): Boolean {
        val r = run(
            ctx,
            listOf(
                "-s", TARGET, "shell",
                "ps -A -o ARGS | grep -c '[M]ain.sh'",
            ),
        )
        val n = r.message.trim().toIntOrNull() ?: 0
        return n > 0
    }

    /**
     * 拉起 WebUI 服务（幂等）。
     *
     * `webui_start.sh` 自带「已在运行」判断：webui.pid 活着就直接退出，
     * 不会起第二个实例。因此可以在启动流程里无条件调用。
     *
     * ★ `setsid -d` 不能省：这个命令是 App 通过 adb 下发的，adb 会话一结束
     *   就会给子进程发 SIGHUP。不脱离会话的话，WebUI 会在启动几秒后被悄悄
     *   杀掉 —— 表现正是「刚点完提示已运行，回头就 WebUI 不可达」。
     *   Main.sh 的启动命令同样用了 setsid，两者必须一致。
     */
    private fun ensureWebui(ctx: Context) {
        run(
            ctx,
            listOf(
                "-s", TARGET, "shell",
                "nohup setsid -d sh $WEBUI_START >/dev/null 2>&1 </dev/null &",
            ),
        )
    }

    /**
     * 重认证并拉起框架。开机自启的核心流程。
     *
     * 幂等：若框架已在运行则直接返回成功，不会产生重复实例
     * （Main.sh 自身也有 PID 文件互斥，这里的检查只是让结果更准确）。
     */
    fun startFramework(ctx: Context): Result {
        if (!isProvisioned(ctx)) {
            return Result(false, "尚未完成配置（缺少 adb 或密钥）")
        }

        // 框架不在（首次使用 / 被删 / 被改坏）→ 自动部署一次再启动。
        // 有了内置框架包，这条链路就完全不需要电脑介入了。
        //
        // 另外：App 每次升级也会重铺一次。内置框架跟 App 一起走，不重铺就会
        // 残留旧脚本（踩过：App 装的是新包，设备上跑的还是几个月前的框架）。
        if (!isFrameworkInstalled(ctx) || deployStampStale(ctx)) {
            val dep = deployFramework(ctx)
            if (!dep.ok) return Result(false, "框架未部署，且自动部署失败：${dep.message}")
        }

        // 首次使用 / 5555 尚未监听时，这里会先连无线调试动态端口再固定 5555
        val c = ensureTransport(ctx)
        if (!c.ok) return c

        if (frameworkRunning(ctx)) {
            // ★ 守护进程活着 ≠ WebUI 活着。WebUI 是 App 读取一切状态的唯一通道
            //   （只有模块列表和日志有 /sdcard 兜底），它崩掉时守护进程毫无感知。
            //   早期版本在这里直接 return，于是出现「点立即执行 → 提示已运行 →
            //   首页全空、按钮报 WebUI 不可达」。这里补一次幂等启动即可自愈。
            ensureWebui(ctx)
            return Result(true, "框架已在运行，跳过启动", skipped = true)
        }

        // ★ 结尾的 & 不能省：少了它，adb 会话一结束框架就被连带杀掉
        val startMain = run(
            ctx,
            listOf(
                "-s", TARGET, "shell",
                "nohup setsid -d sh $MAIN_SH >/dev/null 2>&1 </dev/null &",
            ),
        )
        if (!startMain.ok) {
            return Result(false, "启动框架失败：${startMain.message}")
        }

        // WebUI 供 App 读取状态用；它自身有「已在运行」判断，重复调用无副作用
        ensureWebui(ctx)

        // 给守护进程一点时间写 PID 文件，然后确认它真的活着
        Thread.sleep(2500)
        return if (frameworkRunning(ctx)) {
            Result(true, "框架已启动")
        } else {
            Result(false, "已下发启动指令，但未检测到框架进程")
        }
    }

    // ---------------- 内部工具 ----------------

    /** 需要把内容写进 adb 的 stdin（目前只有 `pair` 用）。 */
    private fun runWithStdin(
        ctx: Context,
        args: List<String>,
        stdin: String,
        timeoutMs: Long = CMD_TIMEOUT_MS,
    ): Result {
        val adb = adbFile(ctx)
        if (!adb.exists()) return Result(false, "内置 adb 不存在：${adb.absolutePath}")
        val home = homeDir(ctx)
        return try {
            val pb = ProcessBuilder(listOf(adb.absolutePath) + args)
            pb.directory(home)
            pb.redirectErrorStream(true)
            pb.environment().apply {
                put("HOME", home.absolutePath)
                put("TMPDIR", ctx.cacheDir.absolutePath)
                put("PATH", "/system/bin:/system/xbin")
            }
            val proc = pb.start()
            proc.outputStream.use { it.write((stdin + "\n").toByteArray()) }

            val sb = StringBuilder()
            val reader = Thread {
                try {
                    proc.inputStream.bufferedReader().forEachLine { sb.appendLine(it) }
                } catch (_: Exception) {
                }
            }
            reader.isDaemon = true
            reader.start()

            if (!proc.waitFor(timeoutMs, TimeUnit.MILLISECONDS)) {
                proc.destroyForcibly()
                reader.join(500)
                return Result(false, "adb 超时（${timeoutMs / 1000}s）：${args.joinToString(" ")}")
            }
            reader.join(1000)

            val out = sb.toString().trim()
            if (out.contains("Successfully paired", ignoreCase = true)) {
                Result(true, "配对成功")
            } else {
                Result(false, "配对失败：${if (out.isEmpty()) "(无输出)" else out}")
            }
        } catch (e: Exception) {
            Result(false, "adb 执行异常：${e.javaClass.simpleName}: ${e.message}")
        }
    }
}

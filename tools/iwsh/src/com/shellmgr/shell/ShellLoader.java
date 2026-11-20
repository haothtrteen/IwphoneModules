package com.shellmgr.shell;

import java.io.BufferedReader;
import java.io.File;
import java.io.FileInputStream;
import java.io.FileOutputStream;
import java.io.InputStream;
import java.io.InputStreamReader;
import java.net.HttpURLConnection;
import java.net.URL;
import java.net.URLEncoder;
import java.util.concurrent.TimeUnit;

/**
 * iwsh 客户端：由 /system/bin/app_process 从第三方 app 的终端启动。
 * 全程只用 Java 标准库，不依赖 Android Context / hidden API。
 *
 * 两种形态（与 rish 一致）：
 *   - 无参数：交互式 REPL，连续读 stdin 执行，exit / Ctrl-D 退出；
 *   - 带参数：执行一条命令后退出（保持旧调用方式兼容）。
 *
 * ★ 交互式 REPL 走**流式**通道（/exec/stream）：命令边跑边出结果，
 *   `getevent -lt`、`logcat`、`tail -f` 这类不自己结束的命令也能用。
 *   一次性调用仍走 /exec（结果一次给全，省一次连接）；
 *   想在一次性调用里也用流式，加 `-s`：`iwsh -s getevent -lt`。
 *
 * 授权按「整个应用」：包名由 iwsh.sh 通过 IWPHONE_APPLICATION_ID 传入，
 * 首次确认后 token 缓存到工具包目录，后续调用与 REPL 内每条命令复用，
 * 不再弹窗。
 *
 * ★ 所有输出统一写 System.err：联发科 ROM / 部分终端 App 会在每次 HTTP
 *   请求时往 stdout 注入 CTA/OkHttp 日志，iwsh.sh 默认丢弃 stdout，
 *   再把 stderr 送回终端，从而只留下命令结果。
 */
public final class ShellLoader {

    private static final String ACTION = "com.shellmgr.action.REQUEST_SHELL";
    private static final String RECEIVER =
            "com.shellmgr.shell_manager/.BrokerShellReceiver";

    /** 流式通道的空闲超时（秒）。0 = 不限。可用 IWPHONE_STREAM_IDLE 覆盖。 */
    private static int idleSeconds() {
        String v = System.getenv("IWPHONE_STREAM_IDLE");
        if (v != null && v.length() > 0) {
            try {
                int n = Integer.parseInt(v.trim());
                if (n >= 0) return n;
            } catch (Exception ignored) {
            }
        }
        return 300;
    }

    /** runStream 里发现 token 失效时置位，交给调用方重新授权。 */
    private static boolean lastInvalidToken = false;

    public static void main(String[] args) {
        // -s / --stream：一次性调用也走流式
        boolean forceStream = false;
        int from = 0;
        while (from < args.length
                && (args[from].equals("-s") || args[from].equals("--stream"))) {
            forceStream = true;
            from++;
        }
        String[] rest = new String[args.length - from];
        System.arraycopy(args, from, rest, 0, rest.length);

        final boolean repl = (rest.length == 0);
        final String oneShot = join(rest);
        String pkg = System.getenv("IWPHONE_APPLICATION_ID");
        if (pkg == null || pkg.length() == 0) pkg = "com.termux";
        String dir = System.getenv("IWPHONE_DIR");
        if (dir == null || dir.length() == 0) dir = ".";
        File cache = new File(dir, ".iwsh_token");

        try {
            String token = obtainToken(cache, pkg);
            if (token == null) System.exit(2);
            if (repl) {
                runRepl(cache, pkg, token);
            } else if (forceStream) {
                runStream(token, oneShot, "", idleSeconds());
                if (lastInvalidToken) {
                    try { cache.delete(); } catch (Exception ignored) {}
                    token = obtainToken(cache, pkg);
                    if (token == null) System.exit(2);
                    runStream(token, oneShot, "", idleSeconds());
                }
            } else {
                String body = execute(token, oneShot, "");
                if (isInvalidToken(body)) {
                    // ★ 授权被撤销后，缓存的旧 token 必须立刻作废并重新走授权，
                    //   否则用户会以为「撤销没生效、还能继续执行」。
                    try { cache.delete(); } catch (Exception ignored) {}
                    token = obtainToken(cache, pkg);
                    if (token == null) System.exit(2);
                    body = execute(token, oneShot, "");
                }
                print(body);
            }
        } catch (Exception e) {
            System.err.println("[iwsh] " + e);
            System.exit(1);
        }
    }

    /** 取 token：优先读缓存，失效则重新走授权并刷新缓存。 */
    private static String obtainToken(File cache, String pkg) throws Exception {
        String token = cached(cache);
        if (token != null && token.length() > 0) return token;

        // 256 位随机 nonce：广播与 /token 端点之间的一次性关联键。
        // 旧版本靠 /sdcard 上的明文 .token 文件传递，会被其它应用扫走；
        // 现在 token 只在服务端内存里挂 60 秒、领一次即删。
        byte[] rnd = new byte[32];
        new java.security.SecureRandom().nextBytes(rnd);
        StringBuilder nb = new StringBuilder();
        for (byte b : rnd) nb.append(String.format("%02x", b));
        String nonce = nb.toString();

        // 必须显式指定组件：部分 ROM 会拦截隐式自定义广播。
        // am broadcast 会等接收器 goAsync 结束（最长 45s），只短等一瞬。
        Process p = Runtime.getRuntime().exec(new String[]{
            "/system/bin/am", "broadcast", "--user", "0",
            "-n", RECEIVER, "-a", ACTION,
            "--es", "nonce", nonce, "--es", "pkg", pkg});
        try {
            p.waitFor(2, TimeUnit.SECONDS);
        } catch (InterruptedException ie) {
            Thread.currentThread().interrupt();
        }
        System.err.println("[iwsh] 已请求授权（" + pkg + "），请在弹窗中允许…");

        long deadline = System.currentTimeMillis() + 45000;
        while (System.currentTimeMillis() < deadline
                && (token == null || token.length() == 0)) {
            try {
                String body = httpGet("http://127.0.0.1:8539/token?nonce=" +
                        URLEncoder.encode(nonce, "UTF-8"));
                token = jsonField(body, "token");
            } catch (Exception ignored) {
            }
            if (token == null || token.length() == 0) Thread.sleep(500);
        }
        if (token == null || token.length() == 0) {
            System.err.println("[iwsh] 授权未完成：超时 / 被拒绝 / 未开启悬浮窗权限");
            return null;
        }
        try {
            FileOutputStream fo = new FileOutputStream(cache);
            fo.write(token.getBytes("UTF-8"));
            fo.close();
            tighten(cache);
        } catch (Exception ignored) {}
        return token;
    }

    private static String httpGet(String url) throws Exception {
        HttpURLConnection c = (HttpURLConnection) new URL(url).openConnection();
        c.setConnectTimeout(3000);
        c.setReadTimeout(8000);
        InputStream in = c.getResponseCode() == 200
                ? c.getInputStream() : c.getErrorStream();
        return in == null ? "" : readAll(in);
    }

    /** 交互式 shell：连续读行执行，cd 由客户端维护 cwd 并回读真实路径。 */
    private static void runRepl(File cache, String pkg, String token) throws Exception {
        BufferedReader in = new BufferedReader(new InputStreamReader(System.in, "UTF-8"));
        String cwd = "";
        System.err.println("iwsh · 交互模式   exit / Ctrl-D 退出   cd 可保持工作目录");
        System.err.flush();
        while (true) {
            System.err.print("iwsh> ");
            System.err.flush();
            String line = in.readLine();
            if (line == null) break;                    // Ctrl-D
            line = line.trim();
            if (line.length() == 0) continue;
            if (line.equals("exit") || line.equals("quit")) break;

            if (line.equals("cd")) {
                cwd = "";
                continue;
            }
            if (line.startsWith("cd ")) {
                // 让框架在指定 cwd 下解析 cd 并回显真实路径，处理 .. 与软链接
                String body = execute(token,
                        "cd " + line.substring(3) + " && pwd", cwd);
                String out = jsonField(body, "stdout");
                if (out != null) {
                    String p = unescape(out).trim();
                    if (p.length() > 0) cwd = p;
                } else {
                    print(body);
                }
                continue;
            }

            // ★ 走流式通道：命令边跑边出结果。
            //   以前这里用一次性 /exec，`getevent -lt` / `logcat` 这类命令
            //   要等进程退出才有输出，实际上等于不可用（还会撞 60s 总超时）。
            int idle = idleSeconds();
            runStream(token, line, cwd, idle);
            if (lastInvalidToken) {
                System.err.println("[iwsh] 授权已失效，正在重新请求授权…");
                try { cache.delete(); } catch (Exception ignored) {}
                String fresh = obtainToken(cache, pkg);
                if (fresh == null) {
                    System.err.println("[iwsh] 重新授权失败");
                    break;
                }
                token = fresh;
                runStream(token, line, cwd, idle);
            }
        }
        System.err.println("bye");
        System.err.flush();
    }

    /** App 内部持有 WebUI 密钥，终端永远拿不到。 */
    private static String execute(String token, String cmd, String cwd) throws Exception {
        StringBuilder url = new StringBuilder("http://127.0.0.1:8539/exec?token=")
                .append(URLEncoder.encode(token, "UTF-8"))
                .append("&cmd=").append(URLEncoder.encode(cmd, "UTF-8"));
        if (cwd != null && cwd.length() > 0) {
            url.append("&cwd=").append(URLEncoder.encode(cwd, "UTF-8"));
        }
        HttpURLConnection c = (HttpURLConnection) new URL(url.toString()).openConnection();
        c.setConnectTimeout(5000);
        c.setReadTimeout(70000);
        int rc = c.getResponseCode();
        InputStream in = rc == 200 ? c.getInputStream() : c.getErrorStream();
        return in == null ? "" : readAll(in);
    }

    private static boolean isInvalidToken(String body) {
        return body.contains("INVALID_TOKEN") || body.contains("GRANT_REVOKED")
                || body.contains("NO_CONTEXT") || body.contains("NO_TOKEN");
    }

    /**
     * 流式执行：`/exec/stream`。命令不退出也能边跑边显示。
     *
     * 框架回的是 NDJSON（每行一个 JSON 对象）：
     *   {"type":"start",...} / {"type":"out","data":"..."} / {"type":"exit","code":0,...}
     *
     * ★ 读超时设为 0（不限）：空闲多久算结束由框架的 idle 参数判断。
     *   客户端再压一个总超时，只会把 `logcat` 这种长跑命令提前掐断 ——
     *   之前一次性通道的 60s 上限就是这个毛病。
     *
     * @return 退出码；-1 表示未知或没跑起来
     */
    private static int runStream(String token, String cmd, String cwd, int idleSec)
            throws Exception {
        lastInvalidToken = false;
        StringBuilder url = new StringBuilder("http://127.0.0.1:8539/exec/stream?token=")
                .append(URLEncoder.encode(token, "UTF-8"))
                .append("&cmd=").append(URLEncoder.encode(cmd, "UTF-8"))
                .append("&idle=").append(idleSec);
        if (cwd != null && cwd.length() > 0) {
            url.append("&cwd=").append(URLEncoder.encode(cwd, "UTF-8"));
        }
        HttpURLConnection c = (HttpURLConnection) new URL(url.toString()).openConnection();
        c.setConnectTimeout(5000);
        c.setReadTimeout(0);
        int rc = c.getResponseCode();
        InputStream in = rc == 200 ? c.getInputStream() : c.getErrorStream();
        if (in == null) {
            System.err.println("[iwsh] 无响应（HTTP " + rc + "）");
            System.err.flush();
            return -1;
        }
        if (rc != 200) {
            String body = readAll(in);
            if (isInvalidToken(body)) {
                lastInvalidToken = true;
                return -1;
            }
            String msg = jsonField(body, "msg");
            String code = jsonField(body, "code");
            String shown = msg != null ? unescape(msg)
                    : code != null ? ("code=" + unescape(code))
                    : ("HTTP " + rc + "：" + body.trim());
            System.err.println("[iwsh] " + shown);
            System.err.flush();
            return -1;
        }

        BufferedReader r = new BufferedReader(new InputStreamReader(in, "UTF-8"));
        String line;
        int exit = -1;
        String reason = "";
        boolean anyOutput = false;
        while ((line = r.readLine()) != null) {
            if (line.length() == 0) continue;
            String type = jsonField(line, "type");
            if (type == null) {
                // 不是流事件 → 通道/框架提前拒绝时的普通 JSON（例如
                // {"ok":false,"code":"TOO_MANY_STREAMS","msg":"…"}）。
                // 不处理的话用户只会看到"执行完什么都没有"。
                String msg = jsonField(line, "msg");
                String code = jsonField(line, "code");
                if (msg != null) {
                    System.err.println("[iwsh] " + unescape(msg));
                } else if (code != null) {
                    System.err.println("[iwsh] code=" + unescape(code));
                } else {
                    System.err.println("[iwsh] " + line.trim());
                }
                System.err.flush();
                continue;
            }
            if ("out".equals(type)) {
                String data = jsonField(line, "data");
                if (data != null && data.length() > 0) {
                    String s = unescape(data);
                    System.err.print(s);
                    System.err.flush();
                    anyOutput = true;
                }
            } else if ("exit".equals(type)) {
                exit = jsonInt(line, "code", -1);
                String rs = jsonField(line, "reason");
                reason = rs == null ? "" : unescape(rs);
            }
        }
        // 「不是命令自己退出」的结束原因必须说清楚，否则用户会以为命令跑完了
        if ("idle".equals(reason)) {
            System.err.println("[iwsh] 空闲超时，命令已停止"
                    + "（IWPHONE_STREAM_IDLE 可调，0 为不限）");
        } else if ("max".equals(reason)) {
            System.err.println("[iwsh] 达到最长运行时间，命令已停止");
        } else if (!anyOutput) {
            if (exit > 0) {
                System.err.println("[iwsh] exit " + exit);
            } else if (exit == 0) {
                System.err.println("[iwsh] 无输出");
            }
        }
        System.err.flush();
        return exit;
    }

    /** 数字字段（jsonField 只取字符串，退出码是裸数字）。 */
    private static int jsonInt(String s, String key, int def) {
        int i = s.indexOf("\"" + key + "\"");
        if (i < 0) return def;
        i += key.length() + 2;
        while (i < s.length() && Character.isWhitespace(s.charAt(i))) i++;
        if (i >= s.length() || s.charAt(i) != ':') return def;
        i++;
        while (i < s.length() && Character.isWhitespace(s.charAt(i))) i++;
        int j = i;
        if (j < s.length() && s.charAt(j) == '-') j++;
        while (j < s.length() && Character.isDigit(s.charAt(j))) j++;
        if (j == i || (j == i + 1 && s.charAt(i) == '-')) return def;
        try {
            return Integer.parseInt(s.substring(i, j));
        } catch (Exception e) {
            return def;
        }
    }

    /** 没有 stdout/stderr 时也要把 code/msg 打出来，避免「执行完什么都没有」。 */
    private static void print(String body) {
        String out = jsonField(body, "stdout");
        String err = jsonField(body, "stderr");
        String msg = jsonField(body, "msg");
        String code = jsonField(body, "code");
        boolean printed = false;
        if (out != null && out.length() > 0) { System.err.print(unescape(out)); printed = true; }
        if (err != null && err.length() > 0) { System.err.print(unescape(err)); printed = true; }
        if (!printed) {
            if (msg != null && msg.length() > 0) {
                System.err.println("[iwsh] " + unescape(msg));
            } else if (code != null && code.length() > 0) {
                System.err.println("[iwsh] code=" + unescape(code));
            } else {
                System.err.println("[iwsh] 无输出：" + body.trim());
            }
        }
        System.err.flush();
        System.err.flush();
    }

    /** 只留属主读写；FUSE(/sdcard) 上可能不生效，故工具包仍建议放终端 App 私有目录。 */
    private static void tighten(File f) {
        try {
            f.setReadable(false, false);
            f.setWritable(false, false);
            f.setReadable(true, true);
            f.setWritable(true, true);
        } catch (Exception ignored) {}
    }

    private static String cached(File f) {
        try {
            if (!f.isFile()) return null;
            // 先读再收紧：旧版本留下的 660 缓存也会在执行一次后变成 600
            String v = readAll(new FileInputStream(f)).trim();
            tighten(f);
            return v;
        } catch (Exception e) {
            return null;
        }
    }

    private static String join(String[] a) {
        StringBuilder b = new StringBuilder();
        for (int i = 0; i < a.length; i++) {
            if (i > 0) b.append(' ');
            b.append(a[i]);
        }
        return b.toString();
    }

    private static String readAll(InputStream in) throws Exception {
        BufferedReader r = new BufferedReader(new InputStreamReader(in, "UTF-8"));
        StringBuilder b = new StringBuilder();
        String line;
        while ((line = r.readLine()) != null) b.append(line).append('\n');
        return b.toString();
    }

    /**
     * 极简 JSON 字符串字段提取，避免引入任何第三方库。
     * ★ 必须容忍冒号后的空格：框架返回的是 {"stdout": "..."}（带空格），
     *   早期只匹配 "stdout":"..." 会解析失败，导致「执行完什么都没输出」。
     */
    private static String jsonField(String s, String key) {
        int i = s.indexOf("\"" + key + "\"");
        if (i < 0) return null;
        i += key.length() + 2;
        while (i < s.length() && Character.isWhitespace(s.charAt(i))) i++;
        if (i >= s.length() || s.charAt(i) != ':') return null;
        i++;
        while (i < s.length() && Character.isWhitespace(s.charAt(i))) i++;
        if (i >= s.length() || s.charAt(i) != '"') return null;
        i++;
        StringBuilder b = new StringBuilder();
        boolean esc = false;
        for (; i < s.length(); i++) {
            char ch = s.charAt(i);
            if (esc) { b.append('\\').append(ch); esc = false; continue; }
            if (ch == '\\') { esc = true; continue; }
            if (ch == '"') break;
            b.append(ch);
        }
        return b.toString();
    }

    private static String unescape(String s) {
        return s.replace("\\n", "\n").replace("\\r", "\r")
                .replace("\\t", "\t").replace("\\\"", "\"")
                .replace("\\\\", "\\");
    }
}

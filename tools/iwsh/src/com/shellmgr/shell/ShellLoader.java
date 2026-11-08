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

    public static void main(String[] args) {
        final boolean repl = (args.length == 0);
        final String oneShot = join(args);
        String pkg = System.getenv("IWPHONE_APPLICATION_ID");
        if (pkg == null || pkg.length() == 0) pkg = "com.termux";
        String dir = System.getenv("IWPHONE_DIR");
        if (dir == null || dir.length() == 0) dir = ".";
        File cache = new File(dir, ".iwsh_token");

        try {
            String token = obtainToken(cache, pkg);
            if (token == null) System.exit(2);
            if (repl) {
                runRepl(token);
            } else {
                print(execute(token, oneShot, ""));
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

        String nonce = "iw" + Long.toString(System.currentTimeMillis(), 36)
                + Integer.toString(new java.security.SecureRandom().nextInt(9000) + 1000);
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

        String[] dirs = {
            "/sdcard/iwphone/broker",
            "/sdcard/Android/data/com.shellmgr.shell_manager/files/broker",
        };
        for (int i = 0; i < 90 && token == null; i++) {
            for (String d : dirs) {
                File f = new File(d, nonce + ".token");
                if (f.isFile()) {
                    token = readAll(new FileInputStream(f)).trim();
                    try { f.delete(); } catch (Exception ignored) {}
                    break;
                }
            }
            if (token == null) Thread.sleep(500);
        }
        if (token == null || token.length() == 0) {
            System.err.println("[iwsh] 授权未完成：超时 / 被拒绝 / 未开启悬浮窗权限");
            return null;
        }
        try {
            FileOutputStream fo = new FileOutputStream(cache);
            fo.write(token.getBytes("UTF-8"));
            fo.close();
        } catch (Exception ignored) {}
        return token;
    }

    /** 交互式 shell：连续读行执行，cd 由客户端维护 cwd 并回读真实路径。 */
    private static void runRepl(String token) throws Exception {
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

            String body = execute(token, line, cwd);
            if (isInvalidToken(body)) {
                print(body);
                System.err.println("[iwsh] 授权已失效，请撤销后重新发起授权");
                break;
            }
            print(body);
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

    private static String cached(File f) {
        try {
            if (!f.isFile()) return null;
            return readAll(new FileInputStream(f)).trim();
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

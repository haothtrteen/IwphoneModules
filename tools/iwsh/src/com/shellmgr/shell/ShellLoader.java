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

/**
 * iwsh 客户端：由 /system/bin/app_process 从第三方 app 的终端启动。
 * 全程只用 Java 标准库，不依赖 Android Context / hidden API。
 *
 * 授权模型（对齐 Shizuku）：把终端应用的包名随请求传给 Shell Manager，
 * 由 App 侧查 PackageManager 得到 uid + 签名，写入「整个应用」的授权记录。
 * 授权一次后 token 缓存到工具包目录，后续调用不再弹窗。
 */
public final class ShellLoader {

    private static final String ACTION = "com.shellmgr.action.REQUEST_SHELL";

    public static void main(String[] args) {
        String cmd = join(args);
        if (cmd.length() == 0) cmd = "id";
        String pkg = System.getenv("IWPHONE_APPLICATION_ID");
        if (pkg == null || pkg.length() == 0) pkg = "com.termux";
        String dir = System.getenv("IWPHONE_DIR");
        if (dir == null || dir.length() == 0) dir = ".";
        File cache = new File(dir, ".iwsh_token");
        try {
            String token = cached(cache);

            // 1) 已有授权 token：直接尝试执行；失效则清缓存重新走授权
            if (token != null && token.length() > 0) {
                String body = execute(token, cmd);
                if (!isInvalidToken(body)) {
                    print(body);
                    return;
                }
                try { cache.delete(); } catch (Exception ignored) {}
                token = null;
            }

            // 2) 请求授权：广播里带终端应用包名
            String nonce = "iw" + Long.toString(System.currentTimeMillis(), 36)
                    + Integer.toString(new java.security.SecureRandom().nextInt(9000) + 1000);
            Process p = Runtime.getRuntime().exec(new String[]{
                "/system/bin/am", "broadcast", "--user", "0",
                "-a", ACTION, "--es", "nonce", nonce,
                "--es", "pkg", pkg});
            p.waitFor();
            System.err.println("[iwsh] 已请求授权（" + pkg + "），请在弹窗中允许…");

            // 3) 轮询一次性下发的 token 文件
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
                System.exit(2);
            }

            // 4) 缓存 token（整个应用长期有效，直到在 App 里撤销）
            try {
                FileOutputStream fo = new FileOutputStream(cache);
                fo.write(token.getBytes("UTF-8"));
                fo.close();
            } catch (Exception ignored) {}

            print(execute(token, cmd));
        } catch (Exception e) {
            System.err.println("[iwsh] " + e);
            System.exit(1);
        }
    }

    private static String cached(File f) {
        try {
            if (!f.isFile()) return null;
            return readAll(new FileInputStream(f)).trim();
        } catch (Exception e) {
            return null;
        }
    }

    /** App 内部持有 WebUI 密钥，终端永远拿不到。 */
    private static String execute(String token, String cmd) throws Exception {
        String url = "http://127.0.0.1:8539/exec?token="
                + URLEncoder.encode(token, "UTF-8")
                + "&cmd=" + URLEncoder.encode(cmd, "UTF-8");
        HttpURLConnection c = (HttpURLConnection) new URL(url).openConnection();
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

    private static void print(String body) {
        String out = jsonField(body, "stdout");
        String err = jsonField(body, "stderr");
        String msg = jsonField(body, "msg");
        if (out != null && out.length() > 0) System.out.print(unescape(out));
        if (err != null && err.length() > 0) System.err.print(unescape(err));
        if ((out == null || out.length() == 0) && msg != null) {
            System.err.println("[iwsh] " + unescape(msg));
        }
        System.out.flush();
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

    /** 极简 JSON 字符串字段提取，避免引入任何第三方库。 */
    private static String jsonField(String s, String key) {
        String k = "\"" + key + "\":\"";
        int i = s.indexOf(k);
        if (i < 0) return null;
        i += k.length();
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

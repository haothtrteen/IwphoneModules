package com.shellmgr.shell;

import java.io.BufferedReader;
import java.io.File;
import java.io.FileInputStream;
import java.io.InputStream;
import java.io.InputStreamReader;
import java.net.HttpURLConnection;
import java.net.URL;
import java.net.URLEncoder;

/**
 * iwsh 客户端：由 /system/bin/app_process 从第三方 app 的终端启动。
 * 全程只用 Java 标准库，不依赖 Android Context / hidden API。
 */
public final class ShellLoader {

    private static final String ACTION = "com.shellmgr.action.REQUEST_SHELL";

    public static void main(String[] args) {
        String cmd = join(args);
        if (cmd.length() == 0) cmd = "id";
        try {
            String nonce = "iw" + Long.toString(System.currentTimeMillis(), 36)
                    + Integer.toString(new java.security.SecureRandom().nextInt(9000) + 1000);

            // 1) 请求 Shell Manager 弹出授权确认
            Process p = Runtime.getRuntime().exec(new String[]{
                "/system/bin/am", "broadcast", "--user", "0",
                "-a", ACTION, "--es", "nonce", nonce});
            p.waitFor();
            System.err.println("[iwsh] 已请求授权，请在弹窗中允许…");

            // 2) 轮询一次性 token（用户确认后由 App 写入公共目录）
            String[] dirs = {
                "/sdcard/iwphone/broker",
                "/sdcard/Android/data/com.shellmgr.shell_manager/files/broker",
            };
            String token = null;
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

            // 3) 回环 HTTP 执行（App 内部持有 WebUI 密钥，终端不接触）
            String url = "http://127.0.0.1:8539/exec?token="
                    + URLEncoder.encode(token, "UTF-8")
                    + "&cmd=" + URLEncoder.encode(cmd, "UTF-8");
            HttpURLConnection c = (HttpURLConnection) new URL(url).openConnection();
            c.setConnectTimeout(5000);
            c.setReadTimeout(70000);
            int rc = c.getResponseCode();
            InputStream in = rc == 200 ? c.getInputStream() : c.getErrorStream();
            String body = in == null ? "" : readAll(in);
            String out = jsonField(body, "stdout");
            String err = jsonField(body, "stderr");
            String msg = jsonField(body, "msg");
            if (out != null && out.length() > 0) System.out.print(unescape(out));
            if (err != null && err.length() > 0) System.err.print(unescape(err));
            if ((out == null || out.length() == 0) && msg != null) {
                System.err.println("[iwsh] " + unescape(msg));
            }
            System.out.flush();
        } catch (Exception e) {
            System.err.println("[iwsh] " + e);
            System.exit(1);
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

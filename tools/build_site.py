#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""组装模块库静态站，供本地预览或 GitHub Pages 部署。

用法：
    python tools/build_site.py                 # 组装到 build/site
    python tools/build_site.py --serve         # 组装后起本地服务（默认 8080）
    python tools/build_site.py --out _site     # CI 用：输出到指定目录

为什么要单独组装，而不是直接把 site/ 当站点根：
    网页要 fetch `modules.catalog.json`，下载链接是 `modules/<id>/<id>.iwp`。
    这两个都在仓库根（或 modules/ 下），不在 site/ 里。Pages 的站点根必须
    同时包含「网页 + 清单 + 包」，否则同域下载会 404。

站点根结构（组装后）：
    index.html
    assets/style.css, assets/app.js
    modules.catalog.json
    modules/<id>/<id>.iwp
"""

import argparse
import os
import shutil
import sys
import http.server
import socketserver
import threading
import webbrowser

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SITE = os.path.join(ROOT, "site")
MODULES = os.path.join(ROOT, "modules")
CATALOG = os.path.join(ROOT, "modules.catalog.json")


def copy_tree(src, dst):
    for base, dirs, files in os.walk(src):
        dirs[:] = [d for d in dirs if d not in (".git", "__pycache__")]
        rel = os.path.relpath(base, src)
        target = dst if rel == "." else os.path.join(dst, rel)
        os.makedirs(target, exist_ok=True)
        for fn in files:
            shutil.copy2(os.path.join(base, fn), os.path.join(target, fn))


def build(out_dir):
    if not os.path.isfile(CATALOG):
        print("❌ 找不到 modules.catalog.json，先运行 python tools/build_modules.py")
        return False

    if os.path.isdir(out_dir):
        shutil.rmtree(out_dir)
    os.makedirs(out_dir, exist_ok=True)

    # 1) 网页
    copy_tree(SITE, out_dir)

    # 2) 清单（网页同域读取）
    shutil.copy2(CATALOG, os.path.join(out_dir, "modules.catalog.json"))

    # 3) 模块包（同域下载，避免 raw.githubusercontent 在部分网络下不可用）
    count = 0
    if os.path.isdir(MODULES):
        for name in sorted(os.listdir(MODULES)):
            pkg = os.path.join(MODULES, name, name + ".iwp")
            if not os.path.isfile(pkg):
                continue
            d = os.path.join(out_dir, "modules", name)
            os.makedirs(d, exist_ok=True)
            shutil.copy2(pkg, os.path.join(d, name + ".iwp"))
            count += 1

    # 4) 关掉 Jekyll：文件名里有中文和下划线，交给静态托管更省事
    with open(os.path.join(out_dir, ".nojekyll"), "w") as f:
        f.write("")

    print("✅ 站点已组装：%s" % out_dir)
    print("   模块包 %d 个" % count)
    return True


class _Handler(http.server.SimpleHTTPRequestHandler):
    def log_message(self, fmt, *args):
        pass


def serve(out_dir, port):
    os.chdir(out_dir)
    handler = _Handler
    with socketserver.TCPServer(("127.0.0.1", port), handler) as httpd:
        url = "http://127.0.0.1:%d/" % port
        print("🌐 本地预览：%s  （Ctrl-C 停止）" % url)
        threading.Timer(0.6, lambda: webbrowser.open(url)).start()
        try:
            httpd.serve_forever()
        except KeyboardInterrupt:
            print("\n已停止")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", default=os.path.join(ROOT, "build", "site"))
    ap.add_argument("--serve", action="store_true")
    ap.add_argument("--port", type=int, default=8080)
    args = ap.parse_args()

    out = args.out if os.path.isabs(args.out) else os.path.join(ROOT, args.out)
    if not build(out):
        return 1
    if args.serve:
        serve(out, args.port)
    return 0


if __name__ == "__main__":
    sys.exit(main())

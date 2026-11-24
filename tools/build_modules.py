#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""模块仓库构建脚本：打包 .iwp + 生成 modules.catalog.json。

用法：
    python tools/build_modules.py            # 打包并重建清单
    python tools/build_modules.py --check    # 只校验，清单不是最新就返回 1（CI 用）

设计要点
--------
1. **可复现构建**：zip 内时间戳固定为 2020-01-01，条目按名字排序。
   否则每次 CI 构建的 sha256 都不一样，catalog 会天天变，diff 全是噪音。
2. **清单是产物，不是手写文件**：模块元数据只认 modules/<id>/module.json，
   catalog 每次从它重新生成，杜绝"改了版本忘了改清单"。
3. **包内只放运行时文件**：module.json / README.md / *.iwp 不进包，
   否则框架会把这些当模块文件铺到工作目录。
"""

import argparse
import datetime
import hashlib
import io
import json
import os
import sys
import zipfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
MODULES_DIR = os.path.join(ROOT, "modules")
CATALOG = os.path.join(ROOT, "modules.catalog.json")
REPO = "haothtrteen/IwphoneModules"

# 固定时间戳：可复现构建的关键。改这个值会让所有模块 sha256 变化，
# 非必要不要动。
FIXED_DATE = (2020, 1, 1, 0, 0, 0)

# 不进包的文件
EXCLUDE_NAMES = {"module.json", "README.md", "README_EN.md"}
EXCLUDE_EXT = {".iwp", ".md"}

REQUIRED = ("id", "name", "version", "author", "description")


def log(msg):
    sys.stderr.write(msg + "\n")


def is_executable(name):
    """判断包内是否需要可执行位。

    Windows 上 os.access(X_OK) 不可靠（几乎所有文件都返回 True），
    所以按扩展名判断：.sh 和无扩展名的二进制（如 aapt）给 0755。
    """
    if name.endswith(".sh"):
        return True
    return not os.path.splitext(name)[1]


def collect_files(mod_dir):
    """收集要打包的文件，返回 [(绝对路径, 包内相对名)]。"""
    out = []
    for base, dirs, files in os.walk(mod_dir):
        dirs.sort()
        for fn in sorted(files):
            if fn in EXCLUDE_NAMES:
                continue
            if os.path.splitext(fn)[1].lower() in EXCLUDE_EXT:
                continue
            if fn.startswith("."):
                continue
            full = os.path.join(base, fn)
            rel = os.path.relpath(full, mod_dir).replace(os.sep, "/")
            out.append((full, rel))
    out.sort(key=lambda x: x[1])
    return out


def build_package(mod_dir, mid):
    """把模块目录打成 .iwp，返回 (字节, sha256)。"""
    files = collect_files(mod_dir)
    if not files:
        raise ValueError("目录里没有可打包的文件")

    buf = io.BytesIO()
    with zipfile.ZipFile(buf, "w", zipfile.ZIP_DEFLATED) as z:
        for full, rel in files:
            zi = zipfile.ZipInfo(rel, date_time=FIXED_DATE)
            zi.compress_type = zipfile.ZIP_DEFLATED
            zi.external_attr = ((0o755 if is_executable(rel) else 0o644) << 16)
            with open(full, "rb") as f:
                z.writestr(zi, f.read())
    data = buf.getvalue()
    return data, hashlib.sha256(data).hexdigest()


def load_meta(mod_dir):
    p = os.path.join(mod_dir, "module.json")
    if not os.path.isfile(p):
        return None
    with io.open(p, encoding="utf-8") as f:
        return json.load(f)


# 需要强制 LF 的文本类型。.bat 排除（cmd.exe 要 CRLF），无扩展名跳过（可能是二进制）。
TEXT_EXT = {".sh", ".prop", ".json", ".md", ".txt", ".conf", ".cfg"}


def check_eol(mod_dir):
    """检查文本文件是否夹带 CRLF。

    设备上跑的是 mksh，CRLF 会直接报 `syntax error: unexpected 'fi'`（踩过）。
    .gitattributes 对 modules/ 关闭了行尾转换，所以这里必须自己把关 ——
    否则作者在 Windows 编辑器里保存一次就带进去了。
    """
    errs = []
    for base, dirs, files in os.walk(mod_dir):
        dirs.sort()
        for fn in sorted(files):
            if fn.endswith(".iwp"):
                continue
            if os.path.splitext(fn)[1].lower() not in TEXT_EXT:
                continue
            full = os.path.join(base, fn)
            with open(full, "rb") as f:
                if b"\r\n" in f.read():
                    rel = os.path.relpath(full, mod_dir).replace(os.sep, "/")
                    errs.append("%s 含 CRLF（需要 LF，否则设备上 mksh 会报语法错误）" % rel)
    return errs


def validate(meta, dirname, mod_dir):
    """返回错误列表；空列表表示通过。"""
    errs = []
    if not isinstance(meta, dict):
        return ["module.json 不是对象"]
    for k in REQUIRED:
        if not str(meta.get(k, "")).strip():
            errs.append("缺少字段 %s" % k)
    if str(meta.get("id", "")) != dirname:
        errs.append("id(%s) 与目录名(%s) 不一致" % (meta.get("id"), dirname))
    if not os.path.isfile(os.path.join(mod_dir, "iwphone.prop")):
        errs.append("缺少 iwphone.prop")
    # 原生模块用 main.sh；Magisk 兼容模块用 service.sh / post-fs-data.sh
    entries = ("main.sh", "service.sh", "post-fs-data.sh")
    if not any(os.path.isfile(os.path.join(mod_dir, e)) for e in entries):
        errs.append("缺少入口脚本（main.sh / service.sh / post-fs-data.sh）")
    errs.extend(check_eol(mod_dir))
    return errs


def build_catalog(modules):
    """按 schemaVersion 2 组装清单。字段保持与 App 兼容，只增不改。"""
    return {
        "schemaVersion": 2,
        "repository": REPO,
        "updatedAt": modules["_updatedAt"],
        "modules": modules["list"],
    }


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--check", action="store_true",
                    help="只校验清单是否为最新，不写文件")
    args = ap.parse_args()

    if not os.path.isdir(MODULES_DIR):
        log("❌ 找不到 modules/ 目录")
        return 1

    entries = []
    errors = []

    for name in sorted(os.listdir(MODULES_DIR)):
        mod_dir = os.path.join(MODULES_DIR, name)
        if not os.path.isdir(mod_dir):
            continue
        meta = load_meta(mod_dir)
        if meta is None:
            log("⚠️  跳过 %s（没有 module.json）" % name)
            continue

        errs = validate(meta, name, mod_dir)
        if errs:
            errors.append((name, errs))
            continue

        data, sha = build_package(mod_dir, name)
        rel_path = "modules/%s/%s.iwp" % (name, name)
        out_path = os.path.join(mod_dir, name + ".iwp")

        # 只在内容真的变了时写盘，保持 mtime 稳定（CI diff 更干净）
        old = None
        if os.path.isfile(out_path):
            with open(out_path, "rb") as f:
                old = f.read()
        if old != data and not args.check:
            with open(out_path, "wb") as f:
                f.write(data)
        elif old != data and args.check:
            log("✗ %s 的 .iwp 不是最新（需要重新构建）" % name)

        entries.append({
            "id": meta["id"],
            "name": meta["name"],
            "version": meta["version"],
            "author": meta["author"],
            "description": meta["description"],
            "category": meta.get("category", "未分类"),
            "order": meta.get("order", 999),
            "icon": meta.get("icon", ""),
            "exclusive": meta.get("exclusive"),
            "runtime": str(meta.get("runtime", "0")),
            "packagePath": rel_path,
            "sizeBytes": len(data),
            "sha256": sha,
        })

    if errors:
        for name, errs in errors:
            log("❌ %s: %s" % (name, "; ".join(errs)))
        return 1

    entries.sort(key=lambda m: (m.get("order", 999), m["id"]))

    # updatedAt：清单内容没变就沿用旧日期，避免纯日期变更的噪音提交
    old_updated = ""
    if os.path.isfile(CATALOG):
        try:
            with io.open(CATALOG, encoding="utf-8-sig") as f:
                old_updated = json.load(f).get("updatedAt", "")
        except Exception:
            pass

    today = datetime.date.today().isoformat()
    old_list = []
    if os.path.isfile(CATALOG):
        try:
            with io.open(CATALOG, encoding="utf-8-sig") as f:
                old_list = json.load(f).get("modules", [])
        except Exception:
            pass
    same = old_list == entries
    catalog = build_catalog({"list": entries,
                             "_updatedAt": old_updated if same else today})

    text = json.dumps(catalog, ensure_ascii=False, indent=2) + "\n"
    old_text = ""
    if os.path.isfile(CATALOG):
        with io.open(CATALOG, encoding="utf-8") as f:
            old_text = f.read()

    changed = text != old_text
    if args.check:
        if changed:
            log("❌ modules.catalog.json 不是最新，请运行 python tools/build_modules.py")
            return 1
        log("✅ 清单已是最新（%d 个模块）" % len(entries))
        return 0

    if changed:
        with io.open(CATALOG, "w", encoding="utf-8", newline="\n") as f:
            f.write(text)
        log("✅ 已更新 modules.catalog.json（%d 个模块）" % len(entries))
    else:
        log("✅ 清单无变化（%d 个模块）" % len(entries))

    for m in entries:
        log("   %-30s v%-8s %6d B  %s" % (m["id"], m["version"],
                                          m["sizeBytes"], m["sha256"][:12]))
    return 0


if __name__ == "__main__":
    sys.exit(main())

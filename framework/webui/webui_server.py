#!/usr/bin/env python3
# -*- coding: utf-8 -*-
# =====================================================
# iwphone modrunner v3 · WebUI 后端
# Python 3 标准库零依赖（Termux 下 pkg install python 即可运行）
#
# 仅绑定 127.0.0.1。对外暴露请使用：
#   adb forward tcp:8537 tcp:8537
# 然后浏览器访问 http://127.0.0.1:8537
# =====================================================
import json
import os
import re
import shutil
import signal
import subprocess
import sys
import tempfile
import time
from http.server import ThreadingHTTPServer, BaseHTTPRequestHandler
from urllib.parse import urlparse, parse_qs, unquote

WEBUI_DIR = os.path.dirname(os.path.abspath(__file__))
FRAME_DIR = os.path.dirname(WEBUI_DIR)
STATIC_INDEX = os.path.join(WEBUI_DIR, "static", "index.html")


# ---------------- 配置加载（source env.sh 后读取环境） ----------------
def load_env():
    """读取 env.sh 里的配置值。

    ⚠️ 必须用 `set` 而不是 `env`：
    env.sh 中的赋值形如 VAR="${VAR:-默认值}"，**没有 export**，
    因此它们只是 shell 变量而非环境变量，`env` 命令根本看不到 ——
    早先这里用 `env`，导致 CFG 里所有键都取不到值（全部落到默认值），
    WEBUI_TOKEN 之类的配置会静默失效。
    `set` 会列出全部 shell 变量，但输出形如 VAR='value'，需剥掉引号。
    """
    cfg = {}
    try:
        r = subprocess.run(
            ["sh", "-c", '. "%s/env.sh" >/dev/null 2>&1; set' % FRAME_DIR],
            capture_output=True, text=True, timeout=10)
        for line in r.stdout.splitlines():
            if "=" not in line:
                continue
            k, v = line.split("=", 1)
            k = k.strip()
            if not k:
                continue
            v = v.strip()
            if len(v) >= 2 and v[0] == v[-1] and v[0] in ("'", '"'):
                v = v[1:-1]
            cfg[k] = v
    except Exception:
        pass
    return cfg


CFG = load_env()
IWPHONE_ROOT = CFG.get("IWPHONE_ROOT", "/data/local/tmp/iwphone")
WORK_DIR = CFG.get("WORK_DIR", IWPHONE_ROOT + "/work")
TMP_DIR = CFG.get("TMP_DIR", IWPHONE_ROOT + "/tmp")
LOCK_DIR = CFG.get("LOCK_DIR", IWPHONE_ROOT + "/locks")
PID_FILE = CFG.get("PID_FILE", IWPHONE_ROOT + "/modrunner.pid")
LOG_ROOT_DIR = CFG.get("LOG_ROOT_DIR", "/sdcard/iwphone/logs")
# 模块进程 stdout/stderr 的落盘目录（原生文件系统，勿改到 /sdcard）
MODIO_DIR = CFG.get("MODIO_DIR", IWPHONE_ROOT + "/modio")
SNAPSHOT_DIR = CFG.get("SNAPSHOT_DIR", IWPHONE_ROOT + "/modsnap")
SDCARD_DIR = CFG.get("SDCARD_DIR", "/sdcard/iwphone")
WEBUI_PORT = int(CFG.get("WEBUI_PORT", "8537") or "8537")
WEBUI_TOKEN = CFG.get("WEBUI_TOKEN", "")

# 访问密钥文件（APatch 式「用户自己设密钥」）：
# 密钥由 App 在主页引导用户输入，然后经 adb 推到这里（600，shell 属主）。
# 服务端按 mtime 缓存 —— 改密钥不需要重启 WebUI，下个请求就生效。
TOKEN_FILE = os.path.join(IWPHONE_ROOT, "state", "webui_token")
_token_cache = {"mtime": None, "value": ""}
_warned_no_token = set()   # 只警告一次，别把日志刷爆


def current_token():
    """当前生效的访问密钥。环境变量优先（手工调试用），否则读密钥文件。

    ★ 没有密钥就返回空串 —— 调用方必须据此**拒绝**请求，
      绝不因为"没配"就放行（那等于把 shell 权限挂在本机 127.0.0.1 上裸奔）。
    """
    if WEBUI_TOKEN:
        return WEBUI_TOKEN
    try:
        st = os.stat(TOKEN_FILE)
    except OSError:
        return ""
    if _token_cache["mtime"] != st.st_mtime:
        try:
            with open(TOKEN_FILE, encoding="utf-8", errors="replace") as f:
                _token_cache["value"] = f.read().strip()
            _token_cache["mtime"] = st.st_mtime
        except OSError:
            return ""
    return _token_cache["value"]


# ---------------- 框架状态查询 ----------------
def pid_alive(pid):
    try:
        os.kill(int(pid), 0)
        return True
    except (ValueError, OSError):
        return False


def daemon_status():
    try:
        with open(PID_FILE) as f:
            pid = f.read().strip()
    except OSError:
        return False, None
    if pid and pid_alive(pid):
        return True, pid
    return False, None


def module_running(name):
    lock = os.path.join(LOCK_DIR, name)
    if not os.path.isdir(lock):
        return False, None
    try:
        with open(os.path.join(lock, "pid")) as f:
            pid = f.read().strip()
    except OSError:
        return True, None  # 锁在但 pid 未写全 = 正在启动
    if pid and pid != "0" and pid_alive(pid):
        return True, pid
    return False, None


def proc_user(pid):
    """进程以什么身份在跑，返回 "root" / "shell" / "app(10123)" / "system(1000)"。

    读 /proc/<pid>/status 的 Uid 行。uid 是判定免 root 是否成立的硬证据：
    框架本该以 shell(2000) 运行，若显示 root(0) 说明权限比预期大，
    显示 app(10xxx) 则说明根本没拿到 shell。
    """
    if not pid:
        return ""
    try:
        with open("/proc/%s/status" % pid, "r") as f:
            for line in f:
                if line.startswith("Uid:"):
                    uid = int(line.split()[1])
                    break
            else:
                return ""
    except (OSError, ValueError, IndexError):
        return ""
    if uid == 0:
        return "root"
    if uid == 2000:
        return "shell"
    if uid < 10000:
        return "system(%d)" % uid
    return "app(%d)" % uid


def module_run(name):
    """启动模块并**立即返回**，不等待模块的生命周期。

    为什么不直接跑 `sh mod_run.sh <name>` 然后同步取输出：

    `mod_run.sh` 内部的 `start_module` 会把模块的存活期「继承」给调用者 ——
    它自己会一直挂着不退出（这是框架靠 `kill -0` 轮询判定模块存活的必要条件）。
    而 WebUI 是「发指令就返回」的语义，用 subprocess.run 同步等只会等满超时、
    抛 TimeoutExpired，最后返回 500 让 App 误报「启动失败」——
    但模块其实已经在跑了。这个误报非常误导人。

    改为：分离进程启动 → 轮询锁确认真的起来了 → 返回。
    锁由 start_module 在拉起进程前写入，通常几百毫秒内可见。
    """
    if not _safe_module_name(name):
        return {"ok": False, "msg": "模块名不合法：%s" % name}

    main_sh = os.path.join(WORK_DIR, name, "main.sh")
    if not os.path.isfile(main_sh):
        return {"ok": False, "msg": "模块不存在：%s" % main_sh}

    # 幂等：已在运行就直接成功返回，不重复拉起
    running, pid = module_running(name)
    if running:
        return {"ok": True, "msg": "模块已在运行（PID %s）" % pid,
                "pid": pid, "already": True}

    # mod_run.sh 的失败原因（黑名单/冲突/不存在）会写在它的输出里，
    # 先落到临时文件，起不来时读回来当错误信息
    out_path = os.path.join(tempfile.gettempdir(),
                            "iwphone_modrun_%d_%d.log" % (os.getpid(), int(time.time())))
    try:
        logf = open(out_path, "wb")
    except OSError:
        logf = subprocess.DEVNULL

    try:
        subprocess.Popen(
            ["sh", os.path.join(FRAME_DIR, "mod_run.sh"), name],
            cwd=FRAME_DIR,
            stdout=logf, stderr=subprocess.STDOUT,
            stdin=subprocess.DEVNULL,
            start_new_session=True,   # 脱离 WebUI，别被它的生命周期牵连
        )
    except Exception as e:
        return {"ok": False, "msg": "启动失败：%s" % e}

    deadline = time.time() + 8
    while time.time() < deadline:
        time.sleep(0.3)
        running, pid = module_running(name)
        if running:
            return {"ok": True, "msg": "模块已启动（PID %s）" % pid, "pid": pid}

    detail = ""
    try:
        with open(out_path, "r", encoding="utf-8", errors="replace") as f:
            detail = f.read().strip()
    except OSError:
        pass
    finally:
        try:
            os.unlink(out_path)
        except OSError:
            pass

    return {
        "ok": False,
        "msg": detail or "模块未在预期时间内启动，请查看模块日志",
    }


def parse_prop(path):
    meta = {}
    try:
        with open(path, encoding="utf-8", errors="replace") as f:
            for line in f:
                line = line.strip()
                if "=" in line and not line.startswith("#"):
                    k, v = line.split("=", 1)
                    meta[k.strip()] = v.strip().strip('"')
    except OSError:
        pass
    return meta


def tail_text(path, n):
    try:
        with open(path, "rb") as f:
            f.seek(0, 2)
            size = f.tell()
            f.seek(max(0, size - 64 * 1024))
            data = f.read().decode("utf-8", errors="replace")
        lines = data.splitlines()
        return "\n".join(lines[-n:])
    except OSError:
        return ""


def sh_run(args, timeout=40, cwd=None):
    r = subprocess.run(args, capture_output=True, text=True, timeout=timeout, cwd=cwd)
    out = (r.stdout + r.stderr).strip()
    return r.returncode, out


def read_prop_cmd(key, default=""):
    """读一个系统属性（`getprop <key>`）。失败/空返回 default。"""
    try:
        rc, out = sh_run(["getprop", key], timeout=5)
        if rc == 0 and out:
            return out.splitlines()[0].strip()
    except Exception:
        pass
    return default


def selinux_mode():
    """SELinux 当前模式，返回「强制 / 宽容 / 已关闭 / 未知」。

    优先 `getenforce`，个别 ROM 没有该命令则回退读 selinuxfs。
    注意：App 进程（untrusted_app）读不到这些，必须由 WebUI（root）代读。
    """
    try:
        rc, out = sh_run(["getenforce"], timeout=5)
        if rc == 0 and out:
            m = out.strip().lower()
            if "enforcing" in m:
                return "强制"
            if "permissive" in m:
                return "宽容"
            if "disabled" in m:
                return "已关闭"
    except Exception:
        pass
    try:
        with open("/sys/fs/selinux/enforce", "r") as f:
            v = f.read().strip()
        if v == "1":
            return "强制"
        if v == "0":
            return "宽容"
    except OSError:
        pass
    return "未知"


# ---------------- 业务动作 ----------------
# ---------------- 资源冲突（与 conflict.sh / sandbox.sh 对齐） ----------------
STATE_DIR = os.path.join(IWPHONE_ROOT, "state")
CONFLICT_LOG = os.path.join(STATE_DIR, "conflicts.log")
WRITERS_DIR = os.path.join(STATE_DIR, "writers")
OWNERS_DIR = os.path.join(STATE_DIR, "owners")

# conflicts.log 每行格式：
#   L1 拦截： <时间>\t<想启动的模块>\t<占用者>\t<资源名>
#   L2 冲突： <时间>\tWRITER_CONFLICT\t<资源名>:<模块1>,<模块2>
#   L3 漂移： <时间>\tVALUE_DRIFT\t<资源名>\t<旧值>-><新值>


def parse_conflict_log(n=200):
    """解析 conflicts.log，返回结构化记录（最新的在前）。"""
    out = []
    try:
        with open(CONFLICT_LOG, "r", encoding="utf-8", errors="replace") as f:
            lines = f.readlines()
    except OSError:
        return out
    for line in lines[-n:]:
        line = line.rstrip("\n")
        if not line:
            continue
        parts = line.split("\t")
        if len(parts) < 3:
            continue
        ts, kind = parts[0], parts[1]
        if kind == "WRITER_CONFLICT":
            # <res>:<mod1>,<mod2>
            body = parts[2] if len(parts) > 2 else ""
            res, _, who = body.partition(":")
            out.append({
                "time": ts, "type": "writer",
                "resource": res,
                "modules": [m for m in who.split(",") if m],
                "message": "资源 %s 被多个模块写入" % res,
            })
        elif kind == "VALUE_DRIFT":
            res = parts[2] if len(parts) > 2 else ""
            chg = parts[3] if len(parts) > 3 else ""
            out.append({
                "time": ts, "type": "drift",
                "resource": res, "modules": [],
                "message": "资源 %s 值被外部改动（%s）" % (res, chg),
            })
        else:
            # L1 拦截： ts \t 想启动模块 \t 占用者 \t 资源名
            out.append({
                "time": ts, "type": "block",
                "resource": parts[3] if len(parts) > 3 else "",
                "modules": [kind, parts[2]] if len(parts) > 2 else [kind],
                "message": "模块 %s 因资源 %s 被 %s 占用而拒绝启动"
                           % (kind, parts[3] if len(parts) > 3 else "?",
                              parts[2] if len(parts) > 2 else "?"),
            })
    out.reverse()
    return out


def read_owners():
    """读 state/owners/<资源名>，返回 {资源名: [模块名,...]}。"""
    res = {}
    try:
        names = os.listdir(OWNERS_DIR)
    except OSError:
        return res
    for r in names:
        p = os.path.join(OWNERS_DIR, r)
        if not os.path.isfile(p):
            continue
        try:
            with open(p, "r", encoding="utf-8", errors="replace") as f:
                mods = sorted({ln.strip() for ln in f if ln.strip()})
        except OSError:
            continue
        if mods:
            res[r] = mods
    return res


def read_writers():
    """读 state/writers/<资源名>，返回 {资源名: [{module,time,cmd},...]}。"""
    res = {}
    try:
        names = os.listdir(WRITERS_DIR)
    except OSError:
        return res
    for r in names:
        p = os.path.join(WRITERS_DIR, r)
        if not os.path.isfile(p):
            continue
        rows = []
        try:
            with open(p, "r", encoding="utf-8", errors="replace") as f:
                for ln in f:
                    parts = ln.rstrip("\n").split("\t")
                    if len(parts) >= 3:
                        rows.append({"module": parts[0], "time": parts[1],
                                     "cmd": parts[2]})
        except OSError:
            continue
        if rows:
            res[r] = rows
    return res


def _merged_resources():
    """资源 → 模块集合：运行时记账 ∪ 模块声明。"""
    merged = {}
    for src in (read_owners(), read_declared()):
        for r, mods in src.items():
            merged.setdefault(r, set()).update(mods)
    return {k: sorted(v) for k, v in merged.items()}


def build_resource_map():
    """汇总资源占用：被谁声明、谁在写，并标记是否冲突。"""
    owners = _merged_resources()
    writers = read_writers()
    # 把只有 writers 没有 owners 的也并进来（异常情况兜底）
    allres = sorted(set(owners) | set(writers))
    items = []
    for r in allres:
        wmods = sorted({w["module"] for w in writers.get(r, [])})
        omods = owners.get(r, [])
        mods = sorted(set(wmods) | set(omods))
        items.append({
            "resource": r,
            "modules": mods,
            "writers": writers.get(r, []),
            "conflict": len(mods) > 1,
        })
    return items


def read_declared():
    """扫 work/*/iwphone.prop，返回 {资源名: [模块名,...]}。

    与 read_owners()（运行时记账）互补：声明是**事前**的意图，
    记账是**事后**的痕迹。只看记账会漏掉「刚装上还没跑」的模块，
    那样 UI 上就看不到冲突。
    """
    res = {}
    try:
        names = sorted(os.listdir(WORK_DIR))
    except OSError:
        return res
    for name in names:
        d = os.path.join(WORK_DIR, name)
        if not os.path.isdir(d):
            continue
        meta = parse_prop(os.path.join(d, "iwphone.prop"))
        raw = meta.get("exclusive", "") or ""
        for r in raw.replace(";", ",").split(","):
            r = r.strip()
            if r:
                res.setdefault(r, set()).add(name)
    return {k: sorted(v) for k, v in res.items()}


def module_conflicts():
    """给每个模块标注它声明的资源是否与别人重复。

    资源占用 = 运行时记账（owners）∪ 模块声明（exclusive）。
    后者覆盖「模块已安装但尚未运行」的情况。
    """
    res2mods = _merged_resources()

    # 模块 → 它碰的资源
    mod2res = {}
    for r, mods in res2mods.items():
        for m in mods:
            mod2res.setdefault(m, []).append(r)
    # 模块 → 被谁挡住（同资源其他模块）
    out = {}
    for m, rs in mod2res.items():
        blocked_by = set()
        for r in rs:
            for other in res2mods.get(r, []):
                if other != m:
                    blocked_by.add(other)
        out[m] = {
            "resources": sorted(rs),
            "blocked_by": sorted(blocked_by),
            "has_conflict": bool(blocked_by),
        }
    return out


def list_modules():
    mods = []
    try:
        names = sorted(os.listdir(WORK_DIR))
    except OSError:
        names = []
    # 冲突信息一次性算好，避免每个模块重复读盘
    try:
        cfmap = module_conflicts()
    except Exception:
        cfmap = {}
    for name in names:
        d = os.path.join(WORK_DIR, name)
        if not os.path.isdir(d):
            continue
        running, pid = module_running(name)
        meta = parse_prop(os.path.join(d, "iwphone.prop"))
        cf = cfmap.get(name, {})
        mods.append({
            "name": name,
            "running": running,
            "pid": pid,
            "has_main": os.path.isfile(os.path.join(d, "main.sh")),
            "title": meta.get("PackageName", name),
            "version": meta.get("version", ""),
            "author": meta.get("author", ""),
            "description": meta.get("description", ""),
            "exclusive": meta.get("exclusive", ""),
            "exclusive_group": meta.get("exclusive.group", ""),
            "resources": cf.get("resources", []),
            "blocked_by": cf.get("blocked_by", []),
            "has_conflict": cf.get("has_conflict", False),
            # 有 config.prop 的模块才在界面上给「配置」入口
            "has_config": os.path.isfile(os.path.join(d, "config.prop")),
            # 有 action.sh（Magisk/KernelSU/AxManager 式模块的「动作」）才给「动作」按钮
            "has_action": os.path.isfile(os.path.join(d, "action.sh")),
            # 有 webroot/（KernelSU 式 WebUI）才给「WebUI」入口
            "has_webroot": os.path.isdir(os.path.join(d, "webroot")),
            # 有快照（模块写过的资源可一键还原）
            "has_snapshot": os.path.isfile(
                os.path.join(SNAPSHOT_DIR, name + ".snap")
            ),
            # 兼容层预检结果（仅 module.prop 式模块有）
            "compatVerdict": _compat_verdict(d),
            "compatReasons": _compat_reasons(d),
        })
    return mods


# ============================================================
# 模块通用配置
#
# 模块作者只要在目录里放一份 config.prop 声明选项，App 就会自动生成
# 一个通用配置页 —— 不需要为每个模块单独写界面。
#
# config.prop 每行一个选项，竖线分隔 6 段：
#
#     键|类型|标签|默认值|可选值(逗号分隔,可空)|说明
#
# 例：
#     scale|enum|动画速度|0.5|0,0.5,1|0 关闭动画，1 系统默认
#     blur|bool|关闭窗口模糊|1||关掉后界面更流畅
#     host|text|DNS 主机名|dns.adguard.com||留空则用系统 DNS
#
# 类型：bool / enum / int / text
#
# 值落到同目录的 config.sh（shell 赋值语句），模块 main.sh 直接 source 即可：
#     cd "$(dirname "$0")"
#     [ -f ./config.sh ] && . ./config.sh
#     SCALE="${SCALE:-0.5}"
#
# 之所以用 shell 赋值文件而不是 JSON：模块是 shell 脚本，
# 让它 `. ./config.sh` 是最省事、零依赖的读取方式。
# ============================================================

# 类型别名：config.prop 里 bool/enum/int/text 与 Dart 侧的 toggle/select/
# number/text 两种拼法都接受（容易顺手写混，索性都收），对外统一归一化成前者
_TYPE_ALIASES = {
    "bool": "bool", "toggle": "bool",
    "enum": "enum", "select": "enum",
    "int": "int", "number": "int",
    "text": "text",
}
CONFIG_TYPES = ("bool", "enum", "int", "text")

# 键名必须是合法 shell 标识符（要拼进 config.sh，不能让模块注入任意内容）
_CONFIG_KEY_RE = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*$")


def module_dir(name):
    """模块目录；模块名不合法时返回 None（防路径穿越）。"""
    if not _safe_module_name(name):
        return None
    d = os.path.join(WORK_DIR, name)
    return d if os.path.isdir(d) else None


def parse_config_spec(mdir):
    """解析 config.prop，返回选项声明列表。

    任何一行格式不对就整行跳过（不抛异常）—— 模块自带的配置文件
    不该因为一行写错就让整个模块在界面上不可用。
    """
    specs = []
    path = os.path.join(mdir, "config.prop")
    try:
        with open(path, encoding="utf-8", errors="replace") as f:
            lines = f.readlines()
    except OSError:
        return specs

    for raw in lines:
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        parts = line.split("|")
        if len(parts) < 4:
            continue
        key = parts[0].strip()
        ctype = _TYPE_ALIASES.get(parts[1].strip().lower())
        if ctype is None:
            continue   # 未知类型，跳过该行
        label = parts[2].strip()
        default = parts[3].strip()
        choices = parts[4].strip() if len(parts) > 4 else ""
        desc = parts[5].strip() if len(parts) > 5 else ""

        if not _CONFIG_KEY_RE.match(key):
            continue

        specs.append({
            "key": key,
            "type": ctype,
            "label": label or key,
            "default": default,
            "values": [v for v in choices.split(",") if v != ""],
            "desc": desc,
        })
    return specs


def _shell_quote_value(v):
    """把值安全地写进 config.sh 的双引号里。

    只转义在双引号内仍具特殊含义的字符：\\ " $ ` 
    （换行也一并去掉，避免一行变多行导致语法错乱）
    """
    s = str(v).replace("\n", " ").replace("\r", " ")
    s = s.replace("\\", "\\\\")
    s = s.replace('"', '\\"')
    s = s.replace("$", "\\$")
    s = s.replace("`", "\\`")
    return s


def read_config_values(mdir, specs):
    """读取当前值：优先 config.sh，缺失则用 spec 里的默认值。

    config.sh 是 shell 赋值文件，这里用轻量解析而不是真的 source ——
    只认 `KEY="value"` / `KEY=value` / `KEY='value'` 三种形式。
    """
    values = {s["key"]: s["default"] for s in specs}
    if not specs:
        return values

    path = os.path.join(mdir, "config.sh")
    try:
        with open(path, encoding="utf-8", errors="replace") as f:
            text = f.read()
    except OSError:
        return values

    keys = {s["key"] for s in specs}
    for line in text.splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        if "=" not in line:
            continue
        k, v = line.split("=", 1)
        k = k.strip()
        if k not in keys:
            continue
        v = v.strip()
        # 去掉成对引号
        if len(v) >= 2 and v[0] == v[-1] and v[0] in ("'", '"'):
            v = v[1:-1]
        values[k] = v.replace('\\"', '"').replace("\\\\", "\\")
    return values


def validate_config_value(spec, value):
    """校验单个值；不合法返回 (False, 原因)。"""
    v = str(value)
    t = spec["type"]
    if t == "bool":
        if v not in ("0", "1", "true", "false", "yes", "no", "on", "off"):
            return False, "布尔值只能是 0/1"
        return True, ""
    if t == "enum":
        if spec["values"] and v not in spec["values"]:
            return False, "取值必须是 [%s] 之一" % ", ".join(spec["values"])
        return True, ""
    if t == "int":
        try:
            int(v)
        except ValueError:
            return False, "必须是整数"
        return True, ""
    # text：只限制长度，内容由 shell 转义保证安全
    if len(v) > 512:
        return False, "文本过长（上限 512 字符）"
    return True, ""


def module_config_get(name):
    mdir = module_dir(name)
    if mdir is None:
        return {"ok": False, "msg": "模块不存在：%s" % name}
    specs = parse_config_spec(mdir)
    if not specs:
        return {"ok": True, "has": False, "specs": [], "values": {},
                "msg": "该模块没有可配置项（缺少 config.prop）"}
    return {
        "ok": True,
        "has": True,
        "specs": specs,
        "values": read_config_values(mdir, specs),
    }


def module_config_set(name, incoming):
    """写回 config.sh。

    只接受 spec 里声明过的键 —— 未声明的键一律忽略。
    这是防注入的关键：config.sh 会被模块 source 执行，
    绝不能让用户提交的内容拼进 shell 语句。
    """
    mdir = module_dir(name)
    if mdir is None:
        return {"ok": False, "msg": "模块不存在：%s" % name}
    specs = parse_config_spec(mdir)
    if not specs:
        return {"ok": False, "msg": "该模块没有可配置项"}

    by_key = {s["key"]: s for s in specs}
    values = read_config_values(mdir, specs)

    for k, v in incoming.items():
        if k not in by_key:
            continue  # 未声明的键直接忽略
        ok, why = validate_config_value(by_key[k], v)
        if not ok:
            return {"ok": False, "msg": "%s：%s" % (by_key[k]["label"], why)}
        values[k] = str(v)

    path = os.path.join(mdir, "config.sh")
    buf = [
        "# 由 Shell Manager 生成 —— 模块 main.sh 直接 source 本文件即可读取配置",
        "# 请勿手工编辑：改动会在 App 里保存配置时被覆盖",
        "",
    ]
    for s in specs:
        # 统一写成大写：shell 里全大写是配置变量惯例，也避免
        # 与 PATH / HOME / IFS 这类小写环境变量撞名
        buf.append('%s="%s"' % (s["key"].upper(), _shell_quote_value(values.get(s["key"], s["default"]))))
    buf.append("")

    try:
        with open(path, "w", encoding="utf-8") as f:
            f.write("\n".join(buf))
    except OSError as e:
        return {"ok": False, "msg": "写入失败：%s" % e}

    return {"ok": True, "msg": "配置已保存", "values": values}


_WEBUI_MIME = {
    ".html": "text/html", ".htm": "text/html", ".js": "application/javascript",
    ".css": "text/css", ".json": "application/json", ".png": "image/png",
    ".jpg": "image/jpeg", ".jpeg": "image/jpeg", ".gif": "image/gif",
    ".svg": "image/svg+xml", ".ico": "image/x-icon", ".woff": "font/woff",
    ".woff2": "font/woff2", ".ttf": "font/ttf", ".txt": "text/plain",
}


def serve_module_webroot(name, sub):
    """服务模块自带的 webroot/（KernelSU 式每模块 WebUI）。

    路径规则：GET /mod/<模块名>/...  →  work/<模块名>/webroot/...
    空路径落到 index.html。
    """
    mdir = module_dir(name)
    if mdir is None:
        return None
    webroot = os.path.join(mdir, "webroot")
    if not os.path.isdir(webroot):
        return None

    rel = (sub or "").lstrip("/")
    if rel == "":
        rel = "index.html"

    # ★ 防目录穿越：unzip 出来的文件名理论上可含 ../，必须规范化后比对
    full = os.path.normpath(os.path.join(webroot, rel))
    if not full.startswith(os.path.abspath(webroot) + os.sep):
        return None
    if not os.path.isfile(full):
        return None

    ext = os.path.splitext(full)[1].lower()
    ctype = _WEBUI_MIME.get(ext, "application/octet-stream")
    try:
        with open(full, "rb") as f:
            data = f.read()
    except OSError:
        return None
    return (data, ctype)


_SNAP_MARK_RE = re.compile(r"#\s*\[([^\]]+)\]\s*$")


def _current_value_of(resource):
    """查某个资源当前的值（用于快照对照展示）。查不到就返回空串。"""
    if not resource:
        return ""
    if resource.startswith("prop."):
        rc, out = sh_run(["getprop", resource[5:]], timeout=10)
        return (out or "").strip() if rc == 0 else ""
    parts = resource.split(".", 1)
    if len(parts) == 2 and parts[0] in ("global", "secure", "system"):
        rc, out = sh_run(["settings", "get", parts[0], parts[1]], timeout=10)
        v = (out or "").strip()
        return v if rc == 0 else ""
    return ""


def module_snapshot(name):
    """读模块快照，给 App 做「还原前预览」。

    返回每项的：资源名 / 还原命令 / 当前值 / 是否可自动还原。
    用户点「还原」之前能看清到底会改什么 —— 盲还原太吓人。
    """
    # ★ 刻意不要求模块目录存在：模块被卸载后，它留下的快照仍应可查看/还原
    #   （卸载时快照会保留，见 module_uninstall）。否则"卸载=兜底失效"。
    if not _safe_module_name(name):
        return {"ok": False, "msg": "非法模块名：%s" % name}
    path = os.path.join(SNAPSHOT_DIR, name + ".snap")
    if not os.path.isfile(path):
        return {"ok": False, "msg": "该模块没有快照（快照在模块首次写系统资源时生成）"}

    items = []
    try:
        with open(path, encoding="utf-8", errors="replace") as f:
            for raw in f:
                line = raw.rstrip("\n").rstrip("\r")
                if not line.strip():
                    continue
                m = _SNAP_MARK_RE.search(line)
                res = m.group(1) if m else ""
                if line.lstrip().startswith("#"):
                    # 不可自动还原项：仍然展示，让用户知道这块要自己处理
                    items.append({
                        "resource": res,
                        "cmd": line.strip(),
                        "current": "",
                        "restorable": False,
                    })
                    continue
                items.append({
                    "resource": res,
                    "cmd": line.strip(),
                    "current": _current_value_of(res),
                    "restorable": True,
                })
    except OSError as e:
        return {"ok": False, "msg": "读取快照失败：%s" % e}

    return {
        "ok": True,
        "items": items,
        "count": len([i for i in items if i["restorable"]]),
        "skipped": len([i for i in items if not i["restorable"]]),
    }


def list_snapshots():
    """列出所有快照（含已卸载模块留下的"孤儿快照"）。

    孤儿快照是兜底的关键一环：模块被卸载了，但它改过的系统设置
    仍然可以还原 —— 前提是这些快照能被找到。
    """
    items = []
    try:
        names = sorted(os.listdir(SNAPSHOT_DIR))
    except OSError:
        names = []
    for f in names:
        if not f.endswith(".snap"):
            continue
        name = f[:-5]
        path = os.path.join(SNAPSHOT_DIR, f)
        restorable = 0
        skipped = 0
        try:
            with open(path, encoding="utf-8", errors="replace") as fh:
                for line in fh:
                    line = line.strip()
                    if not line:
                        continue
                    if line.startswith("#"):
                        skipped += 1
                    else:
                        restorable += 1
        except OSError:
            continue
        if restorable == 0 and skipped == 0:
            continue
        items.append({
            "name": name,
            "restorable": restorable,
            "skipped": skipped,
            "orphan": not os.path.isdir(os.path.join(WORK_DIR, name)),
            "mtime": int(os.path.getmtime(path)),
        })
    items.sort(key=lambda x: x["mtime"], reverse=True)
    return {"ok": True, "items": items}


def delete_snapshot(name):
    """删除某个快照（用户确认不再需要还原时清理）。"""
    if not _safe_module_name(name):
        return {"ok": False, "msg": "非法模块名：%s" % name}
    path = os.path.join(SNAPSHOT_DIR, name + ".snap")
    if not os.path.isfile(path):
        return {"ok": False, "msg": "快照不存在：%s" % name}
    try:
        os.remove(path)
    except OSError as e:
        return {"ok": False, "msg": "删除失败：%s" % e}
    return {"ok": True, "msg": "已删除 %s 的快照" % name}


def module_action(name):
    """执行模块的 action.sh（Magisk/KernelSU/AxManager 式模块的「动作」）。

    语义与 Magisk 的 action 按钮一致：用户手动触发的一次性任务，
    与常驻的 service.sh 互不影响。同步执行并回传输出（动作通常很快，
    给 60 秒上限；慢动作应自己把进度写进日志）。
    """
    mdir = module_dir(name)
    if mdir is None:
        return {"ok": False, "msg": "模块不存在：%s" % name}
    script = os.path.join(mdir, "action.sh")
    if not os.path.isfile(script):
        return {"ok": False, "msg": "该模块没有 action.sh"}
    rc, out = sh_run(["sh", script], timeout=60)
    return {"ok": rc == 0, "msg": out or "动作已执行"}


_COMPAT_VERDICT_LABEL = {
    "ok": "预计兼容",
    "blocked": "需要 Root 环境",
    "unknown": "无法自动判断",
}


def _compat_report_path(d):
    return os.path.join(d, ".compat_report")


def _compat_verdict(d):
    """兼容层预检判定：ok / blocked / unknown / 空串（原生模块无此文件）。"""
    rep = _compat_report_path(d)
    if not os.path.isfile(rep):
        return ""
    try:
        with open(rep, encoding="utf-8", errors="replace") as f:
            for line in f:
                if line.startswith("VERDICT="):
                    return line[8:].strip()
    except OSError:
        pass
    return ""


def _compat_reasons(d):
    """预检的原因/说明（多行文本，无 VERDICT/CAP 行）。"""
    rep = _compat_report_path(d)
    if not os.path.isfile(rep):
        return ""
    try:
        with open(rep, encoding="utf-8", errors="replace") as f:
            return "".join(
                ln for ln in f
                if ln.strip() and not ln.startswith(("VERDICT=", "CAP="))
            )
    except OSError:
        return ""


def module_log_path(name, kind):
    """模块日志文件路径。

    `.log`（module_log 写的）在 LOG_ROOT_DIR（/sdcard，便于用户直接查看）。

    `.out` / `.err`（模块进程的 stdout/stderr）自 2026-09-18 起改落在
    MODIO_DIR（原生文件系统）—— 因为 stdout 指向 /sdcard(FUSE) 时，
    `cmd` 类命令会因 fd 无法经 binder 传递而静默失败
    （`Failed transaction (2147483646)`）。见 env.sh 的 MODIO_DIR 注释。

    这里对 out/err 做「新位置优先、旧位置兜底」，保证升级前产生的
    历史日志仍然能读到。
    """
    sdcard_path = os.path.join(LOG_ROOT_DIR, "modules", name, "%s.%s" % (name, kind))
    if kind == "log":
        return sdcard_path

    native_path = os.path.join(MODIO_DIR, name, "%s.%s" % (name, kind))
    try:
        if os.path.isfile(native_path):
            return native_path
    except OSError:
        pass
    return sdcard_path


def list_packages():
    pkgs = []
    pdir = os.path.join(FRAME_DIR, "module")
    try:
        files = sorted(os.listdir(pdir))
    except OSError:
        files = []
    for f in files:
        if not f.endswith(".iwp"):
            continue
        name = f[:-4]
        pkgs.append({
            "name": name,
            "file": f,
            "installed": os.path.isdir(os.path.join(WORK_DIR, name)),
        })
    return pkgs


def runner_start():
    running, pid = daemon_status()
    if running:
        return {"ok": False, "msg": "守护进程已在运行（PID %s）" % pid}
    try:
        os.makedirs(LOG_ROOT_DIR, exist_ok=True)
        logf = open(os.path.join(LOG_ROOT_DIR, "main_stdout.log"), "ab")
        subprocess.Popen(
            ["sh", os.path.join(FRAME_DIR, "Main.sh")],
            cwd=FRAME_DIR, stdout=logf, stderr=subprocess.STDOUT,
            start_new_session=True, env=os.environ.copy())
    except Exception as e:
        return {"ok": False, "msg": "启动失败：%s" % e}
    time.sleep(0.6)
    running, pid = daemon_status()
    if running:
        return {"ok": True, "msg": "守护进程已启动（PID %s）" % pid, "pid": pid}
    return {"ok": False, "msg": "启动失败，请查看 main_stdout.log"}


def runner_stop():
    rc, out = sh_run(["sh", os.path.join(FRAME_DIR, "stop_runner.sh")])
    return {"ok": rc == 0, "msg": out or "已停止"}


def runner_restart():
    """重启守护进程：先停后启。

    停止与启动之间留出间隔，确保 PID 文件已删除、端口与锁已释放，
    否则 Main.sh 的 already_running 检查会判定「已在运行」而拒绝启动。
    """
    sh_run(["sh", os.path.join(FRAME_DIR, "stop_runner.sh")])
    time.sleep(2)
    res = runner_start()
    if res.get("ok"):
        return {"ok": True, "msg": "框架已重启"}
    return {"ok": False, "msg": "重启失败：%s" % res.get("msg", "未知原因")}


def _safe_module_name(name):
    """模块名校验，与框架 core.sh 的 validate_module 保持一致。

    卸载会执行 rmtree，必须严格阻断路径穿越 —— 否则 "../../" 之类的名字
    可能删掉工作目录之外的路径。
    """
    if not name or len(name) > 64:
        return False
    if ".." in name or "/" in name or "\\" in name:
        return False
    if any(c.isspace() for c in name):
        return False
    return True


def module_uninstall(name):
    """卸载模块：停止 → 跑模块清理钩子 → 删除模块目录 → 清理锁 / 触发文件 / 日志。

    关于模块自带的 uninstall.sh：历史上框架刻意不调用它，因为旧示例写的是
    "$IWPHONE_ROOT/Module"（大写 M），与实际的 work/ 不符，执行了也删不掉东西。
    但完全不调用又带来另一个问题 —— 模块把产物部署到工作目录**之外**时
    （例如把二进制拷到 /data/local/tmp），rmtree 清不到，会永久残留。

    因此改为「尽力执行、失败忽略」：先跑一次钩子用于清理外部产物，再用 rmtree
    兜底删目录。这样钩子写错也不会卡住卸载，真正的目录清理由框架保证。
    """
    if not _safe_module_name(name):
        return {"ok": False, "msg": "非法模块名：%s" % name}

    target = os.path.join(WORK_DIR, name)
    # 兜底：确认目标确实落在 WORK_DIR 内
    if os.path.dirname(os.path.realpath(target)) != os.path.realpath(WORK_DIR):
        return {"ok": False, "msg": "拒绝操作：路径越界"}

    # 1) 先停掉正在运行的实例（失败不阻断卸载流程）
    sh_run(["sh", os.path.join(FRAME_DIR, "mod_stop.sh"), name])

    # 2) 尽力跑一次模块自带的清理钩子 —— 用于清掉模块部署到工作目录之外的产物。
    #    失败只记录不阻断：钩子可能写错，真正的目录清理由下面的 rmtree 保证。
    hook_msg = ""
    hook = os.path.join(target, "uninstall.sh")
    if os.path.isfile(hook):
        try:
            rc, out = sh_run(["sh", hook], timeout=8, cwd=target)
            if rc != 0:
                hook_msg = out[-200:]
        except Exception as e:
            hook_msg = "%s: %s" % (type(e).__name__, e)

    # 3) 删除模块目录
    if not os.path.exists(target):
        return {"ok": False, "msg": "模块未安装：%s" % name}
    try:
        shutil.rmtree(target)
    except Exception as e:
        return {"ok": False, "msg": "删除失败：%s" % e}

    # 4) 清理锁、触发文件与沙箱目录、模块日志
    shutil.rmtree(os.path.join(LOCK_DIR, name), ignore_errors=True)
    for p in (os.path.join(TMP_DIR, name),
              os.path.join(TMP_DIR, "home_" + name),
              os.path.join(TMP_DIR, "sb_" + name)):
        if os.path.isdir(p):
            shutil.rmtree(p, ignore_errors=True)
        elif os.path.isfile(p):
            try:
                os.remove(p)
            except OSError:
                pass
    shutil.rmtree(os.path.join(LOG_ROOT_DIR, "modules", name), ignore_errors=True)

    msg = "已卸载：%s" % name
    if hook_msg:
        msg += "\n\n（模块清理钩子返回异常，已忽略，不影响卸载：%s）" % hook_msg
    return {"ok": True, "msg": msg}


# ---------------- 框架配置（env.sh 读写） ----------------

# 允许通过 WebUI 修改的配置项白名单。
# 刻意排除：
#   - 路径类（IWPHONE_ROOT / WORK_DIR / TMP_DIR / LOCK_DIR / PID_FILE / LOG_ROOT_DIR / SDCARD_DIR）
#     改了会让框架找不到自己的目录
#   - WEBUI_PORT 改了 App 会立刻失联（需同步改客户端，不宜在此暴露）
#   - COMMAND_BLACKLIST 是安全正则，改错等于关掉防护
CONFIG_SPECS = [
    # key, label, type, group, min, max, unit, desc
    ("POLL_SEC", "守护轮询间隔", "int", "运行行为", 1, 3600, "秒",
     "守护进程扫描触发目录的周期。越小响应越快，但更耗电。"),
    ("MAX_PARALLEL", "最大并行模块数", "int", "运行行为", 0, 64, "个",
     "同时运行模块的上限，0 表示不限制。"),
    ("MAX_RUNTIME_SEC", "单模块超时", "int", "运行行为", 0, 86400, "秒",
     "模块运行超过该时长会被强制终止，0 表示不限制。"),
    ("AUTO_CLEAN", "自动清理触发文件", "bool", "运行行为", 0, 0, "",
     "开启后模块启动时自动删除触发文件，避免重复触发。"),
    ("VERBOSE", "终端输出日志", "bool", "运行行为", 0, 0, "",
     "开启后框架日志同时打印到终端。"),
    ("PATH_ISOLATION", "模块环境隔离", "bool", "安全", 0, 0, "",
     "开启后模块在独立 HOME/TMPDIR 与受限 PATH 下运行。"),
    ("SANDBOX_PATH", "沙箱 PATH", "str", "安全", 0, 0, "",
     "模块沙箱内可用的命令路径，冒号分隔。"),
    ("CONTROL_ADBSH", "允许投递脚本", "bool", "安全", 0, 0, "",
     "开启后 /sdcard/iwphone 下的 readbsh 可触发执行投递脚本。"
     "注意：任何有存储权限的应用都能触发，介意请关闭。"),
    ("WEBUI_TOKEN", "访问令牌", "str", "WebUI", 0, 0, "",
     "非空时 WebUI 要求 ?token= 或 X-Token 头。设置后 App 需填同一令牌。"),
    ("LOGROTATE_ENABLE", "日志轮转", "bool", "日志", 0, 0, "",
     "开启后自动控制日志体积，防止长期运行吃满存储。"
     "单个日志超过上限即截断，只保留最近的尾部内容。"),
    ("LOGROTATE_MAX_BYTES", "单文件上限", "int", "日志", 65536, 104857600, "字节",
     "单个日志文件超过该大小会被截断。默认 2097152（2MB）。"),
    ("LOGROTATE_KEEP_DAYS", "框架日志保留", "int", "日志", 0, 365, "天",
     "按天分割的框架日志只保留最近几天，0 表示永久保留。默认 7。"),
    ("LOGROTATE_ORPHAN_DAYS", "清理孤儿日志", "int", "日志", 0, 365, "天",
     "清理「模块已卸载但日志目录仍在」的残留。0 表示关闭（默认），"
     "开启后只删除模块确实不存在、且已超龄的目录。"),
]


def _env_path():
    return os.path.join(FRAME_DIR, "env.sh")


def read_env_values(keys):
    """重新 source env.sh 读取指定变量的当前值。

    不缓存 —— 配置刚改过时要拿到最新值。
    """
    if not keys:
        return {}
    script = '. "%s/env.sh" >/dev/null 2>&1; ' % FRAME_DIR
    script += "; ".join('echo "%s=$%s"' % (k, k) for k in keys)
    try:
        r = subprocess.run(["sh", "-c", script], capture_output=True,
                           text=True, timeout=10)
    except Exception:
        return {}
    out = {}
    for line in r.stdout.splitlines():
        if "=" in line:
            k, v = line.split("=", 1)
            out[k.strip()] = v.strip()
    return out


def get_config():
    """返回可配置项的元数据与当前值。"""
    keys = [s[0] for s in CONFIG_SPECS]
    values = read_env_values(keys)
    items = []
    for key, label, typ, group, lo, hi, unit, desc in CONFIG_SPECS:
        items.append({
            "key": key,
            "label": label,
            "type": typ,
            "group": group,
            "min": lo,
            "max": hi,
            "unit": unit,
            "desc": desc,
            "value": values.get(key, ""),
        })
    return {"ok": True, "items": items, "env_path": _env_path()}


def _validate_config_value(spec, value):
    """校验取值，返回错误信息（None = 通过）。"""
    key, label, typ, _group, lo, hi, _unit, _desc = spec
    value = "" if value is None else str(value).strip()

    if typ == "int":
        if not re.fullmatch(r"-?\d+", value):
            return "%s 需要整数" % label
        n = int(value)
        if n < lo or n > hi:
            return "%s 需在 %d ~ %d 之间" % (label, lo, hi)
        return None

    if typ == "bool":
        if value not in ("0", "1"):
            return "%s 只能是 0 或 1" % label
        return None

    # str
    if "\n" in value or '"' in value:
        return "%s 不能包含换行或英文双引号" % label
    if "}" in value:
        return "%s 不能包含右花括号（会破坏 env.sh 的 ${...} 语法）" % label
    if len(value) > 512:
        return "%s 过长（上限 512 字符）" % label
    return None


def set_config(key, value):
    """修改 env.sh 中某个配置项的默认值。

    env.sh 的写法统一为：KEY="${KEY:-默认值}"  # 注释
    因此只替换 `:-` 与 `}` 之间的内容，注释与文件结构原样保留。
    """
    spec = next((s for s in CONFIG_SPECS if s[0] == key), None)
    if spec is None:
        return {"ok": False, "msg": "不允许修改该配置项：%s" % key}

    err = _validate_config_value(spec, value)
    if err:
        return {"ok": False, "msg": err}

    value = "" if value is None else str(value).strip()
    path = _env_path()
    try:
        with open(path, encoding="utf-8") as f:
            text = f.read()
    except OSError as e:
        return {"ok": False, "msg": "无法读取 env.sh：%s" % e}

    # 精确匹配 KEY="${KEY:-<旧值>}"，只替换 <旧值>。
    # ⚠️ 第 2 组必须用 [^}]* 精确圈定旧值，把 `}` 留给第 3 组。
    # 若写成 (.*?)(".*) 非贪婪匹配，`}` 会被一起吃进第 2 组而被替换掉，
    # 结果是 KEY="${KEY:-值  —— 引号未闭合，整个 env.sh 语法崩坏（已踩过这个坑）。
    pattern = re.compile(
        r'^(' + re.escape(key) + r'="\$\{' + re.escape(key) + r':-)([^}]*)(\}.*)$',
        re.MULTILINE)
    if not pattern.search(text):
        return {"ok": False, "msg": "在 env.sh 中找不到 %s 的赋值行" % key}

    # 首次通过 WebUI 修改时留一份原始备份
    bak = path + ".bak_webui"
    if not os.path.exists(bak):
        try:
            shutil.copy2(path, bak)
        except OSError:
            pass

    new_text = pattern.sub(lambda m: m.group(1) + value + m.group(3), text, count=1)

    # 写入前先做语法自检：env.sh 一旦被写坏，框架所有脚本都会失效。
    # 用 `sh -n` 校验临时文件，不通过就放弃本次写入。
    tmp = path + ".tmp_check"
    try:
        with open(tmp, "w", encoding="utf-8", newline="") as f:
            f.write(new_text)
        rc = subprocess.run(["sh", "-n", tmp], capture_output=True).returncode
    except Exception as e:
        try:
            os.remove(tmp)
        except OSError:
            pass
        return {"ok": False, "msg": "写入前校验失败：%s" % e}

    if rc != 0:
        try:
            os.remove(tmp)
        except OSError:
            pass
        return {"ok": False, "msg": "修改会导致 env.sh 语法错误，已放弃（原文件未动）"}

    try:
        shutil.move(tmp, path)
    except Exception as e:
        try:
            os.remove(tmp)
        except OSError:
            pass
        return {"ok": False, "msg": "写入 env.sh 失败：%s" % e}

    return {"ok": True, "msg": "%s 已更新为 %s" % (key, value or "（空）")}


# ---------------- 模块批量控制 ----------------

def _proc_children(pid):
    """取 pid 的直接子进程列表。"""
    out = []
    try:
        entries = os.listdir("/proc")
    except OSError:
        return out
    for e in entries:
        if not e.isdigit():
            continue
        try:
            with open("/proc/%s/stat" % e) as f:
                data = f.read()
        except OSError:
            continue
        # stat 格式：pid (comm) state ppid ...
        # comm 可能含空格与括号，所以从最后一个 ')' 之后解析
        rp = data.rfind(")")
        if rp < 0:
            continue
        parts = data[rp + 2:].split()
        if len(parts) < 2:
            continue
        try:
            if int(parts[1]) == pid:
                out.append(int(e))
        except ValueError:
            continue
    return out


def _kill_tree(pid, sig):
    """递归终止进程树：先子孙、后自身，避免留下孤儿进程。"""
    for c in _proc_children(pid):
        _kill_tree(c, sig)
    try:
        os.kill(pid, sig)
    except OSError:
        pass


def _find_module_processes():
    """扫描 /proc，找出工作目录落在 WORK_DIR 下的进程，返回 [(pid, 模块名)]。

    这是**不依赖锁**的兜底识别方式 —— 模块自我 daemon 化、或锁被清理之后，
    仍能凭 /proc/<pid>/cwd 把它找回来。
    """
    found = []
    prefix = os.path.realpath(WORK_DIR) + os.sep
    try:
        entries = os.listdir("/proc")
    except OSError:
        return found
    for e in entries:
        if not e.isdigit():
            continue
        pid = int(e)
        try:
            cwd = os.readlink("/proc/%d/cwd" % pid)
        except OSError:
            continue
        if not cwd.startswith(prefix):
            continue
        name = cwd[len(prefix):].split(os.sep)[0]
        if name:
            found.append((pid, name))
    return found


def modules_stop_all():
    """按锁逐个正常停止（走 mod_stop.sh，会写模块日志）。"""
    try:
        names = sorted(d for d in os.listdir(LOCK_DIR)
                       if os.path.isdir(os.path.join(LOCK_DIR, d)))
    except OSError:
        names = []
    if not names:
        return {"ok": True, "msg": "当前没有运行中的模块",
                "stopped": [], "failed": []}
    ok, bad = [], []
    for n in names:
        rc, _ = sh_run(["sh", os.path.join(FRAME_DIR, "mod_stop.sh"), n])
        (ok if rc == 0 else bad).append(n)
    msg = "已停止 %d 个模块" % len(ok)
    if bad:
        msg += "，%d 个失败" % len(bad)
    return {"ok": True, "msg": msg, "stopped": ok, "failed": bad}


def modules_force_stop_all():
    """强制停止全部模块进程 —— **完全不依赖锁**。

    现有 mod_stop.sh 只认锁里记录的 PID；锁一旦丢失（模块自我 daemon 化、
    锁被清理）它就彻底失效，脚本自己也在提示"需手动造 end 文件"。
    这里改为扫描 /proc、按工作目录识别模块进程，连同子孙一起终止，
    最后清理残留锁与触发文件。
    """
    procs = _find_module_processes()
    if not procs:
        # 没有进程也要清锁（锁可能已残留）
        _purge_module_runtime()
        return {"ok": True, "msg": "没有发现运行中的模块进程",
                "killed": [], "count": 0}

    killed = sorted({name for _pid, name in procs})
    for pid, _name in procs:
        _kill_tree(pid, signal.SIGTERM)
    time.sleep(1)
    for pid, _name in procs:
        if os.path.exists("/proc/%d" % pid):
            _kill_tree(pid, signal.SIGKILL)
    time.sleep(0.5)

    _purge_module_runtime()

    remaining = _find_module_processes()
    if remaining:
        return {"ok": False,
                "msg": "仍有 %d 个模块进程未能终止" % len(remaining),
                "killed": killed, "count": len(procs)}
    return {"ok": True,
            "msg": "已强制终止 %d 个模块进程（%s）" % (len(procs), "、".join(killed)),
            "killed": killed, "count": len(procs)}


def _purge_module_runtime():
    """清理所有模块锁与触发文件（强制停止后调用）。"""
    try:
        for d in os.listdir(LOCK_DIR):
            p = os.path.join(LOCK_DIR, d)
            if os.path.isdir(p):
                shutil.rmtree(p, ignore_errors=True)
    except OSError:
        pass
    try:
        for f in os.listdir(TMP_DIR):
            p = os.path.join(TMP_DIR, f)
            # 只删文件（触发文件）；home_/sb_ 沙箱目录保留，避免影响后续启动
            if os.path.isfile(p):
                try:
                    os.remove(p)
                except OSError:
                    pass
    except OSError:
        pass


def modules_restart_all():
    """重启全部模块：只重启「原先在运行的」，不会顺带启动未运行模块。

    先强制全停（保证没有残留进程抢占），再逐个 mod_run.sh 拉起。
    """
    names = {name for _pid, name in _find_module_processes()}
    try:
        for d in os.listdir(LOCK_DIR):
            if os.path.isdir(os.path.join(LOCK_DIR, d)):
                names.add(d)
    except OSError:
        pass

    targets = sorted(n for n in names
                     if os.path.isfile(os.path.join(WORK_DIR, n, "main.sh")))
    if not targets:
        return {"ok": True, "msg": "没有在运行的模块，无需重启",
                "restarted": [], "failed": []}

    modules_force_stop_all()
    time.sleep(1)

    ok, bad = [], []
    for n in targets:
        rc, _ = sh_run(["sh", os.path.join(FRAME_DIR, "mod_run.sh"), n])
        (ok if rc == 0 else bad).append(n)

    msg = "已重启 %d 个模块" % len(ok)
    if bad:
        msg += "，%d 个失败" % len(bad)
    return {"ok": True, "msg": msg, "restarted": ok, "failed": bad}


# ---------------- 内置终端：命令执行 ----------------

def run_shell_command(cmd, cwd=None, timeout=None):
    """执行一条 shell 命令并返回输出，供 App 内置终端与工具调用使用。

    与框架的关系：这条通道与模块执行**互相独立**，不经过锁、不写模块日志，
    等价于用户在 adb shell 里手敲一条命令（例如 `sh uid2pkg.sh <文件>`、
    投递 readbsh 脚本等）。

    安全约束（终端天然高危，三层一起收）：
      1) 复用 env.sh 的 COMMAND_BLACKLIST 拦截删库级命令；
      2) 超时强制 1~60 秒，避免长任务占死 WebUI 线程；
      3) WebUI 本身仅绑定 127.0.0.1。
    """
    if not cmd or not cmd.strip():
        return {"ok": False, "msg": "命令为空"}
    if len(cmd) > 4096:
        return {"ok": False, "msg": "命令过长（上限 4096 字符）"}

    # 超时：默认 10s，夹在 1~60s
    try:
        t = float(timeout) if timeout not in (None, "") else 10.0
    except (TypeError, ValueError):
        t = 10.0
    t = max(1.0, min(t, 60.0))

    # 高危命令黑名单（与模块扫描同一套正则）。
    # 把命令写进临时文件再交给 grep -E，避免把正则拼进 shell 造成注入。
    bl = CFG.get("COMMAND_BLACKLIST", "")
    if bl:
        tmpf = None
        try:
            with tempfile.NamedTemporaryFile("w", suffix=".cmd",
                                             delete=False) as tf:
                tf.write(cmd)
                tmpf = tf.name
            rc = subprocess.run(["grep", "-qE", bl, tmpf],
                                capture_output=True).returncode
            if rc == 0:
                return {"ok": False, "msg": "命令命中框架黑名单，已拒绝执行"}
        except Exception:
            # 黑名单自检失败时保守放行（终端是显式人工操作，风险由使用者承担）
            pass
        finally:
            if tmpf:
                try:
                    os.remove(tmpf)
                except OSError:
                    pass

    run_cwd = cwd if (cwd and os.path.isdir(cwd)) else None
    try:
        r = subprocess.run(
            ["sh", "-c", cmd],
            cwd=run_cwd,
            capture_output=True, text=True,
            timeout=t,
        )
    except subprocess.TimeoutExpired:
        return {"ok": False, "msg": "命令执行超时（上限 %ds）" % int(t)}
    except Exception as e:
        return {"ok": False, "msg": "执行失败：%s" % e}

    # 输出截断，避免超大输出撑爆 App
    return {
        "ok": True,
        "exitCode": r.returncode,
        "stdout": (r.stdout or "")[-20000:],
        "stderr": (r.stderr or "")[-20000:],
        "cwd": run_cwd or "",
    }


# ---------------- 整体卸载框架 ----------------

def framework_uninstall():
    """卸载整个框架（停 WebUI + 守护 + 模块，删除全部目录）。

    ⚠️ 关键点：uninstall.sh 会**停掉 WebUI 自己** —— 若同步执行，
    这个 HTTP 响应根本发不出去，App 只会看到连接被断开，
    无法区分「卸载成功」还是「网络出错」。所以改为延迟执行：
    先把响应返回，3 秒后再用独立进程跑 uninstall.sh。
    """
    script = os.path.join(FRAME_DIR, "uninstall.sh")
    if not os.path.isfile(script):
        return {"ok": False, "msg": "找不到 uninstall.sh（框架目录可能已被删除）"}

    try:
        # 用 "$0" 传路径，避免路径中的特殊字符被 shell 解释
        subprocess.Popen(
            ["sh", "-c", "sleep 3; exec sh \"$0\" y", script],
            cwd=FRAME_DIR,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            start_new_session=True,
        )
    except Exception as e:
        return {"ok": False, "msg": "无法启动卸载任务：%s" % e}

    return {
        "ok": True,
        "delay": 3,
        "msg": "卸载已启动，约 3 秒后执行。\n\n"
               "将删除：\n"
               "· 运行时目录（全部已装模块、锁、触发文件）\n"
               "· 日志目录与状态镜像\n\n"
               "框架源文件目录会保留，方便日后重新安装。\n"
               "App 随后会与 WebUI 断开连接。",
    }


def latest_runner_log(n):
    try:
        files = [f for f in os.listdir(LOG_ROOT_DIR) if f.startswith("modrunner_")]
    except OSError:
        return ""
    if not files:
        return ""
    files.sort(reverse=True)
    return tail_text(os.path.join(LOG_ROOT_DIR, files[0]), n)


# ---------------- 日志清空 / 导出 ----------------
# 导出目标放在 /sdcard/Download/iwphone_logs/ —— 用户用文件管理器就能找到。
# 不放 /sdcard/iwphone/ 下面：那是框架自己的目录，卸载框架时会被一并删除。
EXPORT_DIR = os.path.join("/sdcard", "Download", "iwphone_logs")

LOG_KINDS = ("log", "out", "err")


def _safe_module_name(name):
    """模块名校验：只允许单层目录名，挡掉路径穿越。"""
    if not name or name in (".", ".."):
        return False
    if "/" in name or "\\" in name or "\x00" in name:
        return False
    return True


def module_log_paths(name, include_launcher=True):
    """模块的日志文件路径（不管存不存在）。

    除 UI 展示的 log/out/err 三种外，还包括 `launcher.log` ——
    那是 core.sh 重定向的启动输出，属于同一个日志目录，
    清空时不带上它会出现「已清空但磁盘占用没变」的困惑。
    """
    base = os.path.join(LOG_ROOT_DIR, "modules", name)
    paths = [os.path.join(base, "%s.%s" % (name, k)) for k in LOG_KINDS]
    if include_launcher:
        paths.append(os.path.join(base, "launcher.log"))
    return paths


def runner_log_paths():
    """框架守护日志（modrunner_*.log），按名字倒序（新的在前）。"""
    try:
        files = [f for f in os.listdir(LOG_ROOT_DIR) if f.startswith("modrunner_")]
    except OSError:
        return []
    files.sort(reverse=True)
    return [os.path.join(LOG_ROOT_DIR, f) for f in files]


def clear_logs(scope, name="", kind=""):
    """清空日志文件内容（**截断**，不是删除文件）。

    截断而非删除的原因：框架/模块用 `>>` append 写日志，文件被删走后
    它们持有的 fd 会继续写进一个「已无名字」的 inode，日志就再也看不到。
    原地截断（open "w"）能保持 inode 不变，正在运行的模块不受影响。

    scope = "runner" 清框架日志；scope = "module" 清指定模块的日志。
    kind 非空时只清该类型，否则清模块的全部三种。
    """
    if scope == "runner":
        paths = runner_log_paths()
        label = "框架日志"
    else:
        if not _safe_module_name(name):
            return {"ok": False, "msg": "模块名不合法：%s" % name}
        paths = module_log_paths(name)
        if kind in LOG_KINDS:
            paths = [p for p in paths if p.endswith("." + kind)]
        label = "模块「%s」的日志" % name

    cleared, missing = [], []
    for p in paths:
        if not os.path.isfile(p):
            missing.append(os.path.basename(p))
            continue
        try:
            with open(p, "w"):
                pass
        except OSError as e:
            return {
                "ok": False,
                "msg": "清空 %s 失败：%s" % (os.path.basename(p), e),
            }
        cleared.append(os.path.basename(p))

    if not cleared:
        hint = "（日志文件不存在，可能从未产生过输出）" if missing else ""
        return {"ok": False, "msg": "没有可清空的日志文件%s" % hint}
    return {
        "ok": True,
        "msg": "已清空 %s：%s" % (label, "、".join(cleared)),
        "cleared": cleared,
    }


def export_log(scope, name="", kind="log"):
    """把一份日志复制到 [EXPORT_DIR]，返回落盘路径。

    由 WebUI（root）执行复制 —— App 进程是 untrusted_app，
    写 /sdcard/Download 需要存储权限，交给 root 侧更稳。
    """
    if scope == "runner":
        paths = runner_log_paths()
        if not paths:
            return {"ok": False, "msg": "没有框架日志文件（守护可能未运行过）"}
        src = paths[0]
        # 源文件名本身就带日期（modrunner_20260917.log），
        # 不再拼源文件名，否则日期会重复两遍。
        safe = "iwphone_framework"
    else:
        if not _safe_module_name(name):
            return {"ok": False, "msg": "模块名不合法：%s" % name}
        if kind not in LOG_KINDS:
            kind = "log"
        src = os.path.join(LOG_ROOT_DIR, "modules", name, "%s.%s" % (name, kind))
        safe = "%s_%s" % (name, kind)

    if not os.path.isfile(src):
        return {"ok": False, "msg": "日志文件不存在：%s" % src}

    try:
        os.makedirs(EXPORT_DIR, exist_ok=True)
    except OSError as e:
        return {"ok": False, "msg": "无法创建导出目录：%s" % e}

    # 文件名里去掉可能干扰 shell / 文件系统的字符
    safe = re.sub(r"[^\w.\-]", "_", safe)
    dst = os.path.join(EXPORT_DIR, "%s_%s.log" % (safe, time.strftime("%Y%m%d_%H%M%S")))
    try:
        shutil.copyfile(src, dst)
        os.chmod(dst, 0o644)
    except OSError as e:
        return {"ok": False, "msg": "导出失败：%s" % e}

    return {
        "ok": True,
        "msg": "已导出到 %s" % dst,
        "path": dst,
        "size": os.path.getsize(dst),
    }


# ---------------- HTTP 处理 ----------------
class Handler(BaseHTTPRequestHandler):
    server_version = "iwphone-webui/3.0"

    def log_message(self, fmt, *args):
        sys.stderr.write("[%s] %s\n" % (time.strftime("%H:%M:%S"), fmt % args))
        sys.stderr.flush()

    # ---- 响应工具 ----
    def _send(self, body, code=200, ctype="text/plain; charset=utf-8"):
        if isinstance(body, str):
            body = body.encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def _json(self, obj, code=200):
        self._send(json.dumps(obj, ensure_ascii=False), code,
                   "application/json; charset=utf-8")

    def _auth(self):
        token = current_token()
        if not token:
            # 没设访问密钥 → 放行，但记一次警告。
            #
            # 这是产品决策（用户明确要求密钥可选）：没密钥时框架照样能用。
            # 代价要说清楚 —— /api/shell 以 shell 权限执行命令且 WebUI 监听回环口，
            # 此时**同设备任何有网络权限的应用都能调用它**。
            # 用户后来在「设置 → 访问密钥」补上即可，不需要重新部署。
            if not _warned_no_token:
                _warned_no_token.add("warned")
                self.log_message(
                    "[WARN] 未设置访问密钥，WebUI 处于开放状态"
                    "（同设备其它应用可调用 /api/shell）")
            return True
        q = parse_qs(urlparse(self.path).query)
        if q.get("token", [""])[0] == token:
            return True
        return self.headers.get("X-Token", "") == token

    # ---- GET ----
    def do_GET(self):
        if not self._auth():
            return self._json({"ok": False, "msg": "未授权：缺少有效 token"}, 403)
        u = urlparse(self.path)
        path = unquote(u.path)
        q = parse_qs(u.query)
        try:
            if path in ("/", "/index.html"):
                return self._serve_index()
            if path == "/api/status":
                return self._api_status()
            if path == "/api/modules":
                return self._json({"ok": True, "modules": list_modules()})
            if path == "/api/packages":
                return self._json({"ok": True, "packages": list_packages()})
            if path == "/api/config":
                return self._json(get_config())
            if path == "/api/conflicts":
                n = int(q.get("tail", ["200"])[0])
                return self._json({
                    "ok": True,
                    "conflicts": parse_conflict_log(n),
                    "resources": build_resource_map(),
                })
            if path == "/api/resources":
                return self._json({"ok": True, "resources": build_resource_map()})
            if path == "/api/runner/log":
                n = int(q.get("tail", ["100"])[0])
                return self._json({"ok": True, "text": latest_runner_log(n)})
            m = re.match(r"^/mod/([^/]+)(/.*)?$", path)
            if m:
                # 模块自带 WebUI（KernelSU 式）。同一个 HTTP 服务里，
                # 模块页面可以直接 fetch /api/shell 等本服务的特权接口。
                served = serve_module_webroot(m.group(1), m.group(2) or "/")
                if served is None:
                    return self._json({"ok": False, "msg": "WebUI 不存在"}, 404)
                data, ctype = served
                self.send_response(200)
                self.send_header("Content-Type", ctype)
                self.send_header("Content-Length", str(len(data)))
                self.end_headers()
                self.wfile.write(data)
                return None
            if path == "/api/snapshots":
                return self._json(list_snapshots())
            m = re.match(r"^/api/module/([^/]+)/snapshot$", path)
            if m:
                return self._json(module_snapshot(m.group(1)))
            m = re.match(r"^/api/module/([^/]+)/config$", path)
            if m:
                return self._json(module_config_get(m.group(1)))
            m = re.match(r"^/api/module/([^/]+)/log$", path)
            if m:
                return self._api_module_log(m.group(1), q)
            return self._json({"ok": False, "msg": "未知路径：%s" % path}, 404)
        except Exception as e:
            return self._json({"ok": False, "msg": "服务器错误：%s" % e}, 500)

    # ---- POST ----
    def do_POST(self):
        if not self._auth():
            return self._json({"ok": False, "msg": "未授权：缺少有效 token"}, 403)
        u = urlparse(self.path)
        path = unquote(u.path)
        q = parse_qs(u.query)
        # 读取并丢弃请求体（API 全部路径驱动，参数一律走 query string）
        try:
            length = int(self.headers.get("Content-Length", "0") or "0")
            if length > 0:
                self.rfile.read(length)
        except Exception:
            pass
        try:
            if path == "/api/config":
                return self._json(set_config(
                    q.get("key", [""])[0],
                    q.get("value", [""])[0],
                ))
            if path == "/api/shell":
                return self._json(run_shell_command(
                    q.get("cmd", [""])[0],
                    q.get("cwd", [""])[0],
                    q.get("timeout", [""])[0],
                ))
            if path == "/api/uninstall":
                return self._json(framework_uninstall())
            if path == "/api/modules/stop-all":
                return self._json(modules_stop_all())
            if path == "/api/modules/force-stop-all":
                return self._json(modules_force_stop_all())
            if path == "/api/modules/restart-all":
                return self._json(modules_restart_all())
            if path == "/api/runner/start":
                return self._json(runner_start())
            if path == "/api/runner/stop":
                return self._json(runner_stop())
            if path == "/api/runner/restart":
                return self._json(runner_restart())
            if path == "/api/log/clear":
                return self._json(clear_logs(
                    q.get("scope", ["module"])[0],
                    q.get("name", [""])[0],
                    q.get("kind", [""])[0],
                ))
            if path == "/api/log/export":
                return self._json(export_log(
                    q.get("scope", ["module"])[0],
                    q.get("name", [""])[0],
                    q.get("kind", ["log"])[0],
                ))
            if path == "/api/sync":
                state_dir = os.path.join(SDCARD_DIR, "state")
                os.makedirs(state_dir, exist_ok=True)
                rc, out = sh_run(["sh", os.path.join(FRAME_DIR, "sync.sh"),
                                  IWPHONE_ROOT, state_dir], timeout=120)
                return self._json({"ok": rc == 0, "msg": out or "同步完成"})
            m = re.match(r"^/api/module/([^/]+)/action$", path)
            if m:
                return self._json(module_action(m.group(1)))
            m = re.match(r"^/api/snapshot/([^/]+)/delete$", path)
            if m:
                return self._json(delete_snapshot(m.group(1)))
            m = re.match(r"^/api/module/([^/]+)/restore$", path)
            if m:
                # 快照还原：把模块改过的系统资源恢复到它动手之前的原值。
                #
                # ★ 必须先停模块 —— 常驻模块的守卫循环会周期性地把值改回去，
                #   不停模块就还原等于白还原（改回去 → 又被覆盖）。
                name = m.group(1)
                stopped = ""
                running, _ = module_running(name)
                if running:
                    # 这里没有独立的 module_stop 函数，直接走框架的停止脚本
                    # （与 module_uninstall 里的做法一致）
                    sh_run(
                        ["sh", os.path.join(FRAME_DIR, "mod_stop.sh"), name],
                        timeout=30,
                    )
                    stopped = "（已先停止该模块，避免它把设置改回去）"
                rc, out = sh_run(
                    ["sh", os.path.join(FRAME_DIR, "restore_snapshot.sh"), name],
                    timeout=120,
                )
                return self._json(
                    {"ok": rc == 0, "msg": (out or "已还原") + stopped}
                )
            m = re.match(r"^/api/module/([^/]+)/config$", path)
            if m:
                # 参数走 query string（与项目其它接口一致）：?键=值&键=值
                flat = {}
                for k, v in q.items():
                    flat[k] = v[0] if isinstance(v, list) and v else ""
                return self._json(module_config_set(m.group(1), flat))
            m = re.match(r"^/api/module/([^/]+)/(run|stop|install)$", path)
            if m:
                return self._api_module_action(m.group(1), m.group(2))
            m = re.match(r"^/api/module/([^/]+)/uninstall$", path)
            if m:
                return self._json(module_uninstall(m.group(1)))
            return self._json({"ok": False, "msg": "未知路径：%s" % path}, 404)
        except Exception as e:
            return self._json({"ok": False, "msg": "服务器错误：%s" % e}, 500)

    # ---- 各端点 ----
    def _serve_index(self):
        try:
            with open(STATIC_INDEX, "rb") as f:
                return self._send(f.read(), 200, "text/html; charset=utf-8")
        except OSError:
            return self._send("index.html 缺失：%s" % STATIC_INDEX, 500)

    def _api_status(self):
        running, pid = daemon_status()
        mods = list_modules()
        webui_pid = os.getpid()
        return self._json({
            "ok": True,
            "daemon": {
                "running": running,
                "pid": pid,
                # 以什么身份在跑：root / shell / app(N)。
                # 免 root 方案下期望是 shell —— 这是最直观的验证点。
                "user": proc_user(pid),
            },
            "webui": {
                "pid": webui_pid,
                "user": proc_user(webui_pid),
            },
            "counts": {
                "modules": len(mods),
                "running": sum(1 for m in mods if m["running"]),
            },
            "config": {
                "work_dir": WORK_DIR,
                "log_dir": LOG_ROOT_DIR,
                "sdcard_dir": SDCARD_DIR,
            },
            # 设备侧只读属性。App 进程是 untrusted_app，读不到
            # /sys/fs/selinux/*（SELinux 拒绝），所以由这里的 root 上下文代读。
            "system": {
                "selinux": selinux_mode(),
                "abi": read_prop_cmd("ro.product.cpu.abi"),
            },
        })

    def _api_module_log(self, name, q):
        kind = q.get("type", ["log"])[0]
        if kind not in ("log", "out", "err"):
            kind = "log"
        n = int(q.get("tail", ["200"])[0])
        path = module_log_path(name, kind)
        running, pid = module_running(name)
        return self._json({
            "ok": True, "name": name, "type": kind,
            "running": running, "pid": pid,
            "text": tail_text(path, n),
        })

    def _api_module_action(self, name, action):
        # run 必须走非阻塞路径 —— 见 module_run() 的注释：
        # mod_run.sh 会持有模块生命周期不退出，同步等必然超时误报失败。
        if action == "run":
            return self._json(module_run(name))
        script = {"stop": "mod_stop.sh",
                  "install": "mod_install.sh"}[action]
        rc, out = sh_run(["sh", os.path.join(FRAME_DIR, script), name])
        return self._json({"ok": rc == 0, "msg": out})


def main():
    os.makedirs(LOG_ROOT_DIR, exist_ok=True)
    server = ThreadingHTTPServer(("127.0.0.1", WEBUI_PORT), Handler)
    print("iwphone WebUI 已启动：http://127.0.0.1:%d" % WEBUI_PORT, flush=True)
    if WEBUI_TOKEN:
        print("访问令牌已启用：?token=%s" % WEBUI_TOKEN, flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()

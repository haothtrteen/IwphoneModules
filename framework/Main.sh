#!/system/bin/sh
# =====================================================
# iwphone modrunner v3 · 综合守护进程（Main.sh）
#
# 常驻运行，每 POLL_SEC 秒执行一轮：
#   1. 消费 /sdcard/iwphone 下的命令文件（reupdate / readbsh / rebooti）
#   2. 调用 iwphone.sh 扫描并执行触发目录中的模块
#   3. 调用 logrotate.sh 做日志轮转（内部按间隔节流，不会每轮都扫盘）
#
# 用法：
#   sh Main.sh           前台运行（Ctrl+C 退出）
#   sh Main.sh &         后台运行
# 停止：sh stop_runner.sh，或在 $IWPHONE_ROOT 下创建 end 文件
#
# 命令文件（在 /sdcard/iwphone 下创建同名文件即生效，消费后自动删除）：
#   reupdate   把执行区镜像同步到 /sdcard/iwphone/state/（方便直接查看运行状态）
#   readbsh    执行 /sdcard/iwphone/adbsh/main.sh（用户投递脚本；CONTROL_ADBSH=0 可关闭）
#   rebooti    停止所有运行中的模块
# =====================================================
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
. "$SCRIPT_DIR/env.sh"
. "$SCRIPT_DIR/core.sh"
. "$SCRIPT_DIR/logrotate.sh"

END_FILE="$IWPHONE_ROOT/end"
STATE_DIR="$SDCARD_DIR/state"

graceful_exit() {
    log "👋 Main.sh 守护退出（运行中的模块不受影响）"
    rm -f "$PID_FILE" "$END_FILE"
    exit 0
}

already_running() {
    if [ -f "$PID_FILE" ]; then
        _old=$(cat "$PID_FILE" 2>/dev/null)
        if [ -n "$_old" ] && ps -A -o pid= 2>/dev/null | grep -q "^[[:space:]]*${_old}[[:space:]]*$"; then
            return 0
        fi
    fi
    return 1
}

# 执行区 → /sdcard 状态镜像。
#
# 只镜像 work/ —— 那是 App 在 WebUI 不可达时唯一会用到的兜底数据
# （/sdcard/iwphone/state/work/<模块>/iwphone.prop）。
#
# ★ 不要整个 IWPHONE_ROOT 全量镜像：框架代码、webui/runtime（解压 32MB）、
#   module/*.iwp 现在都和它同级，全量同步每轮都要算几十 MB 的 MD5，
#   而且会把 state/webui_token 这类机密文件写到公共存储上。
sync_state() {
    [ -d "$IWPHONE_ROOT/work" ] || return 0
    mkdir -p "$STATE_DIR/work" 2>/dev/null
    sh "$SCRIPT_DIR/sync.sh" "$IWPHONE_ROOT/work" "$STATE_DIR/work" >> "$RUN_LOG" 2>&1
}

consume_commands() {
    # reupdate：手动触发一次状态同步
    if [ -f "$SDCARD_DIR/reupdate" ]; then
        rm -f "$SDCARD_DIR/reupdate"
        log "🔄 reupdate：同步执行区 → $STATE_DIR"
        sync_state
    fi

    # readbsh：执行用户投递脚本（无 App 场景的主要操作方式）
    if [ -f "$SDCARD_DIR/readbsh" ]; then
        rm -f "$SDCARD_DIR/readbsh"
        if [ "$CONTROL_ADBSH" -eq 1 ]; then
            if [ -f "$SDCARD_DIR/adbsh/main.sh" ]; then
                log "▶️ readbsh：执行 $SDCARD_DIR/adbsh/main.sh"
                ( cd "$SDCARD_DIR/adbsh" && sh ./main.sh ) >> "$RUN_LOG" 2>&1
                log "✅ readbsh：执行完成"
            else
                log "⚠️ readbsh：未找到 $SDCARD_DIR/adbsh/main.sh"
            fi
        else
            log "⚠️ readbsh：通道已禁用（CONTROL_ADBSH=0），忽略"
        fi
    fi

    # rebooti：停止所有运行中的模块（守护本身继续运行）
    if [ -f "$SDCARD_DIR/rebooti" ]; then
        rm -f "$SDCARD_DIR/rebooti"
        log "🔄 rebooti：停止所有运行中的模块"
        sh "$SCRIPT_DIR/stop_runner.sh" modules
    fi
}

# -----------------------------------------------------
# WebUI 看护
#
# WebUI 是 App 读取一切状态的唯一通道（只有模块列表和日志有 /sdcard 兜底）。
# 它由 webui_start.sh 单独拉起，死掉时 Main.sh 毫无感知 —— 结果就是 App 上
# 一片空白、按钮全报「WebUI 不可达」，而守护进程看起来还活得好好的。
#
# 这里每轮做一次存活检查，挂了就重拉；带节流，避免 python 缺失时刷屏。
# -----------------------------------------------------
WEBUI_START_SH="$SCRIPT_DIR/webui/webui_start.sh"
WEBUI_PIDF="$IWPHONE_ROOT/webui.pid"
WEBUI_RETRY_EVERY="${WEBUI_RETRY_EVERY:-4}"   # 每 N 轮重试一次（默认 4×15s≈1 分钟）
_webui_miss=$WEBUI_RETRY_EVERY                # 首次检查立即尝试

ensure_webui() {
    [ -f "$WEBUI_START_SH" ] || return 0

    if [ -f "$WEBUI_PIDF" ]; then
        _wp=$(cat "$WEBUI_PIDF" 2>/dev/null)
        if [ -n "$_wp" ] && ps -A -o pid= 2>/dev/null | grep -q "^[[:space:]]*${_wp}[[:space:]]*$"; then
            _webui_miss=0
            return 0
        fi
    fi

    _webui_miss=$((_webui_miss + 1))
    if [ "$_webui_miss" -lt "$WEBUI_RETRY_EVERY" ]; then
        return 0
    fi
    _webui_miss=0
    log "🩺 检测到 WebUI 未运行，尝试拉起"
    sh "$WEBUI_START_SH" >> "$RUN_LOG" 2>&1
}

# ---------------- 入口 ----------------
if already_running; then
    echo "❌ 守护进程已在运行（PID $(cat "$PID_FILE")），请先执行 stop_runner.sh"
    exit 1
fi

echo $$ > "$PID_FILE" || { echo "❌ 无法写入 $PID_FILE"; exit 1; }
trap 'graceful_exit' INT TERM

log "===== Main.sh 守护启动（PID $$） ====="
log "触发目录：$TMP_DIR ｜ 命令区：$SDCARD_DIR ｜ 轮询间隔：${POLL_SEC}s"

# 首次启动：同步一次执行区状态，方便用户立即在 /sdcard 查看
log "首次启动：同步执行区状态"
sync_state

while true; do
    if [ -f "$END_FILE" ]; then
        log "检测到 end 文件"
        graceful_exit
    fi
    consume_commands
    ensure_webui
    sh "$SCRIPT_DIR/iwphone.sh"
    logrotate_tick
    sleep "$POLL_SEC"
done

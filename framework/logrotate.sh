#!/system/bin/sh
# =====================================================
# iwphone modrunner v3 · 日志轮转 / 容量控制
#
# 解决什么问题：
#   框架与模块的日志全部用 `>>` 无限追加，长期运行会吃满存储。
#     - main_stdout.log / webui.log       单文件，无上限、无日期分割
#     - modrunner_YYYYMMDD.log            按天分文件，但旧的那天永远不删
#     - modules/<名>/<名>.{log,out,err}   每个模块一份，无上限
#
# 由 Main.sh 每轮调用 logrotate_tick()，内部按 LOGROTATE_INTERVAL_SEC 节流，
# 所以不会每 POLL_SEC 秒都扫一遍盘。
#
# ★ 为什么是「原地截断」而不是「删除后重建 / mv 覆盖」：
#   写入方（core.sh 的 log()、模块的 stdout 重定向）是以 O_APPEND 持有 fd 的。
#   若删掉文件或用 mv 把新文件换上去，它的 fd 仍指向那个已被 unlink 的旧 inode，
#   之后写的内容会进黑洞 —— 日志看起来「轮转成功」了，实际再也收不到新内容。
#   用 `cat tmp > 原文件` 是就地覆盖同一个 inode，写入方会平滑地从新的 EOF 继续追加。
#   （这一条与 App 端「清空日志」用的是同一个原理。）
# =====================================================

# ---- 内部工具 ----

_lr_log() {
    if command -v log >/dev/null 2>&1; then
        log "$1"
    else
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"
    fi
}

_lr_stamp_file() { echo "${IWPHONE_ROOT}/state/.logrotate_last"; }

# 只保留数字，非数字一律归 0（防环境异常把算术搞崩）
_lr_num() {
    case "$1" in
        ''|*[!0-9]*) echo 0 ;;
        *) echo "$1" ;;
    esac
}

# 超限就截断到尾部保留 N 字节（保持 inode）
_logrotate_truncate() {
    _lr_f="$1"
    [ -f "$_lr_f" ] || return 0

    _lr_sz=$(_lr_num "$(wc -c < "$_lr_f" 2>/dev/null)")
    [ "$_lr_sz" -le "$LOGROTATE_MAX_BYTES" ] && return 0

    _lr_tmp="${_lr_f}.lrtmp.$$"
    if ! tail -c "$LOGROTATE_KEEP_BYTES" "$_lr_f" > "$_lr_tmp" 2>/dev/null; then
        rm -f "$_lr_tmp"
        return 0
    fi
    # 就地覆盖同一个 inode —— 关键，见文件头说明
    cat "$_lr_tmp" > "$_lr_f" 2>/dev/null
    rm -f "$_lr_tmp"

    _lr_new=$(_lr_num "$(wc -c < "$_lr_f" 2>/dev/null)")
    _lr_log "🗜️ 日志轮转：$(basename "$_lr_f") ${_lr_sz} → ${_lr_new} 字节"
}

# 删除超龄的按天框架日志（modrunner_YYYYMMDD.log）
_logrotate_prune_dated() {
    [ "$_lr_keep_days" -gt 0 ] || return 0

    # ★ 用文件 mtime 判年龄，而不是解析文件名里的日期去比大小。
    #   原因：Android 的 toybox date 不认 GNU 的相对表达式
    #   （`date -d "-3 days"` 直接返回空，实测），拿它算截止日会静默失效。
    #   而 `find -mtime +N` 是 toybox 原生支持的，语义恰好是「修改时间超过 N 天」，
    #   且不依赖文件名格式 —— 今天正在写的那个文件 mtime 是新的，天然不会被误删。
    for _lr_f in "$LOG_ROOT_DIR"/modrunner_*.log; do
        [ -f "$_lr_f" ] || continue
        _lr_hit=$(find "$_lr_f" -maxdepth 0 -mtime +"$_lr_keep_days" 2>/dev/null)
        [ -n "$_lr_hit" ] || continue
        rm -f "$_lr_f"
        _lr_log "🗑️ 日志轮转：删除过期框架日志 $(basename "$_lr_f")（超 ${_lr_keep_days} 天）"
    done
}

# 清理「模块已不存在」的日志目录（默认关闭，见 env.sh 说明）
_logrotate_prune_orphans() {
    [ "$_lr_orphan_days" -gt 0 ] || return 0
    _lr_mdir="$LOG_ROOT_DIR/modules"
    [ -d "$_lr_mdir" ] || return 0

    for _lr_d in "$_lr_mdir"/*; do
        [ -d "$_lr_d" ] || continue
        _lr_name=$(basename "$_lr_d")
        # 模块还装在 work/ 里 → 免责跳过
        [ -d "$WORK_DIR/$_lr_name" ] && continue
        # 未超龄 → 跳过（避免误删刚卸载、可能马上重装的模块日志）
        _lr_hit=$(find "$_lr_d" -maxdepth 0 -mtime +"$_lr_orphan_days" 2>/dev/null)
        [ -n "$_lr_hit" ] || continue
        rm -rf "$_lr_d"
        _lr_log "🗑️ 日志轮转：清理孤儿日志目录 $_lr_name（模块已不存在且超 ${_lr_orphan_days} 天）"
    done
}

# ---- 入口：供 Main.sh 每轮调用 ----
logrotate_tick() {
    [ "$(_lr_num "$LOGROTATE_ENABLE")" -eq 1 ] || return 0

    _lr_interval=$(_lr_num "$LOGROTATE_INTERVAL_SEC")
    [ "$_lr_interval" -gt 0 ] || return 0

    # ---- 节流：距上次执行不足间隔就直接返回 ----
    _lr_now=$(_lr_num "$(date +%s 2>/dev/null)")
    _lr_stamp=$(_lr_stamp_file)
    if [ "$_lr_now" -gt 0 ] && [ -f "$_lr_stamp" ]; then
        _lr_last=$(_lr_num "$(cat "$_lr_stamp" 2>/dev/null)")
        [ $(( _lr_now - _lr_last )) -lt "$_lr_interval" ] && return 0
    fi
    mkdir -p "${IWPHONE_ROOT}/state" 2>/dev/null
    [ "$_lr_now" -gt 0 ] && echo "$_lr_now" > "$_lr_stamp" 2>/dev/null

    # 这些量在节流之后才读，保证每次真正执行时都是最新配置
    _lr_keep_days=$(_lr_num "$LOGROTATE_KEEP_DAYS")
    _lr_orphan_days=$(_lr_num "$LOGROTATE_ORPHAN_DAYS")

    # ---- 1) 单文件容量上限 ----
    _logrotate_truncate "$LOG_ROOT_DIR/main_stdout.log"
    _logrotate_truncate "$LOG_ROOT_DIR/webui.log"

    for _lr_f in "$LOG_ROOT_DIR"/modrunner_*.log; do
        [ -f "$_lr_f" ] || continue
        _logrotate_truncate "$_lr_f"
    done

    if [ -d "$LOG_ROOT_DIR/modules" ]; then
        for _lr_md in "$LOG_ROOT_DIR/modules"/*; do
            [ -d "$_lr_md" ] || continue
            for _lr_f in "$_lr_md"/*.log "$_lr_md"/*.out "$_lr_md"/*.err; do
                [ -f "$_lr_f" ] || continue
                _logrotate_truncate "$_lr_f"
            done
        done
    fi

    # ---- 2) 按天日志的年龄上限 ----
    _logrotate_prune_dated

    # ---- 3) 孤儿日志目录（默认关闭） ----
    _logrotate_prune_orphans
}

#!/system/bin/sh
# =====================================================
# iwphone modrunner v3 · 单轮运行器（iwphone.sh）
#
# 扫描触发目录，执行所有被触发的模块后退出。
# 平时由 Main.sh 守护进程周期性调用，也可独立手动执行：
#   sh iwphone.sh        扫描并执行一轮
#
# 触发模块：touch <TMP_DIR>/<模块名>（TMP_DIR 见 env.sh）
# =====================================================
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
. "$SCRIPT_DIR/env.sh"
. "$SCRIPT_DIR/core.sh"
. "$SCRIPT_DIR/conflict.sh"

# 单轮执行防并发锁（Main.sh 调用与手动调用互斥，防止扫描重叠）
SCAN_LOCK="${IWPHONE_ROOT}/runner_once.lock"
if ! mkdir "$SCAN_LOCK" 2>/dev/null; then
    log "⏭️ 已有扫描任务进行中，跳过本轮"
    exit 0
fi
trap 'rm -rf "$SCAN_LOCK"' EXIT

log "===== iwphone 单轮扫描开始 ====="

for _trigger in "$TMP_DIR"/*; do
    [ -f "$_trigger" ] || continue
    _module=$(basename "$_trigger")

    # 模块名校验
    if ! validate_module "$_module"; then
        [ "$AUTO_CLEAN" -eq 1 ] && rm -f "$_trigger"
        continue
    fi

    # 并行数限制（按活跃锁数量估算）
    if [ "$MAX_PARALLEL" -gt 0 ]; then
        _active=$(ls "$LOCK_DIR" 2>/dev/null | wc -l)
        if [ "$_active" -ge "$MAX_PARALLEL" ]; then
            log "⏭️ 已达最大并行数 $MAX_PARALLEL，跳过 $_module"
            continue    # 不清触发文件，下一轮再试
        fi
    fi

    # 重复执行校验
    if is_locked "$_module"; then
        log "⏭️ 模块 $_module 运行中，跳过"
        [ "$AUTO_CLEAN" -eq 1 ] && rm -f "$_trigger"
        continue
    fi

    # 模块必须已安装
    if [ ! -f "${WORK_DIR}/${_module}/main.sh" ]; then
        log "❌ 模块未安装：$_module（缺少 ${WORK_DIR}/${_module}/main.sh）"
        [ "$AUTO_CLEAN" -eq 1 ] && rm -f "$_trigger"
        continue
    fi

    # 高危命令拦截
    if ! check_blacklist "${WORK_DIR}/${_module}/main.sh"; then
        log "❌ 模块 $_module 含高危命令，拒绝执行"
        module_log "$_module" "❌ 触发被拒绝：main.sh 命中黑名单"
        [ "$AUTO_CLEAN" -eq 1 ] && rm -f "$_trigger"
        continue
    fi

    # 资源冲突检查（exclusive 声明 vs 已运行模块）
    if ! check_conflict "$_module"; then
        [ "$AUTO_CLEAN" -eq 1 ] && rm -f "$_trigger"
        continue
    fi

    log "▶️ 启动模块：$_module"
    start_module "$_module"
    [ "$AUTO_CLEAN" -eq 1 ] && rm -f "$_trigger"
done

# 一轮扫描结束后做冲突审计（记账比对 + 值快照）
conflict_audit

log "===== 单轮扫描完成 ====="
exit 0

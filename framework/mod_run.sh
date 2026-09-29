#!/system/bin/sh
# =====================================================
# 单模块直启（不经过守护轮询；App / 手动入口）
# 用法：sh mod_run.sh <模块名>
# =====================================================
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
. "$SCRIPT_DIR/env.sh"
. "$SCRIPT_DIR/core.sh"
. "$SCRIPT_DIR/conflict.sh"

MODULE_ID="$1"
if [ -z "$MODULE_ID" ]; then
    echo "用法：sh $0 <模块名>   （模块位于 ${WORK_DIR}/<模块名>/）"
    exit 1
fi

validate_module "$MODULE_ID" || exit 1

if [ ! -f "${WORK_DIR}/${MODULE_ID}/main.sh" ]; then
    echo "❌ 模块不存在：${WORK_DIR}/${MODULE_ID}/main.sh"
    echo "   可先用 mod_install.sh 安装 .iwp 模块包"
    exit 1
fi

if is_locked "$MODULE_ID"; then
    echo "❌ 模块 $MODULE_ID 正在运行，请勿重复执行"
    exit 1
fi

if ! check_blacklist "${WORK_DIR}/${MODULE_ID}/main.sh"; then
    echo "❌ 模块 $MODULE_ID 包含高危禁止命令，拒绝执行"
    module_log "$MODULE_ID" "❌ 触发被拒绝：main.sh 命中黑名单"
    exit 1
fi

if ! check_conflict "$MODULE_ID"; then
    echo "❌ 模块 $MODULE_ID 因资源冲突被拒绝启动，详见："
    echo "   ${CONFLICT_LOG}"
    echo "   （如确需启动，请先停止占用该资源的模块）"
    exit 1
fi

start_module "$MODULE_ID"
echo "✅ 模块 $MODULE_ID 已启动"
echo "   日志目录：${LOG_ROOT_DIR}/modules/${MODULE_ID}/"
exit 0

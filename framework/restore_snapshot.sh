#!/system/bin/sh
# =====================================================
# 还原模块快照：把系统资源恢复到该模块首次写入之前的原值
# 用法：sh restore_snapshot.sh <模块名>
#
# 快照由沙箱在模块「首次写某资源」时自动记录（见 sandbox.sh 的
# _sb_snap_maybe），每行就是一条可直接执行的还原命令，
# 行尾带 [资源名] 注释用于去重。
#
# 还原成功后快照归档为 .done.<时间戳> —— 防止二次误还原
# （二次还原会把模块改过的值当作"原值"写回去）。模块重新启动会生成新快照。
#
# 实现上刻意避开 `VAR=$(...)` + heredoc 的组合：mksh 下那套会把
# 命令替换的结果当命令重新解析执行（踩过这个坑），
# 直接 `while read < 文件` 最稳。
# =====================================================
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
. "$SCRIPT_DIR/env.sh"

MOD="$1"
if [ -z "$MOD" ]; then
    echo "用法：sh $0 <模块名>"
    exit 1
fi
case "$MOD" in
    *..*|*/*) echo "❌ 非法模块名：$MOD"; exit 1 ;;
esac
case "$MOD" in
    *[[:space:]]*) echo "❌ 模块名含空白字符：$MOD"; exit 1 ;;
esac

SNAP="$SNAPSHOT_DIR/$MOD.snap"
if [ ! -f "$SNAP" ]; then
    echo "⚠️ 模块 $MOD 没有快照可还原（快照在模块首次写系统资源时自动生成）"
    exit 1
fi

ok=0
fail=0
while IFS= read -r _line; do
    # 跳过空行与整行注释
    case "$_line" in
        ''|'#'*) continue ;;
    esac
    if sh -c "$_line" >/dev/null 2>&1; then
        ok=$((ok + 1))
    else
        fail=$((fail + 1))
        echo "⚠️ 还原失败：$_line"
    fi
done < "$SNAP"

if [ "$ok" -eq 0 ] && [ "$fail" -eq 0 ]; then
    echo "⚠️ 快照里没有可还原的条目"
    exit 1
fi

echo "✅ 已还原 $ok 项（失败 $fail 项）"

# 归档：避免同一份快照被二次还原
mv "$SNAP" "$SNAP.done.$(date +%s)" 2>/dev/null
echo "   快照已归档。模块重新启动后会生成新快照。"
exit 0

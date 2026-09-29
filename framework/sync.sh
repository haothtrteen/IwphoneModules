#!/system/bin/sh
# =====================================================
# 目录同步工具（内容级 MD5 对比，双向一致）
# 用法：sh sync.sh <源目录> <目标目录>
# 作用：新增/修改 → 复制；源中已删除 → 目标同步删除
# 典型用途：把执行区 /data/local/tmp/iwphone 镜像到
#           /sdcard/iwphone 供用户直接查看
# =====================================================

A_DIR="$1"   # 源目录
B_DIR="$2"   # 目标目录

TMP_PREFIX=".sync_tmp_"

cleanup() {
    rm -f "${A_DIR}/${TMP_PREFIX}"* 2>/dev/null
    rm -f "${B_DIR}/${TMP_PREFIX}"* 2>/dev/null
}
trap cleanup EXIT

# 生成目录文件的 MD5 列表（相对路径|MD5）
# 注意：不使用 find -print0 / read -d ''（bash 专属），保证 POSIX 兼容
generate_md5() {
    _base="$1"
    find "$_base" -type f 2>/dev/null | while IFS= read -r file; do
        _rel="${file#$_base}"
        _md5=$(md5sum "$file" 2>/dev/null | awk '{print $1}')
        printf "%s|%s\n" "$_rel" "$_md5"
    done
}

main() {
    [ ! -d "$A_DIR" ] && echo "错误：源目录不存在：$A_DIR" && exit 1
    [ ! -d "$B_DIR" ] && echo "错误：目标目录不存在：$B_DIR" && exit 1

    echo "===== 开始同步（$A_DIR → $B_DIR） ====="

    a_md5=$(generate_md5 "$A_DIR")
    b_md5=$(generate_md5 "$B_DIR")

    a_md5_tmp=$(mktemp -p "$A_DIR" "${TMP_PREFIX}a_md5.XXXXXX")
    echo "$a_md5" > "$a_md5_tmp"

    # 新增 / 修改
    printf '%s\n' "$a_md5" | while IFS='|' read -r a_rel a_md5; do
        [ -z "$a_rel" ] && continue
        a_file="${A_DIR}${a_rel}"
        b_file="${B_DIR}${a_rel}"
        if [ ! -f "$b_file" ]; then
            echo "新增：$b_file"
            mkdir -p "$(dirname "$b_file")" && cp -af "$a_file" "$b_file"
        else
            b_current_md5=$(printf '%s\n' "$b_md5" | grep -m1 "^${a_rel}|" | cut -d '|' -f 2)
            if [ "$a_md5" != "$b_current_md5" ]; then
                echo "修改：$b_file"
                mkdir -p "$(dirname "$b_file")" && cp -af "$a_file" "$b_file"
            fi
        fi
    done

    # 删除目标中的冗余文件
    printf '%s\n' "$b_md5" | while IFS='|' read -r b_rel b_md5; do
        [ -z "$b_rel" ] && continue
        if ! grep -q "^${b_rel}|" "$a_md5_tmp"; then
            b_file="${B_DIR}${b_rel}"
            echo "删除：$b_file（源中已不存在）"
            rm -f "$b_file"
        fi
    done

    rm -f "$a_md5_tmp"
    echo "===== 同步完成 ====="
}

main

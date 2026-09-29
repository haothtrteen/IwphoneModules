#!/usr/bin/env sh
# =====================================================
# 把 framework/ 打包成 App 内置资产 assets/framework.bin
#
# 为什么扩展名是 .bin 而不是 .tar.gz：
#   AAPT 打包资产时会**解压 .gz 并去掉后缀**（实测得到 assets/framework.tar，
#   35MB 未压缩），导致 App 里 assets.open("framework.tar.gz") 找不到文件。
#   换一个 AAPT 不特殊处理后缀的名字即可（.bin），内容仍是 tar.gz。
#
# 包内结构（App 侧 deployFramework 解压到 /data/local/tmp 即完成部署）：
#   iwphone_modrunner_v3_slim/iwphone_modrunner_v3/…
#
# 前置条件：webui/runtime/ 必须存在（内置 Python 运行时，约 36MB，**不入仓库**）
#   生成：sh tools/build_runtime.sh --arch aarch64
#   或从已部署的设备拉一份：
#     adb pull /data/local/tmp/iwphone_modrunner_v3_slim/iwphone_modrunner_v3/webui/runtime webui/runtime
#
# 用法：
#   sh tools/build_framework_bin.sh
#   sh tools/build_framework_bin.sh --out /tmp/framework.bin
# =====================================================
set -u

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
FRAME_DIR=$(dirname "$SCRIPT_DIR")            # framework/
REPO_ROOT=$(dirname "$FRAME_DIR")             # 仓库根（App 在根目录）
OUT="$REPO_ROOT/android/app/src/main/assets/framework.bin"
ARCH_HINT="aarch64"

while [ $# -gt 0 ]; do
    case "$1" in
        --out)   OUT="$2"; shift 2 ;;
        --arch)  ARCH_HINT="$2"; shift 2 ;;
        -h|--help) sed -n '2,22p' "$0"; exit 0 ;;
        *) echo "未知参数：$1（--out / --arch / --help）"; exit 1 ;;
    esac
done

if [ ! -d "$FRAME_DIR/webui/runtime" ]; then
    echo "❌ 缺少 framework/webui/runtime/（内置 Python 运行时，约 36MB）"
    echo "   二选一："
    echo "     1) sh \"$SCRIPT_DIR/build_runtime.sh\" --arch $ARCH_HINT"
    echo "     2) adb pull /data/local/tmp/iwphone_modrunner_v3_slim/iwphone_modrunner_v3/webui/runtime \\"
    echo "                \"$FRAME_DIR/webui/runtime\""
    exit 1
fi

PY_BIN="$FRAME_DIR/webui/runtime/bin/python3.12"
if [ ! -x "$PY_BIN" ]; then
    echo "⚠️  运行时里没有可执行的 bin/python3.12 —— 部署后 WebUI 起不来，请确认运行时完整"
fi

TMP=$(mktemp -d 2>/dev/null || mktemp -d -t fwbuild)
trap 'rm -rf "$TMP"' EXIT

PKG="$TMP/iwphone_modrunner_v3_slim"
mkdir -p "$PKG"
cp -r "$FRAME_DIR" "$PKG/iwphone_modrunner_v3" || { echo "❌ 复制框架目录失败"; exit 1; }

# 清掉不该进包的东西
rm -rf "$PKG/iwphone_modrunner_v3/webui/__pycache__" 2>/dev/null
find "$PKG" -name '*.bak*' -delete 2>/dev/null
find "$PKG" -name '*.pyc'  -delete 2>/dev/null

mkdir -p "$(dirname "$OUT")"
( cd "$TMP" && tar czf "$OUT" iwphone_modrunner_v3_slim ) || { echo "❌ 打包失败"; exit 1; }

SIZE=$(wc -c < "$OUT" | tr -d ' ')
echo "✅ 已生成：$OUT"
echo "   大小：$((SIZE / 1024 / 1024)) MB"
echo "   下一步：flutter build apk --release"

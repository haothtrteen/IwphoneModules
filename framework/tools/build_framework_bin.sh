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
#   iwphone/…
#   解压后就是 /data/local/tmp/iwphone/ —— 代码、webui、runtime、模块包全都
#   在这一个目录里，和运行时产生的 work/ state/ tmp/ 等同级。全项目只有这一个路径。
#
# 前置条件：webui/runtime/ 必须存在（内置 Python 运行时，约 36MB，**不入仓库**）
#   生成：sh tools/build_runtime.sh --arch aarch64
#   或从已部署的设备拉一份：
#     adb pull /data/local/tmp/iwphone/webui/runtime webui/runtime
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
    echo "     2) adb pull /data/local/tmp/iwphone/webui/runtime \\"
    echo "                \"$FRAME_DIR/webui/runtime\""
    exit 1
fi

PY_BIN="$FRAME_DIR/webui/runtime/bin/python3.12"
if [ ! -f "$PY_BIN" ]; then
    echo "⚠️  运行时里没有 bin/python3.12 —— 部署后 WebUI 起不来，请确认运行时完整"
elif [ ! -x "$PY_BIN" ]; then
    # Windows / NTFS 没有执行位，这里必然会命中，属正常现象：
    # App 侧 deployFramework 解压后会 `chmod -R 777`，权限在设备上补齐。
    # 但**部署命令的顺序必须是「先 chmod 再跑 busybox」**，否则
    # ./busybox --list 会 Permission denied，applet 链接一个都建不出来。
    echo "ℹ️  本机没有执行位（Windows 正常现象）—— App 部署时会 chmod 补齐权限"
fi

TMP=$(mktemp -d 2>/dev/null || mktemp -d -t fwbuild)
trap 'rm -rf "$TMP"' EXIT

# ★ 包内根目录就叫 iwphone：App 解压到 /data/local/tmp 后直接得到
#   /data/local/tmp/iwphone/，代码与运行时状态同处一个目录。
#   不再有 iwphone_modrunner_v3_slim/iwphone_modrunner_v3 这层嵌套 ——
#   那层嵌套导致「手动部署过框架」和「App 认为没部署」两套路径并存，
#   升级 App 就会各种对不上。
PKG="$TMP/iwphone"
cp -r "$FRAME_DIR" "$PKG" || { echo "❌ 复制框架目录失败"; exit 1; }

# 清掉不该进包的东西
rm -rf "$PKG/webui/__pycache__" 2>/dev/null
find "$PKG" -name '*.bak*' -delete 2>/dev/null
find "$PKG" -name '*.pyc'  -delete 2>/dev/null

mkdir -p "$(dirname "$OUT")"
( cd "$TMP" && tar czf "$OUT" iwphone ) || { echo "❌ 打包失败"; exit 1; }

SIZE=$(wc -c < "$OUT" | tr -d ' ')
echo "✅ 已生成：$OUT"
echo "   大小：$((SIZE / 1024 / 1024)) MB"
echo "   下一步：flutter build apk --release"

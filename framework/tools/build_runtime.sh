#!/usr/bin/env sh
# =====================================================
# 构建 WebUI 内置 Python 运行时（静态 musl CPython）
#
# 为什么需要本脚本：
#   Android shell 没有 zstd，无法在设备端自行解压上游发布包，
#   因此运行时需在「有工具链的一侧」（Linux / macOS / Termux）生成后拷入。
#
# 用法：
#   sh tools/build_runtime.sh                    # 依本机架构生成到 webui/runtime
#   sh tools/build_runtime.sh --arch aarch64     # 指定目标架构（交叉生成，给手机用）
#   sh tools/build_runtime.sh --variant lto      # 用 LTO 优化版（运行更快，下载更大）
#   sh tools/build_runtime.sh --out /tmp/rt      # 指定输出目录
#   sh tools/build_runtime.sh --push             # 生成后 adb push 到设备
#
# 依赖：curl 或 wget、zstd、tar（strip 可选，缺失则跳过瘦身）
# =====================================================
set -u

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
FRAME_DIR=$(dirname "$SCRIPT_DIR")
OUTDIR="$FRAME_DIR/webui/runtime"
ARCH=""
VARIANT="${PY_BUILD_VARIANT:-lto}"         # lto(推荐,77MB) | noopt(更小,34MB) | debug
TAG="${PY_BUILD_TAG:-20260901}"
VERSION="${PY_BUILD_VERSION:-3.12.14}"
PUSH=0

while [ $# -gt 0 ]; do
    case "$1" in
        --arch)    ARCH="$2"; shift 2 ;;
        --variant) VARIANT="$2"; shift 2 ;;
        --out)     OUTDIR="$2"; shift 2 ;;
        --tag)     TAG="$2"; shift 2 ;;
        --version) VERSION="$2"; shift 2 ;;
        --push)    PUSH=1; shift ;;
        -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
        *) echo "未知参数：$1"; exit 1 ;;
    esac
done

# 未指定架构时用本机架构
[ -n "$ARCH" ] || ARCH=$(uname -m)

case "$ARCH" in
    aarch64|arm64|arm64-v8a) TRIPLE="aarch64-unknown-linux-musl"; STRIP_BIN="aarch64-linux-gnu-strip" ;;
    x86_64|amd64)            TRIPLE="x86_64-unknown-linux-musl";  STRIP_BIN="strip" ;;
    armv7l|armv8l|arm|armhf)
        echo "❌ 32 位 ARM 无 musl 静态构建（上游未提供）"
        echo "   请在设备上改用系统 Python：Termux 执行 pkg install python"
        exit 1 ;;
    *) echo "❌ 不支持的架构：$ARCH"; exit 1 ;;
esac

ASSET="cpython-${VERSION}+${TAG}-${TRIPLE}-${VARIANT}+static-full.tar.zst"

# 多个镜像源依次尝试（GitHub 直连在国内常不可达）
MIRRORS="
https://mirror4.lzu.edu.cn/github-release/astral-sh/python-build-standalone/LatestRelease/${ASSET}
https://cnb.cool/astral-sh/python-build-standalone/-/releases/download/${TAG}/${ASSET}
https://ghfast.top/https://github.com/astral-sh/python-build-standalone/releases/download/${TAG}/${ASSET}
https://github.com/astral-sh/python-build-standalone/releases/download/${TAG}/${ASSET}
"

TMPD=$(mktemp -d "${TMPDIR:-/tmp}/pyruntime.XXXXXX")
trap 'rm -rf "$TMPD"' EXIT

echo "==> 目标：Python ${VERSION} (${TRIPLE}, ${VARIANT}+static)"

# ---------- 下载 ----------
DL="$TMPD/${ASSET}"
for base in $MIRRORS; do
    printf '    尝试 %s ... ' "$(echo "$base" | awk -F/ '{print $3}')"
    if command -v curl >/dev/null 2>&1; then
        curl -fL --max-time 600 -o "$DL" "$base" 2>/dev/null && OK=1 || OK=0
    else
        wget -q --timeout=60 -O "$DL" "$base" 2>/dev/null && OK=1 || OK=0
    fi
    if [ "$OK" = 1 ] && [ -f "$DL" ] && [ "$(wc -c < "$DL")" -gt 1048576 ]; then
        echo "OK ($(( $(wc -c < "$DL") / 1048576 )) MB)"
        break
    fi
    echo "失败"
    OK=0
done

[ "$OK" = 1 ] || { echo "❌ 所有镜像源下载失败，请检查网络或手动下载："; echo "   $ASSET"; exit 1; }

# ---------- 解包（只要 install 树，跳过 build 中间产物）----------
echo "==> 解包 python/install ..."
mkdir -p "$TMPD/x"
zstd -d --stdout "$DL" | tar xf - -C "$TMPD/x" python/install \
    || { echo "❌ 解包失败（需要 GNU/BSD tar 与 zstd）"; exit 1; }

SRC="$TMPD/x/python/install"
[ -d "$SRC" ] || { echo "❌ 归档结构异常：未找到 python/install"; exit 1; }

# ---------- 瘦身 ----------
echo "==> 瘦身：strip + 移除非必需组件"
if command -v "$STRIP_BIN" >/dev/null 2>&1; then
    "$STRIP_BIN" --strip-all "$SRC/bin/python${VERSION%.*}" 2>/dev/null
elif command -v llvm-strip >/dev/null 2>&1; then
    llvm-strip --strip-all "$SRC/bin/python${VERSION%.*}" 2>/dev/null
else
    echo "    (无可用 strip，跳过二进制瘦身)"
fi

PYLIB="$SRC/lib/python${VERSION%.*}"
rm -rf \
    "$SRC/include" "$SRC/share" \
    "$SRC/bin/2to3"* "$SRC/bin/idle3"* \
    "$SRC/bin/pip"* "$SRC/bin/pydoc3"* \
    "$SRC/bin/python3-config" "$SRC/bin/python${VERSION%.*}-config" \
    "$PYLIB"/config-* \
    "$PYLIB/test" "$PYLIB/idlelib" "$PYLIB/ensurepip" "$PYLIB/tkinter" \
    "$PYLIB/lib2to3" "$PYLIB/turtledemo" "$PYLIB/pydoc_data" \
    "$PYLIB/site-packages" \
    "$SRC/lib/libpython${VERSION%.*}.a" \
    "$SRC/lib/tcl"* "$SRC/lib/tk"* "$SRC/lib/itcl"* "$SRC/lib/thread"* "$SRC/lib/pkgconfig" 2>/dev/null

# ---------- 落地 ----------
rm -rf "$OUTDIR"
mkdir -p "$OUTDIR"
cp -a "$SRC/bin" "$SRC/lib" "$OUTDIR/" 2>/dev/null
chmod 755 "$OUTDIR/bin/python${VERSION%.*}" 2>/dev/null

cat > "$OUTDIR/RUNTIME.txt" <<EOF
内置 Python 运行时
  版本：    CPython ${VERSION} (${VARIANT}+static)
  目标：    ${TRIPLE}
  来源：    python-build-standalone ${TAG}
  上游：    https://github.com/astral-sh/python-build-standalone
  说明：    完全静态链接，不依赖系统 libc；已移除 test/idlelib/pip/tk 等非必需组件
EOF

echo "==> 运行时已生成：$OUTDIR"
du -sh "$OUTDIR" 2>/dev/null

# ---------- 可选：推送到设备 ----------
if [ "$PUSH" = 1 ]; then
    if ! command -v adb >/dev/null 2>&1; then
        echo "⚠️  未找到 adb，跳过推送"
    else
        DEV_DIR="${DEVICE_DIR:-/data/local/tmp/iwphone}"
        echo "==> 推送到设备 $DEV_DIR/webui/runtime ..."
        adb shell "mkdir -p $DEV_DIR/webui" 
        adb push "$OUTDIR" "$DEV_DIR/webui/runtime" && \
        adb shell "chmod 755 $DEV_DIR/webui/runtime/bin/python${VERSION%.*}"
    fi
fi

echo "✅ 完成。启动 WebUI：sh webui/webui_start.sh"
exit 0

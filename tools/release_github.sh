#!/usr/bin/env bash
# =====================================================
# 一键发布：构建 release APK → 建 GitHub Release → 上传 APK
#
# 为什么写这个脚本：gh CLI 没装，而且本机有 TLS 中间人代理，
# 裸 curl 访问 GitHub 容易踩证书/代理坑。这里把代理探测、鉴权、
# 建 release、传资产全部收进一条命令，避免每次手工拼 API。
#
# 用法：
#   export GITHUB_TOKEN=github_pat_xxx     # 需 Contents 读写权限
#   bash tools/release_github.sh v1.2.3
#
# 可选参数：
#   --prerelease            标记为预发布
#   --notes <文件>          指定 release 说明（默认用 docs/RELEASE_NOTES.md）
#   --skip-build            跳过构建，用现有 APK（不推荐）
#   --dry-run               只构建 + 打印将要做的事，不碰 GitHub
#
# 依赖：flutter（能跑）、curl
# =====================================================
set -euo pipefail

REPO="haothtrteen/IwphoneModules"
REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
DIST_DIR="$REPO_DIR/dist"
APK_OUT="$REPO_DIR/build/app/outputs/flutter-apk/app-release.apk"
NOTES_FILE="$REPO_DIR/docs/RELEASE_NOTES.md"

TAG=""
PRERELEASE=0
SKIP_BUILD=0
DRY_RUN=0

while [ $# -gt 0 ]; do
    case "$1" in
        --prerelease) PRERELEASE=1; shift ;;
        --skip-build) SKIP_BUILD=1; shift ;;
        --dry-run)    DRY_RUN=1; shift ;;
        --notes)      NOTES_FILE="$2"; shift 2 ;;
        -h|--help)    sed -n '2,20p' "$0"; exit 0 ;;
        -*)           echo "未知参数：$1"; exit 1 ;;
        *)            TAG="$1"; shift ;;
    esac
done

if [ -z "$TAG" ]; then
    echo "用法：bash tools/release_github.sh v1.2.3 [--prerelease] [--dry-run]"
    exit 1
fi

# ---------- 0) 代理 + TLS（本机是 TLS 中间人环境，必须显式传给 curl）----------
PROXY="${https_proxy:-${HTTPS_PROXY:-}}"
CURL_PROXY=()
if [ -n "$PROXY" ]; then
    CURL_PROXY=(--proxy "$PROXY")
    echo "ℹ️  使用代理：$PROXY"
fi

# Windows 的 schannel 后端会强制查证书吊销链，而中间人代理签发的证书查不到，
# 直接报 CRYPT_E_NO_REVOCATION_CHECK（curl error 35）。必须显式关掉。
# 其它平台（Linux/macOS 的 OpenSSL/SecureTransport）没有这个选项，所以先探测。
CURL_TLS=()
if curl --help all 2>/dev/null | grep -q -- '--ssl-no-revoke'; then
    CURL_TLS=(--ssl-no-revoke)
fi

# ---------- 1) 构建 ----------
if [ "$SKIP_BUILD" -eq 0 ]; then
    echo "🔨 构建 release APK…"
    if ! command -v flutter >/dev/null 2>&1; then
        FLUTTER_BIN="${FLUTTER_BIN:-}"
        if [ -z "$FLUTTER_BIN" ]; then
            echo "❌ 找不到 flutter。请把它加进 PATH，或设置 FLUTTER_BIN 指向 flutter 可执行文件。"
            exit 1
        fi
    else
        FLUTTER_BIN="flutter"
    fi

    # 先自检：工具链起不来就别浪费时间（本机曾因系统管道耗尽管不动，报 error 231）
    if ! "$FLUTTER_BIN" --no-version-check --version >/dev/null 2>&1; then
        echo "❌ flutter 工具链不可用（--version 就失败）。"
        echo "   本机曾出现 CreateFile failed 231（系统命名管道耗尽），重启 WorkBuddy 或系统后重试。"
        exit 1
    fi

    ( cd "$REPO_DIR" && "$FLUTTER_BIN" --no-version-check build apk --release )
else
    echo "ℹ️  跳过构建，使用现有 APK"
fi

if [ ! -f "$APK_OUT" ]; then
    echo "❌ 没找到 APK：$APK_OUT"
    exit 1
fi

# ---------- 2) 归档产物（带版本号，便于分发）----------
mkdir -p "$DIST_DIR"
ASSET="$DIST_DIR/ShellManager-$TAG.apk"
cp -f "$APK_OUT" "$ASSET"
SIZE_MB=$(( $(wc -c < "$ASSET") / 1024 / 1024 ))
echo "📦 产物：$ASSET（${SIZE_MB} MB）"

# ---------- 3) 校验签名（未签名 / debug 签名的包不该发）----------
# 注意 ${ANDROID_HOME:-}：脚本开了 set -u，直接引用未定义的 ANDROID_HOME 会中断。
APKSIGNER=$(ls -d "${ANDROID_HOME:-/nonexistent}"/build-tools/*/apksigner* 2>/dev/null | tail -1 || true)
if [ -z "$APKSIGNER" ]; then
    APKSIGNER=$(ls -d "$HOME"/AppData/Local/Android/Sdk/build-tools/*/apksigner* 2>/dev/null | tail -1 || true)
fi
if [ -n "$APKSIGNER" ]; then
    export JAVA_HOME="${JAVA_HOME:-F:/jdk21/jdk-21.0.12.1+1}"
    export PATH="$JAVA_HOME/bin:$PATH"
    echo "🔏 签名校验："
    "$APKSIGNER" verify --print-certs "$ASSET" 2>&1 | grep -E "certificate DN|digest:" | head -2 | sed 's/^/   /'
else
    echo "ℹ️  没找到 apksigner，跳过签名校验（发布前请自行确认）"
fi

if [ "$DRY_RUN" -eq 1 ]; then
    echo "🧪 --dry-run：到此为止，未接触 GitHub。"
    exit 0
fi

# ---------- 4) Token ----------
if [ -z "${GITHUB_TOKEN:-}" ]; then
    printf "🔑 输入 GitHub Token（需 Contents 读写，输入不回显）："
    read -rs GITHUB_TOKEN
    echo ""
fi
if [ -z "$GITHUB_TOKEN" ]; then
    echo "❌ 没有 Token，退出"
    exit 1
fi

API="https://api.github.com/repos/$REPO"
UPLOAD="https://uploads.github.com/repos/$REPO"

api() {  # api <method> <url> [curl 额外参数...]
    local method="$1"; shift
    local url="$1"; shift
    curl -sS "${CURL_TLS[@]}" "${CURL_PROXY[@]}" -X "$method" \
        -H "Authorization: Bearer $GITHUB_TOKEN" \
        -H "Accept: application/vnd.github+json" \
        -H "X-GitHub-Api-Version: 2022-11-28" \
        "$url" "$@"
}

# ---------- 5) 建 release（已存在则复用）----------
NOTES_ARG=()
if [ -f "$NOTES_FILE" ]; then
    NOTES_ARG=(--data-binary @-)
    BODY=$(cat "$NOTES_FILE")
else
    BODY="Shell Manager $TAG"
fi

echo "🚀 创建 release $TAG …"
RELEASE_JSON=$(python - "$TAG" "$PRERELEASE" "$BODY" <<'PY' | api POST "$API/releases" -H "Content-Type: application/json" --data-binary @-
import json, sys
tag, pre, body = sys.argv[1], sys.argv[2] == "1", sys.argv[3]
print(json.dumps({
    "tag_name": tag,
    "name": f"Shell Manager {tag}",
    "body": body,
    "draft": False,
    "prerelease": pre,
}, ensure_ascii=False))
PY
)

RELEASE_ID=$(printf '%s' "$RELEASE_JSON" | python -c "import sys,json;d=json.load(sys.stdin);print(d.get('id',''))" 2>/dev/null || true)
if [ -z "$RELEASE_ID" ]; then
    echo "⚠️  创建 release 返回异常，尝试复用已存在的同名 release…"
    RELEASE_JSON=$(api GET "$API/releases/tags/$TAG")
    RELEASE_ID=$(printf '%s' "$RELEASE_JSON" | python -c "import sys,json;d=json.load(sys.stdin);print(d.get('id',''))" 2>/dev/null || true)
fi
if [ -z "$RELEASE_ID" ]; then
    echo "❌ 拿不到 release id，原始返回："
    printf '%s\n' "$RELEASE_JSON" | head -20
    exit 1
fi
echo "   release id = $RELEASE_ID"

# ---------- 6) 上传 APK 资产 ----------
ASSET_NAME=$(basename "$ASSET")
echo "⬆️  上传 APK：$ASSET_NAME（${SIZE_MB} MB，大文件请耐心）…"
api POST "$UPLOAD/releases/$RELEASE_ID/assets?name=$ASSET_NAME" \
    -H "Content-Type: application/vnd.android.package-archive" \
    --data-binary "@$ASSET" \
    | python -c "import sys,json;d=json.load(sys.stdin);print('   ✅ 已上传：', d.get('browser_download_url') or d)" 2>/dev/null \
    || { echo "⚠️  上传返回异常，请到网页确认"; }

echo ""
echo "🎉 完成：https://github.com/$REPO/releases/tag/$TAG"

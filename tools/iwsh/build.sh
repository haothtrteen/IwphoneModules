#!/usr/bin/env bash
# 重新编译 iwsh.dex 到 App assets。
# 依赖：JDK 8+（javac）、Android SDK build-tools（d8）、android.jar（platforms/android-34）
# 用法： JAVA_HOME=/path/to/jdk bash tools/iwsh/build.sh
set -e
cd "$(dirname "$0")/../.."

AJAR="${ANDROID_JAR:-/c/Users/admin/AppData/Local/Android/Sdk/platforms/android-34/android.jar}"
D8="${D8_BIN:-/c/Users/admin/AppData/Local/Android/Sdk/build-tools/34.0.0/d8.bat}"
JAVAC="${JAVA_HOME:?请设置 JAVA_HOME}/bin/javac"

mkdir -p tools/iwsh/classes tools/iwsh/out
"$JAVAC" -source 8 -target 8 -d tools/iwsh/classes \
  tools/iwsh/src/com/shellmgr/shell/ShellLoader.java 2>/dev/null
"$D8" --lib "$AJAR" --min-api 24 --output tools/iwsh/out \
  tools/iwsh/classes/com/shellmgr/shell/ShellLoader.class
cp tools/iwsh/out/classes.dex android/app/src/main/assets/iwsh.dex
echo "已生成 android/app/src/main/assets/iwsh.dex"

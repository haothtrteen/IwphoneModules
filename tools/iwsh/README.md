# iwsh dex 构建源

`src/com/shellmgr/shell/ShellLoader.java` 是 iwsh 式终端客户端的源码，
编译产物 `../../android/app/src/main/assets/iwsh.dex` 会随 APK 打包，
由 App 的「接入说明 → 导出工具包」连同 `iwsh.sh` 一起导出。

改完 Java 后运行 `bash tools/iwsh/build.sh` 重新生成 dex（需 JDK 与 Android SDK d8）。

`Probe.java` / `classes*` / `dex*` / `probe.b64` 是 2026-11-06 真机诊断
（`ActivityThread.systemMain()` 在 MIUI 崩溃）留下的临时文件，不参与构建、不入库。

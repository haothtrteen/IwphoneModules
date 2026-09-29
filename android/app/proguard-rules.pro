# Flutter 引擎与嵌入层（缺失会导致 release 包启动即崩溃）
-keep class io.flutter.app.** { *; }
-keep class io.flutter.plugin.** { *; }
-keep class io.flutter.util.** { *; }
-keep class io.flutter.view.** { *; }
-keep class io.flutter.** { *; }
-keep class io.flutter.plugins.** { *; }
-keep class io.flutter.embedding.** { *; }

# AndroidX 生命周期（FlutterActivity 依赖）
-keep class androidx.lifecycle.** { *; }

# 应用自身代码（从 AndroidManifest 反射创建，必须保留）
-keep class com.shellmgr.shell_manager.** { *; }

# 保留行号以便排查线上堆栈
-keepattributes SourceFile,LineNumberTable
-renamesourcefileattribute SourceFile

# Flutter 延迟加载组件（deferred components）会引用 Play Core，
# 本项目未使用该特性，且未引入 play:core 依赖，故忽略此类缺失警告。
-dontwarn com.google.android.play.core.**

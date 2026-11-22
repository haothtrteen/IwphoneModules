/// 应用身份常量（界面展示用）。
///
/// ⚠️ `kAppVersion` 必须与 `pubspec.yaml` 里 `version:` 的前半段保持一致：
/// pubspec 决定 APK 的 versionName / versionCode，这里只决定界面上写什么。
/// 项目约定零第三方依赖，不引入 `package_info_plus`，所以只能手工同步 ——
/// 发版时两处一起改，别只改一处。
///
/// ★ 改应用名只改这里 + AndroidManifest 的 android:label，
///   **包名 `com.shellmgr.shell_manager` 绝不能动** ——
///   BrokerProvider authority、iwsh 广播组件、授权表签名绑定、
///   模块仓库引用全都绑在包名上，改了等于授权全废、第三方集成全断。
const String kAppName = 'IWPhone';

/// 界面上显示的版本号（与 pubspec.yaml `1.3.39+169` 同步）。
const String kAppVersion = '1.3.42';

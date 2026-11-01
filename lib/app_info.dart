/// 应用版本号（界面上显示用）。
///
/// ⚠️ 必须与 `pubspec.yaml` 里 `version:` 的前半段保持一致：
/// pubspec 决定 APK 的 versionName，这里只决定界面上写什么。
/// 项目约定零第三方依赖，不引入 `package_info_plus`，所以只能手工同步 ——
/// 发版时两处一起改，别只改一处。
const String kAppVersion = '1.3.0';

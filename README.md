<p align="center">
  <img src="assets/icon.svg" width="120" alt="随看图标">
</p>

<h1 align="center">随看 Suikan</h1>

<p align="center">
  <b>随开随看 · 想看就看</b>
</p>

<p align="center">
  把全网直播装进一个 App，想看什么，随手就看。
  斗鱼 / 虎牙 / 抖音 / B站（直播）/ 快手
</p>

---

<p align="center">
  <img src="assets/banner.jpg" alt="随看 Suikan" width="100%">
</p>

## 平台

- **手机 / iOS**：随看
- **Windows**：随看
- **TV**：随看（兼容 Android 6 / arm32）
- 支持平台：斗鱼 / 虎牙 / 抖音 / B站（直播）/ 快手

## 🎯 本仓库定制（2.0.x）

本仓库基于开源直播聚合项目定制维护。

### 统一改动（三端共用）

- **版本号**：手机版 / WIN / TV 三端统一使用自定版本号 `2.0.X`（当前 `2.0.2+20002`）。
- **品牌改名**：App 名统一为「随看」（任何平台不带 TV 字样），包名 `com.suikan.app`（手机/iOS）/ `com.suikan.tvbox`（TV）。
- **分类列表**：使用社区维护的短视频分类数据替换原版（分类相关文件）。
- **崩溃修复**：
  - Windows 退出崩溃：窗口关闭时全平台调用 `player.stop()`。
  - 直播页返回键崩溃：`PopScope` 回调中调用 `onClose()`，`SystemChrome.*` 增加平台守卫。

### 手机版 / Windows

- dart_quickjs 使用 **git 态**（sdk `>=3.10.0`）。
- Windows 退出崩溃 / 返回键崩溃修复（见上）。

### TV 版（兼容 Android 6 / arm32）

TV 版改动最大，主要针对小米盒子等安卓 6 设备：

- **固定 Flutter 3.24.5**；minSdk 使用变量写法 `val minSdkForAndroid6 = 23`，防止迁移器改回 24。
- **dart_quickjs**：改为 `path: ../vendor/dart_quickjs` + sdk `>=3.1.0`（编译前切 vendor 态、编完切回 git 态），预编译 `libquickjs.so`（arm32）置于 `jniLibs`。
- **返回键原生拦截**：`MainActivity.kt` 重写 `onKeyDown`/`onBackPressed` → MethodChannel → main.dart 决策。
- **硬解默认关**：`player_controller.dart` 按设置设 mpv `hwdec`；`app_settings_controller.dart` 默认 false。
- **小米盒子音量记忆**：MethodChannel + Hive `kLastVolume` + 轮询保存。
- **quickjs 三级加载 fallback**：`_loadLib()` 改 `lookupFunction` 写法。

## 仓库说明

- 【停更】：[原作者仓库 xiaoyaocz/dart_simple_live](https://github.com/xiaoyaocz/dart_simple_live)
- 【在更】https://github.com/June6699/dart_simple_live
- 【TDV】https://github.com/chen-zeong/dtv_mobile

## 支持平台

- [x] Android
- [x] iOS
- [x] Windows
- [x] MacOS
- [x] Linux
- [x] Android TV
- [x] TV-windows（TV 的 UI 在 Windows 上运行，相较纯 TV，此版本支持多开）

## 声明

本项目的功能基于互联网上公开资料整理与开发，无任何破解、逆向工程等行为。

本项目仅用于学习交流编程技术，严禁用于商业目的。如有任何商业行为，均与本项目无关。

如果本项目存在侵犯您合法权益的情况，请及时联系开发者，开发者会及时处理相关内容。

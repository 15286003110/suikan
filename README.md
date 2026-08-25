<p align="center">
  <img src="assets/icon.svg" width="120" alt="随看图标">
</p>

<h1 align="center">随看 Suikan</h1>

<p align="center">
  <b>随开随看 · 想看就看</b>
</p>

<p align="center">
  把全网直播装进一个 App。<br>
  主流平台热门内容，一个入口全部看到，不用来回切换。<br>
  简约无打扰，想看什么，随手就看。
</p>

---

## 平台

| 平台 | 显示名 | 包名 / Bundle ID | Flutter | 产物 |
|---|---|---|---|---|
| 手机版（Android） | 随看 | `com.suikan.app` | 3.47.1 | APK（arm64） |
| Windows | 随看 | — | 3.47.1 | ZIP |
| TV（Android 6 / arm32） | 随看 | `com.suikan.tvbox` | 3.24.5 | APK（armeabi-v7a） |
| iOS | 随看 | `com.suikan.app` | 3.47.1 | IPA（TrollStore 安装） |

## 版本号

三端统一使用自定版本号 **`2.0.X`**（编译号 `2.0.X+2000X`，当前 `2.0.2+20002`），不跟随上游版本号。

---

## 🎯 本仓库定制（2.0.x）

本仓库基于开源直播聚合项目定制维护（fork 来源见文末"仓库说明"）。

### 统一改动（三端共用）

- **版本号**：手机版 / WIN / TV 三端统一使用自定版本号 `2.0.X`（当前 `2.0.2+20002`）。
- **品牌改名**：App 名统一为「随看」（任何平台不带 TV 字样），包名 `com.suikan.app`（手机/iOS）/ `com.suikan.tvbox`（TV）。
- **抖音分类列表**：使用 [chen-zeong/dtv_mobile](https://github.com/chen-zeong/dtv_mobile) 的分类列表替换原 fork 版本（`douyin_site.dart` / `douyin_sign.dart`）。
- **崩溃修复**：
  - Windows 退出崩溃（`@image#1` / Clipboard_Screenshot 错误）：窗口关闭时全平台调用 `player.stop()`。
  - 直播页返回键崩溃：`PopScope` 回调中调用 `onClose()`，`SystemChrome.*` 增加平台守卫。

### 手机版 / Windows（Flutter 3.47.1）

- dart_quickjs 使用 **git 态**（`xiaoyaocz/dart_quickjs`，sdk `>=3.10.0`）。
- Windows 退出崩溃 / 返回键崩溃修复（见上）。

### TV 版（Flutter 3.24.5，兼容 Android 6 / arm32）

TV 版改动最大，主要针对小米盒子等安卓 6 设备：

- **固定 Flutter 3.24.5**；minSdk 使用变量写法 `val minSdkForAndroid6 = 23`，防止迁移器改回 24。
- **dart_quickjs**：改为 `path: ../vendor/dart_quickjs` + sdk `>=3.1.0`（编译前切 vendor 态、编完切回 git 态），预编译 `libquickjs.so`（arm32）置于 `jniLibs`。
- **返回键原生拦截**：`MainActivity.kt` 重写 `onKeyDown`/`onBackPressed` → MethodChannel → main.dart 决策。
- **硬解默认关**：`player_controller.dart` 按设置设 mpv `hwdec`；`app_settings_controller.dart` 默认 false（盒子硬解兼容性差）。
- **小米盒子音量记忆**：MethodChannel + Hive `kLastVolume` + 轮询保存。
- **quickjs 三级加载 fallback**：`_loadLib()` 改 `lookupFunction` 写法，兼容盒子环境。

### 云端构建（GitHub Actions）

本仓库内置工作流，可云端编译各平台安装包（仓库公开后 Actions 免费不限量）：

| 工作流 | 产物 | 说明 |
|---|---|---|
| `build-ios-trollstore.yml` | `SimpleLive.ipa` | iOS 未签名 IPA（TrollStore 重签安装），Flutter 3.47.1 |
| `build-tv-arm32.yml` | `SimpleLive_TV_arm32_2.0.X.apk` | TV 版 arm32 / 安卓6，Flutter 3.24.5 |
| `build-app-arm64.yml` | `SimpleLive_arm64_2.0.X.apk` | 手机版 arm64，Flutter 3.47.1 |
| `build-windows.yml` | `SimpleLive_WIN_2.0.X.zip` | Windows 版，Flutter 3.47.1 |

所有工作流从 `pubspec.yaml` 动态读取版本号，升版只需修改 `version: 2.0.X+2000X`。

---

## 仓库说明

- fork 来源：[原作者仓库 xiaoyaocz/dart_simple_live](https://github.com/xiaoyaocz/dart_simple_live)
- 本仓库基于 [June6699/dart_simple_live](https://github.com/June6699/dart_simple_live) 定制
- 抖音分类列表参考：[chen-zeong/dtv_mobile](https://github.com/chen-zeong/dtv_mobile)

## APP 支持平台

- [x] Android
- [x] iOS
- [x] Windows
- [x] MacOS
- [x] Linux
- [x] Android TV
- [x] TV-windows（TV 的 UI 在 Windows 上运行，相较纯 TV，此版本支持多开）

## 环境

- 手机 / WIN：Flutter `3.47.1`
- TV：Flutter `3.24.5`
- 云端构建：GitHub Actions（Linux / Windows / macOS runner）

## 声明

本项目的功能基于互联网上公开资料整理与开发，无任何破解、逆向工程等行为。

本项目仅用于学习交流编程技术，严禁用于商业目的。如有任何商业行为，均与本项目无关。

如果本项目存在侵犯您合法权益的情况，请及时联系开发者，开发者会及时处理相关内容。

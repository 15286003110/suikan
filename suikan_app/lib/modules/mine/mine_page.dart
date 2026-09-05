import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';
import 'package:remixicon/remixicon.dart';
import 'package:simple_live_app/app/app_style.dart';
import 'package:simple_live_app/app/platform_utils.dart';
import 'package:simple_live_app/app/utils.dart';
import 'package:simple_live_app/routes/app_navigation.dart';
import 'package:simple_live_app/routes/route_path.dart';
import 'package:simple_live_app/modules/settings/custom_source/custom_source_list_page.dart';
import 'package:simple_live_app/modules/settings/fnos/fn_os_list_page.dart';
import 'package:url_launcher/url_launcher_string.dart';

class MinePage extends StatelessWidget {
  const MinePage({Key? key}) : super(key: key);

  void _showAbout(BuildContext context) {
    Get.dialog(
      Dialog(
        shape: RoundedRectangleBorder(borderRadius: AppStyle.radius12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 24, 24, 12),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Image.asset(
                    'assets/images/logo.png',
                    width: 56,
                    height: 56,
                  ),
                  AppStyle.vGap8,
                  const Text(
                    "随看",
                    style: TextStyle(
                      fontSize: 17,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  const Text(
                    "随开随看 · 想看就看",
                    style: TextStyle(color: Colors.grey, fontSize: 13),
                  ),
                  AppStyle.vGap4,
                  Text(
                    "Ver ${Utils.packageInfo.version}",
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.primary,
                      fontSize: 12,
                    ),
                  ),
                ],
              ),
            ),
            const Divider(height: 1, indent: 16, endIndent: 16),
            ListTile(
              dense: true,
              leading: const Icon(Remix.error_warning_line),
              title: const Text("免责声明"),
              trailing: const Icon(
                Icons.chevron_right,
                color: Colors.grey,
              ),
              onTap: () {
                Get.back();
                Utils.showStatement();
              },
            ),
            ListTile(
              dense: true,
              leading: const Icon(Remix.github_line),
              title: const Text("开源主页"),
              trailing: const Icon(
                Icons.chevron_right,
                color: Colors.grey,
              ),
              onTap: () {
                Get.back();
                launchUrlString(
                  "https://github.com/mobingchong/suikan",
                  mode: LaunchMode.externalApplication,
                );
              },
            ),
            AppStyle.vGap4,
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: Get.isDarkMode
          ? SystemUiOverlayStyle.light.copyWith(
              systemNavigationBarColor: Colors.transparent,
            )
          : SystemUiOverlayStyle.dark.copyWith(
              systemNavigationBarColor: Colors.transparent,
            ),
      child: SafeArea(
        child: ListView(
          padding: AppStyle.edgeInsetsA4,
          children: [
            AppStyle.vGap12,
            ListTile(
              contentPadding:
                  const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              leading: Image.asset(
                'assets/images/logo.png',
                width: 56,
                height: 56,
              ),
              title: const Text(
                "随看",
                style: TextStyle(height: 1.0),
              ),
              subtitle: const Text("随开随看 · 想看就看"),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => _showAbout(context),
            ),
            _row(Remix.history_line, "观看记录", () {
              AppNavigator.toHistory();
            }),
            _row(Remix.account_circle_line, "账号管理", () {
              Get.toNamed(RoutePath.kSettingsAccount);
            }),
            _row(Icons.devices, "数据同步", () {
              Get.toNamed(RoutePath.kSync);
            }),
            _row(Icons.playlist_play, "自定义直播源", () {
              Get.to(() => const CustomSourceListPage());
            }),
            _row(Icons.movie_outlined, "NAS影视库", () {
              Get.to(() => const FnOsListPage());
            }),
            _row(Remix.link, "链接解析", () {
              Get.toNamed(RoutePath.kTools);
            }),
            _row(Remix.moon_line, "外观设置", () {
              Get.toNamed(RoutePath.kAppstyleSetting);
            }),
            _row(Remix.home_2_line, "主页设置", () {
              Get.toNamed(RoutePath.kSettingsIndexed);
            }),
            _row(Remix.play_circle_line, "直播间设置", () {
              Get.toNamed(RoutePath.kSettingsPlay);
            }),
            _row(Icons.tune, "播放页设置", () {
              Get.toNamed(RoutePath.kSettingsPlaybackPage);
            }),
            if (PlatformUtils.supportsInlineMultiRoom)
              _row(Remix.layout_grid_line, "多开设置", () {
                Get.toNamed(RoutePath.kSettingsMultiRoom);
              }),
            _row(Remix.text, "弹幕设置", () {
              Get.toNamed(RoutePath.kSettingsDanmu);
            }),
            _row(Remix.heart_line, "关注设置", () {
              Get.toNamed(RoutePath.kSettingsFollow);
            }),
            _row(Remix.timer_2_line, "定时关闭", () {
              Get.toNamed(RoutePath.kSettingsAutoExit);
            }),
            _row(Remix.apps_line, "其他设置", () {
              Get.toNamed(RoutePath.kSettingsOther);
            }),
            AppStyle.vGap12,
          ],
        ),
      ),
    );
  }

  Widget _row(IconData icon, String title, VoidCallback onTap) {
    return ListTile(
      visualDensity: VisualDensity.compact,
      contentPadding:
          const EdgeInsets.symmetric(horizontal: 16, vertical: 0),
      leading: Icon(icon),
      title: Text(title),
      trailing: const Icon(
        Icons.chevron_right,
        color: Colors.grey,
      ),
      onTap: onTap,
    );
  }
}

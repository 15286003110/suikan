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
            visualDensity: VisualDensity.compact,
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
            AppStyle.vGap12,
            _buildCard(
              context,
              children: [
                ListTile(
                visualDensity: VisualDensity.compact,
                  leading: const Icon(Remix.history_line),
                  title: const Text("观看记录"),
                  trailing: const Icon(
                    Icons.chevron_right,
                    color: Colors.grey,
                  ),
                  onTap: () {
                    AppNavigator.toHistory();
                  },
                ),
              ],
            ),
            AppStyle.vGap12,
            _buildCard(
              context,
              children: [
                ListTile(
                visualDensity: VisualDensity.compact,
                  leading: const Icon(Remix.account_circle_line),
                  title: const Text("账号管理"),
                  trailing: const Icon(
                    Icons.chevron_right,
                    color: Colors.grey,
                  ),
                  onTap: () {
                    Get.toNamed(RoutePath.kSettingsAccount);
                  },
                ),
                ListTile(
                visualDensity: VisualDensity.compact,
                  leading: const Icon(Icons.devices),
                  title: const Text("数据同步"),
                  trailing: const Icon(
                    Icons.chevron_right,
                    color: Colors.grey,
                  ),
                  onTap: () {
                    Get.toNamed(RoutePath.kSync);
                  },
                ),
              ],
            ),
            AppStyle.vGap12,
            _buildCard(
              context,
              children: [
                ListTile(
                visualDensity: VisualDensity.compact,
                  leading: const Icon(Icons.playlist_play),
                  title: const Text("自定义直播源"),
                  trailing: const Icon(
                    Icons.chevron_right,
                    color: Colors.grey,
                  ),
                  onTap: () {
                    Get.to(() => const CustomSourceListPage());
                  },
                ),
                ListTile(
                visualDensity: VisualDensity.compact,
                  leading: const Icon(Icons.movie_outlined),
                  title: const Text("NAS影视库"),
                  trailing: const Icon(
                    Icons.chevron_right,
                    color: Colors.grey,
                  ),
                  onTap: () {
                    Get.to(() => const FnOsListPage());
                  },
                ),
                ListTile(
                visualDensity: VisualDensity.compact,
                  leading: const Icon(Remix.link),
                  title: const Text("链接解析"),
                  trailing: const Icon(
                    Icons.chevron_right,
                    color: Colors.grey,
                  ),
                  onTap: () {
                    Get.toNamed(RoutePath.kTools);
                  },
                ),
              ],
            ),
            AppStyle.vGap12,
            _buildCard(
              context,
              children: [
                ListTile(
                visualDensity: VisualDensity.compact,
                  leading: const Icon(Remix.moon_line),
                  title: const Text("外观设置"),
                  trailing: const Icon(
                    Icons.chevron_right,
                    color: Colors.grey,
                  ),
                  onTap: () {
                    Get.toNamed(RoutePath.kAppstyleSetting);
                  },
                ),
                ListTile(
                visualDensity: VisualDensity.compact,
                  leading: const Icon(Remix.home_2_line),
                  title: const Text("主页设置"),
                  trailing: const Icon(
                    Icons.chevron_right,
                    color: Colors.grey,
                  ),
                  onTap: () {
                    Get.toNamed(RoutePath.kSettingsIndexed);
                  },
                ),
                ListTile(
                visualDensity: VisualDensity.compact,
                  leading: const Icon(Remix.play_circle_line),
                  title: const Text("直播间设置"),
                  trailing: const Icon(
                    Icons.chevron_right,
                    color: Colors.grey,
                  ),
                  onTap: () {
                    Get.toNamed(RoutePath.kSettingsPlay);
                  },
                ),
                ListTile(
                visualDensity: VisualDensity.compact,
                  leading: const Icon(Icons.tune),
                  title: const Text("播放页设置"),
                  trailing: const Icon(
                    Icons.chevron_right,
                    color: Colors.grey,
                  ),
                  onTap: () {
                    Get.toNamed(RoutePath.kSettingsPlaybackPage);
                  },
                ),
                if (PlatformUtils.supportsInlineMultiRoom)
                  ListTile(
                  visualDensity: VisualDensity.compact,
                    leading: const Icon(Remix.layout_grid_line),
                    title: const Text("多开设置"),
                    trailing: const Icon(
                      Icons.chevron_right,
                      color: Colors.grey,
                    ),
                    onTap: () {
                      Get.toNamed(RoutePath.kSettingsMultiRoom);
                    },
                  ),
                ListTile(
                visualDensity: VisualDensity.compact,
                  leading: const Icon(Remix.text),
                  title: const Text("弹幕设置"),
                  trailing: const Icon(
                    Icons.chevron_right,
                    color: Colors.grey,
                  ),
                  onTap: () {
                    Get.toNamed(RoutePath.kSettingsDanmu);
                  },
                ),
                ListTile(
                visualDensity: VisualDensity.compact,
                  leading: const Icon(Remix.heart_line),
                  title: const Text("关注设置"),
                  trailing: const Icon(
                    Icons.chevron_right,
                    color: Colors.grey,
                  ),
                  onTap: () {
                    Get.toNamed(RoutePath.kSettingsFollow);
                  },
                ),
                ListTile(
                visualDensity: VisualDensity.compact,
                  leading: const Icon(Remix.timer_2_line),
                  title: const Text("定时关闭"),
                  trailing: const Icon(
                    Icons.chevron_right,
                    color: Colors.grey,
                  ),
                  onTap: () {
                    Get.toNamed(RoutePath.kSettingsAutoExit);
                  },
                ),
                ListTile(
                visualDensity: VisualDensity.compact,
                  leading: const Icon(Remix.apps_line),
                  title: const Text("其他设置"),
                  trailing: const Icon(
                    Icons.chevron_right,
                    color: Colors.grey,
                  ),
                  onTap: () {
                    Get.toNamed(RoutePath.kSettingsOther);
                  },
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildCard(
    BuildContext context, {
    required List<Widget> children,
  }) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Theme(
          data: Theme.of(context).copyWith(
            listTileTheme: ListTileThemeData(
              shape: RoundedRectangleBorder(borderRadius: AppStyle.radius8),
            ),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: children,
          ),
        ),
      ],
    );
  }
}

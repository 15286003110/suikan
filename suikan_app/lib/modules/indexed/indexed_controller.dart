import 'package:flutter/widgets.dart';

import 'package:get/get.dart';
import 'package:simple_live_app/app/constant.dart';
import 'package:simple_live_app/app/controller/app_settings_controller.dart';
import 'package:simple_live_app/app/desktop_startup_args.dart';
import 'package:simple_live_app/app/event_bus.dart';
import 'package:simple_live_app/app/log.dart';
import 'package:simple_live_app/app/sites.dart';
import 'package:simple_live_app/app/utils.dart';
import 'package:simple_live_app/modules/category/category_controller.dart';
import 'package:simple_live_app/modules/category/category_page.dart';
import 'package:simple_live_app/modules/home/home_controller.dart';
import 'package:simple_live_app/modules/home/home_page.dart';
import 'package:simple_live_app/modules/follow_user/follow_user_controller.dart';
import 'package:simple_live_app/modules/follow_user/follow_user_page.dart';
import 'package:simple_live_app/modules/mine/mine_page.dart';
import 'package:simple_live_app/routes/app_navigation.dart';

class IndexedController extends GetxController {
  RxList<HomePageItem> items = RxList<HomePageItem>([]);

  var index = 0.obs;
  RxList<Widget> pages = RxList<Widget>([
    const SizedBox(),
    const SizedBox(),
    const SizedBox(),
    const SizedBox(),
  ]);

  void setIndex(int i) {
    if (pages[i] is SizedBox) {
      switch (items[i].index) {
        case 0:
          Get.put(HomeController());
          pages[i] = const HomePage();
          break;
        case 1:
          Get.put(FollowUserController());
          pages[i] = const FollowUserPage();
          break;
        case 2:
          Get.put(CategoryController());
          pages[i] = const CategoryPage();
          break;
        case 3:
          pages[i] = const MinePage();
          break;
        default:
      }
    } else {
      if (index.value == i) {
        EventBus.instance
            .emit<int>(EventBus.kBottomNavigationBarClicked, items[i].index);
      }
    }

    index.value = i;
  }

  @override
  void onInit() {
    Future.delayed(Duration.zero, showFirstRun);
    Future.delayed(Duration.zero, restorePendingLiveRoom);
    items.value = AppSettingsController.instance.homeSort
        .map((key) => Constant.allHomePages[key]!)
        .toList();
    setIndex(0);
    super.onInit();
  }

  void showFirstRun() async {
    var settingsController = Get.find<AppSettingsController>();
    if (settingsController.firstRun) {
      settingsController.setNoFirstRun();
      await Utils.showStatement();
    }
  }

  void restorePendingLiveRoom() async {
    try {
      final settingsController = Get.find<AppSettingsController>();
      final startupRoom = DesktopStartupArgs.startupRoom;
      final lastRoom =
          startupRoom ?? await settingsController.consumePendingLastLiveRoom();
      if (lastRoom == null) {
        return;
      }
      final siteId = lastRoom["siteId"];
      final roomId = lastRoom["roomId"];
      if (siteId == null || roomId == null || roomId.isEmpty) {
        return;
      }
      // 站点可能尚未注册（极端时序）：等一帧再确认，仍无则跳过，不阻断启动。
      await Future.delayed(Duration.zero);
      final site = Sites.allSites[siteId];
      if (site == null) {
        Log.w('自动恢复直播间跳过：站点未注册 $siteId');
        return;
      }
      AppNavigator.toLiveRoomDetail(
        site: site,
        roomId: roomId,
        initialDesktopSidePanelCollapsed:
            DesktopStartupArgs.startupCollapseChat,
      );
    } catch (e, stack) {
      // 自动恢复是锦上添花，任何异常都不应让 App 变空白页。
      Log.e('自动恢复直播间异常（已跳过）: $e', stack);
    }
  }
}

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:simple_live_app/app/event_bus.dart';
import 'package:simple_live_app/app/sites.dart';
import 'package:simple_live_app/modules/home/home_list_controller.dart';
import 'package:simple_live_app/routes/route_path.dart';

class HomeController extends GetxController
    with GetSingleTickerProviderStateMixin {
  late TabController tabController;
  final tabVersion = 0.obs;
  StreamSubscription<dynamic>? streamSubscription;
  StreamSubscription<dynamic>? _customSub;
  StreamSubscription<dynamic>? _siteSub;

  HomeController() {
    tabController =
        TabController(length: Sites.browseSites.length, vsync: this);
  }

  @override
  void onInit() {
    streamSubscription = EventBus.instance.listen(
      EventBus.kBottomNavigationBarClicked,
      (index) {
        if (index == 0) {
          refreshOrScrollTop();
        }
      },
    );
    _registerSiteControllers();
    _customSub = EventBus.instance.listen(
      EventBus.kCustomSourcesChanged,
      (_) => _rebuildTabs(),
    );
    _siteSub = EventBus.instance.listen(
      EventBus.kSiteSettingsChanged,
      (_) => _rebuildTabs(),
    );
    super.onInit();
  }

  void _registerSiteControllers() {
    for (var site in Sites.browseSites) {
      if (site.id.startsWith('custom_') || site.id.startsWith('fnos_')) {
        continue;
      }
      if (!Get.isRegistered<HomeListController>(tag: site.id)) {
        Get.put(HomeListController(site), tag: site.id);
      }
    }
  }

  void _rebuildTabs() {
    tabController.dispose();
    tabController =
        TabController(length: Sites.browseSites.length, vsync: this);
    _registerSiteControllers();
    tabVersion.value++;
  }

  void refreshOrScrollTop() {
    var tabIndex = tabController.index;
    if (tabIndex < 0 || tabIndex >= Sites.browseSites.length) return;
    final site = Sites.browseSites[tabIndex];
    if (site.id.startsWith('custom_') || site.id.startsWith('fnos_')) return;
    final controller = Get.find<HomeListController>(tag: site.id);
    controller.scrollToTopOrRefresh();
  }

  void toSearch() {
    Get.toNamed(
      RoutePath.kSearch,
      arguments: {
        "siteId": Sites.browseSites[tabController.index].id,
      },
    );
  }

  @override
  void onClose() {
    streamSubscription?.cancel();
    _customSub?.cancel();
    _siteSub?.cancel();
    super.onClose();
  }
}

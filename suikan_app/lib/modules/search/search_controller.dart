import 'dart:async';

import 'package:flutter/material.dart';

import 'package:get/get.dart';
import 'package:simple_live_app/app/controller/app_settings_controller.dart';
import 'package:simple_live_app/app/sites.dart';
import 'package:simple_live_app/modules/search/local_content_search_controller.dart';
import 'package:simple_live_app/modules/search/search_list_controller.dart';

class AppSearchController extends GetxController
    with GetSingleTickerProviderStateMixin {
  late TabController tabController;
  int index = 0;

  var searchMode = 0.obs;

  /// 可搜索的直播平台（排除自定义源 custom_ 与影视库 fnos_，它们统一进「本地内容」tab）。
  List<Site> get searchSites => Sites.supportSites
      .where((s) =>
          !s.id.startsWith('custom_') && !s.id.startsWith('fnos_'))
      .toList();

  AppSearchController() {
    final initialIndex = _resolveInitialIndex();
    index = initialIndex;
    // 第 0 个 tab 为「本地内容」（直播源频道+影视库），其后为各直播平台。
    tabController = TabController(
      length: searchSites.length + 1,
      vsync: this,
      initialIndex: initialIndex,
    );
    AppSettingsController.instance
        .setLastSearchSiteId(searchSites[index - 1].id);
    tabController.animation?.addListener(() {
      var currentIndex = (tabController.animation?.value ?? 0).round();
      if (index == currentIndex) {
        return;
      }
      index = currentIndex;
      if (index == 0) {
        return; // 本地内容 tab 无需触发平台搜索
      }
      AppSettingsController.instance
          .setLastSearchSiteId(searchSites[index - 1].id);

      var controller = Get.find<SearchListController>(
          tag: searchSites[index - 1].id);

      if (controller.list.isEmpty &&
          !controller.pageEmpty.value &&
          controller.keyword.isNotEmpty) {
        controller.refreshData();
      }
    });
  }

  StreamSubscription<dynamic>? streamSubscription;

  TextEditingController searchController = TextEditingController();

  int _resolveInitialIndex() {
    String? siteId;
    final args = Get.arguments;
    if (args is Map) {
      siteId = args["siteId"]?.toString();
    } else if (args is String) {
      siteId = args;
    }
    siteId ??= AppSettingsController.instance.lastSearchSiteId.value;
    final resolvedIndex =
        searchSites.indexWhere((site) => site.id == siteId);
    // 平台 tab 前移一位（本地内容占 0）
    return resolvedIndex < 0 ? 1 : resolvedIndex + 1;
  }

  @override
  void onInit() {
    Get.put(LocalContentSearchController());
    for (var site in searchSites) {
      Get.put(
        SearchListController(site),
        tag: site.id,
      );
    }

    super.onInit();
  }

  void doSearch() {
    if (searchController.text.isEmpty) {
      return;
    }
    if (index == 0) {
      // 本地内容：直播源频道 + 影视库
      Get.find<LocalContentSearchController>()
          .search(searchController.text);
      return;
    }
    for (var site in searchSites) {
      var controller = Get.find<SearchListController>(tag: site.id);
      controller.clear();
      controller.keyword = searchController.text;
      controller.searchMode.value = searchMode.value;
    }
    var controller = Get.find<SearchListController>(
        tag: searchSites[index - 1].id);
    controller.refreshData();
  }

  @override
  void onClose() {
    streamSubscription?.cancel();
    super.onClose();
  }
}

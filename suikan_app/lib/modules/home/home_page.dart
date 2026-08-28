import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:simple_live_app/app/app_style.dart';
import 'package:simple_live_app/app/fnos/fn_os_service.dart';
import 'package:simple_live_app/app/sites.dart';
import 'package:simple_live_app/modules/home/home_controller.dart';
import 'package:simple_live_app/modules/home/home_list_view.dart';
import 'package:simple_live_app/modules/settings/custom_source/custom_source_browse_page.dart';
import 'package:simple_live_app/modules/settings/fnos/fn_os_browse_page.dart';

class HomePage extends GetView<HomeController> {
  const HomePage({Key? key}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return Obx(() {
      // 自定义源 / 飞牛影视 增删后实时重建标签
      controller.tabVersion.value;
      return Scaffold(
        appBar: AppBar(
          titleSpacing: 8,
          title: TabBar(
            controller: controller.tabController,
            labelPadding: AppStyle.edgeInsetsH20,
            isScrollable: true,
            indicatorSize: TabBarIndicatorSize.label,
            tabAlignment: TabAlignment.center,
            tabs: Sites.browseSites
                .map(
                  (e) => Tab(
                    //text: e.name,

                    child: Row(
                      children: [
                        Image.asset(
                          e.logo,
                          width: 24,
                        ),
                        AppStyle.hGap8,
                        Text(e.name),
                      ],
                    ),
                  ),
                )
                .toList(),
          ),
          actions: [
            IconButton(
              onPressed: controller.toSearch,
              icon: const Icon(Icons.search),
            )
          ],
        ),
        body: TabBarView(
          controller: controller.tabController,
          children: Sites.browseSites
              .map(
                (e) => e.id.startsWith('fnos_')
                    ? FnOsBrowsePage(
                        server: FnOsService.instance.serverForSiteId(e.id)!,
                        embedded: true,
                      )
                    : e.id.startsWith('custom_')
                        ? CustomSourceBrowsePage(sourceId: e.id)
                        : HomeListView(
                            e.id,
                          ),
              )
              .toList(),
        ),
      );
    });
  }
}

import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:simple_live_app/app/app_style.dart';
import 'package:simple_live_app/modules/search/global_search_controller.dart';
import 'package:simple_live_app/modules/search/global_search_view.dart';

/// 方案 B：彻底单页全局搜索
/// - 单输入框，输入防抖 600ms 自动搜
/// - 无平台/本地内容 Tab、无房间/主播切换，一次搜索聚合全部来源
class SearchPage extends GetView<GlobalSearchController> {
  const SearchPage({Key? key}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        automaticallyImplyLeading: false,
        title: TextField(
          controller: controller.searchController,
          autofocus: true,
          onChanged: controller.onInputChanged,
          decoration: InputDecoration(
            hintText: "搜索所有平台与本地内容",
            border: OutlineInputBorder(
              borderRadius: AppStyle.radius24,
            ),
            contentPadding: AppStyle.edgeInsetsH12,
            prefixIcon: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                IconButton(
                  onPressed: Get.back,
                  icon: const Icon(Icons.arrow_back),
                ),
                AppStyle.hGap8,
              ],
            ),
            suffixIcon: IconButton(
              onPressed: () =>
                  controller.searchGlobal(controller.searchController.text),
              icon: const Icon(Icons.search),
            ),
          ),
          onSubmitted: (e) {
            controller.searchGlobal(e);
          },
        ),
      ),
      body: const GlobalSearchView(),
    );
  }
}

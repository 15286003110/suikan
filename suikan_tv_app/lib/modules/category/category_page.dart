import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:simple_live_tv_app/routes/app_navigation.dart';
import 'package:simple_live_tv_app/widgets/highlight_widget.dart';
import 'package:simple_live_tv_app/widgets/net_image.dart';
import 'package:get/get.dart';
import 'package:simple_live_tv_app/app/app_focus_node.dart';
import 'package:simple_live_tv_app/app/app_style.dart';
import 'package:simple_live_tv_app/app/fnos/fn_os_service.dart';
import 'package:simple_live_tv_app/app/sites.dart';
import 'package:simple_live_tv_app/modules/category/category_controller.dart';
import 'package:simple_live_tv_app/modules/settings/custom_source/custom_source_browse_page.dart';
import 'package:simple_live_tv_app/modules/settings/fnos/fn_os_browse_page.dart';
import 'package:simple_live_tv_app/widgets/app_scaffold.dart';
import 'package:simple_live_tv_app/widgets/button/highlight_button.dart';

class CategoryPage extends GetView<CategoryController> {
  const CategoryPage({super.key});

  @override
  Widget build(BuildContext context) {
    return AppScaffold(
      child: Column(
        children: [
          AppStyle.vGap32,
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              AppStyle.hGap48,
              HighlightButton(
                focusNode: AppFocusNode(),
                iconData: Icons.arrow_back,
                text: "返回",
                //autofocus: true, // 焦点默认给下方列表, 与热门直播保持一致
                onTap: () {
                  Get.back();
                },
              ),
              AppStyle.hGap32,
              Text(
                "直播类目",
                style: AppStyle.titleStyleWhite.copyWith(
                  fontSize: 36.w,
                  fontWeight: FontWeight.bold,
                ),
              ),
              AppStyle.hGap24,
              const Spacer(),
              Obx(
                () => Visibility(
                  visible: controller.loadding.value,
                  child: SizedBox(
                    width: 48.w,
                    height: 48.w,
                    child: CircularProgressIndicator(
                      color: Colors.white,
                      strokeWidth: 4.w,
                    ),
                  ),
                ),
              ),
              //  AppStyle.hGap24,
              // HighlightButton(
              //   focusNode: AppFocusNode(),
              //   iconData: Icons.refresh,
              //   text: "刷新",
              //   onTap: () {
              //     controller.refreshData();
              //   },
              // ),
              AppStyle.hGap48,
            ],
          ),
          AppStyle.vGap24,
          Wrap(
            alignment: WrapAlignment.center,
            spacing: 36.w,
            children: Sites.supportSites
                .map(
                  (e) => Obx(
                    () => HighlightButton(
                      icon: Image.asset(
                        e.logo,
                        width: 48.w,
                        height: 48.w,
                      ),
                      text: e.name,
                      selected: controller.siteId.value == e.id,
                      focusNode: AppFocusNode(),
                      onTap: () {
                        final id = e.id;
                        // 自定义直播源/飞牛影视库与手机端一致：打开频道网格/影视库浏览页，
                        // 不走内置平台的类目接口。
                        if (id.startsWith('custom_')) {
                          Get.to(() => CustomSourceBrowsePage(sourceId: id));
                          return;
                        }
                        if (id.startsWith('fnos_')) {
                          final server =
                              FnOsService.instance.serverForSiteId(id);
                          if (server != null) {
                            Get.to(() => FnOsBrowsePage(server: server));
                          }
                          return;
                        }
                        controller.setSite(id);
                      },
                    ),
                  ),
                )
                .toList(),
          ),
          AppStyle.vGap24,
          Expanded(
            child: Obx(
              () => ListView.builder(
                padding: AppStyle.edgeInsetsH48,
                itemCount: controller.list.length,
                controller: controller.scrollController,
                itemBuilder: (_, i) {
                  var item = controller.list[i];
                  // 进入页面/切换平台后, 焦点默认落到第一个分类的第一个子类目(下方列表),
                  // 而不是左上角返回键 (与热门直播行为一致)
                  if (i == 0) {
                    Future.delayed(Duration.zero, () {
                      if (controller.currentPage == 2) {
                        final subs =
                            item.showAll.value ? item.childrenExt : item.take15;
                        if (subs.isNotEmpty) {
                          subs.first.focusNode.requestFocus();
                        }
                      }
                    });
                  }
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Padding(
                        padding: AppStyle.edgeInsetsV32,
                        child: Text(
                          item.name,
                          style: AppStyle.titleStyleWhite,
                        ),
                      ),
                      Obx(
                        () => GridView.count(
                          shrinkWrap: true,
                          padding: AppStyle.edgeInsetsV8,
                          physics: const NeverScrollableScrollPhysics(),
                          crossAxisCount: 8,
                          crossAxisSpacing: 36.w,
                          mainAxisSpacing: 36.w,
                          children: item.showAll.value
                              ? (item.childrenExt
                                  .map(
                                    (e) => buildSubCategory(e),
                                  )
                                  .toList())
                              : (item.take15
                                  .map(
                                    (e) => buildSubCategory(e),
                                  )
                                  .toList()
                                ..add(buildShowMore(item))),
                        ),
                      ),
                    ],
                  );
                },
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget buildSubCategory(LiveSubCategoryExt item) {
    return HighlightWidget(
      focusNode: item.focusNode,
      onTap: () {
        AppNavigator.toCategoryDetail(site: item.site, category: item);
      },
      color: Colors.white10,
      borderRadius: AppStyle.radius16,
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          (item.pic != null && item.pic!.isNotEmpty)
              ? NetImage(
                  item.pic ?? "",
                  width: 64.w,
                  height: 64.w,
                  borderRadius: 16.w,
                  cacheWidth: 100,
                )
              : Image.asset(
                  "assets/images/${item.site.id}.png",
                  width: 64.w,
                  height: 64.w,
                ),
          AppStyle.vGap12,
          Text(
            item.name,
            maxLines: 1,
            textAlign: TextAlign.center,
            style: item.focusNode.isFoucsed.value
                ? AppStyle.textStyleBlack
                : AppStyle.textStyleWhite,
          ),
        ],
      ),
    );
  }

  Widget buildShowMore(AppLiveCategory item) {
    return HighlightWidget(
      focusNode: item.moreFocusNode,
      onTap: () {
        item.showAll.value = true;
      },
      color: Colors.white10,
      borderRadius: AppStyle.radius16,
      child: Center(
        child: Text(
          "显示全部",
          maxLines: 1,
          textAlign: TextAlign.center,
          style: item.moreFocusNode.isFoucsed.value
              ? AppStyle.textStyleBlack
              : AppStyle.textStyleWhite,
        ),
      ),
    );
  }
}

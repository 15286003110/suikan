import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:get/get.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:simple_live_tv_app/app/app_focus_node.dart';
import 'package:simple_live_tv_app/app/app_style.dart';
import 'package:simple_live_tv_app/modules/sync/sync_controller.dart';
import 'package:simple_live_tv_app/services/sync_service.dart';
import 'package:simple_live_tv_app/widgets/app_scaffold.dart';
import 'package:simple_live_tv_app/widgets/button/highlight_button.dart';

class SyncPage extends GetView<SyncController> {
  const SyncPage({super.key});

  @override
  Widget build(BuildContext context) {
    return AppScaffold(
      child: Column(
        children: [
          AppStyle.vGap24,
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              AppStyle.hGap48,
              HighlightButton(
                focusNode: AppFocusNode(),
                iconData: Icons.arrow_back,
                text: "返回",
                autofocus: true,
                onTap: () {
                  Get.back();
                },
              ),
              AppStyle.hGap32,
              Text(
                "数据同步",
                style: AppStyle.titleStyleWhite.copyWith(
                  fontSize: 36.w,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const Spacer(),
              AppStyle.hGap48,
            ],
          ),
          AppStyle.vGap24,
          Expanded(
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Text(
                        "配置包同步",
                        style: AppStyle.titleStyleWhite.copyWith(
                          fontSize: 32.w,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      AppStyle.vGap12,
                      Text(
                        "本 TV 作为接收端，无需额外操作：\n"
                        "在手机 / 电脑 / 平板的随看中打开\n"
                        "「数据同步 - 局域网同步」，\n"
                        "发现本 TV 后选择「同步完整配置包」，\n"
                        "即可推送设置、关注、历史、屏蔽词、\n"
                        "自定义直播源、影视库与账号到本 TV。",
                        style: AppStyle.subTextStyleWhite,
                        textAlign: TextAlign.center,
                      ),
                      AppStyle.vGap16,
                      Text(
                        "同步完成后数据自动生效，无需重启。",
                        style: AppStyle.textStyleWhite,
                        textAlign: TextAlign.center,
                      ),
                    ],
                  ),
                ),
                VerticalDivider(
                  color: Colors.white.withAlpha(50),
                  thickness: 2.w,
                  endIndent: 120.w,
                  indent: 120.w,
                ),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Text(
                        "局域网同步",
                        style: AppStyle.titleStyleWhite.copyWith(
                          fontSize: 32.w,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      AppStyle.vGap16,
                      Obx(
                        () => Visibility(
                          visible: SyncService.instance.httpRunning.value,
                          child: GestureDetector(
                            onTap: () {
                              Get.back();
                            },
                            child: QrImageView(
                              data: SyncService.instance.ipAddress.value,
                              version: QrVersions.auto,
                              backgroundColor: Colors.white,
                              padding: AppStyle.edgeInsetsA24,
                              size: 420.0.w,
                            ),
                          ),
                        ),
                      ),
                      AppStyle.vGap24,
                      Obx(
                        () => Visibility(
                          visible: SyncService.instance.httpRunning.value,
                          child: Text(
                            '服务已启动：${SyncService.instance.ipAddress.value.split(';').map((e) => '$e:${SyncService.httpPort}').join('；')}',
                            style: AppStyle.textStyleWhite,
                            textAlign: TextAlign.center,
                          ),
                        ),
                      ),
                      Obx(
                        () => Visibility(
                          visible: !SyncService.instance.httpRunning.value,
                          child: Text(
                            SyncService.instance.lanErrorMsg.isEmpty
                                ? 'HTTP服务未启动，请尝试重启应用'
                                : SyncService.instance.lanErrorMsg,
                            style: AppStyle.textStyleWhite,
                            textAlign: TextAlign.center,
                          ),
                        ),
                      ),
                      Obx(
                        () => Visibility(
                          visible: SyncService.instance.httpRunning.value &&
                              SyncService.instance.udpErrorMsg.value.isNotEmpty,
                          child: Padding(
                            padding: EdgeInsets.only(top: 12.w),
                            child: Text(
                              SyncService.instance.udpErrorMsg.value,
                              style: AppStyle.subTextStyleWhite,
                              textAlign: TextAlign.center,
                            ),
                          ),
                        ),
                      ),
                      AppStyle.vGap12,
                      Obx(
                        () => Visibility(
                          visible: SyncService.instance.httpRunning.value,
                          child: Text(
                            "请扫描二维码或在手机端搜索本 TV\n建立连接后可在手机端选择要同步的数据",
                            style: AppStyle.textStyleWhite,
                            textAlign: TextAlign.center,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

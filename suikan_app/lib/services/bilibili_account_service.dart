import 'dart:io';

import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';
import 'package:simple_live_app/app/constant.dart';
import 'package:simple_live_app/app/sites.dart';
import 'package:simple_live_app/models/account/bilibili_user_info_page.dart';
import 'package:simple_live_app/requests/http_client.dart';
import 'package:simple_live_app/services/local_storage_service.dart';
import 'package:simple_live_core/simple_live_core.dart';

class BiliBiliAccountService extends GetxService {
  static BiliBiliAccountService get instance =>
      Get.find<BiliBiliAccountService>();

  var logined = false.obs;

  var cookie = "";
  var uid = 0;
  var name = "未登录".obs;

  @override
  void onInit() {
    cookie = LocalStorageService.instance
        .getValue(LocalStorageService.kBilibiliCookie, "");
    logined.value = cookie.isNotEmpty;
    loadUserInfo();
    super.onInit();
  }

  /// 只有这几类 code 才代表"登录态真的没了"，应该清凭证。
  ///
  /// 依据 bilibili-API-collect 公共错误码表：
  /// - -101 账号未登录 / -102 账号被封停 / -658 Token 过期  → 权限类
  /// 而 **-352 风控校验失败、-412 IP 被拦截、-509/-799 限频** 属于**请求类**，
  /// 是"你被风控了"而不是"你没登录"。把它们当登录失效清掉，会形成
  /// 「被风控 → 清登录 → 变匿名 → 更容易被风控」的恶性循环。
  static bool _isAuthFailure(int? code) =>
      code == -101 || code == -102 || code == -658;

  static int? _codeOf(Map result) {
    final c = result["code"];
    if (c is int) return c;
    if (c is String) return int.tryParse(c);
    return null;
  }

  Future loadUserInfo() async {
    if (cookie.isEmpty) {
      return;
    }
    // 先验注入：本地有 cookie 就先给站点用上，再去做网络校验。
    // 以前只有 code==0 才 setSite()，一旦这次请求超时/被风控/网络未就绪，
    // 界面仍显示"已登录"，但本次运行全程匿名发请求 —— 用户完全无感。
    setSite();
    try {
      var result = await HttpClient.instance.getJson(
        "https://api.bilibili.com/x/member/web/account",
        header: {
          "Cookie": cookie,
        },
      );
      var code = _codeOf(result);
      if (code == 0) {
        var info = BiliBiliUserInfoModel.fromJson(result["data"]);
        name.value = info.uname ?? "未登录";
        uid = info.mid ?? 0;
        setSite();
      } else if (_isAuthFailure(code)) {
        SmartDialog.showToast("哔哩哔哩登录已失效，请重新登录");
        logout();
      } else {
        // 风控 / 限频 / 其它业务错误：保留登录态（cookie 已在开头注入，
        // 观看与弹幕不受影响），只记录，不登出。
        CoreLog.w(
          "B站用户信息接口返回非登录类错误，保留登录态：code=$code "
          "message=${result["message"]}",
        );
      }
    } catch (e) {
      // 网络失败同理：cookie 已注入，功能不受影响，绝不能登出。
      CoreLog.w("获取哔哩哔哩用户信息失败（不影响观看）：$e");
    }
  }

  void setSite() {
    var site = (Sites.allSites[Constant.kBiliBili]!.liveSite as BiliBiliSite);
    site.userId = uid;
    site.cookie = cookie;
  }

  void setCookie(String cookie) {
    this.cookie = cookie;
    LocalStorageService.instance
        .setValue(LocalStorageService.kBilibiliCookie, cookie);
    logined.value = cookie.isNotEmpty;
    // 登录成功即刻生效：直接注入站点，不必等后续那次 loadUserInfo()。
    // 以前这里不注入，全靠三个登录流程在后面补一句 loadUserInfo()；
    // 一旦那次请求网络失败，用户"登录成功"了却仍是匿名身份。
    if (cookie.isNotEmpty) {
      setSite();
    }
  }

  void logout() async {
    cookie = "";
    uid = 0;
    name.value = "未登录";
    setSite();
    LocalStorageService.instance
        .setValue(LocalStorageService.kBilibiliCookie, "");
    logined.value = false;

    if (Platform.isAndroid || Platform.isIOS) {
      CookieManager cookieManager = CookieManager.instance();
      await cookieManager.deleteAllCookies();
    }
  }
}

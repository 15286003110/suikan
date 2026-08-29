import 'package:simple_live_core/simple_live_core.dart';
import 'package:simple_live_tv_app/app/app_focus_node.dart';
import 'package:simple_live_tv_app/app/constant.dart';
import 'package:simple_live_tv_app/app/controller/app_settings_controller.dart';
import 'package:simple_live_tv_app/app/custom_source/custom_source_service.dart';
import 'package:simple_live_tv_app/app/fnos/fn_os_service.dart';

class Sites {
  static final Map<String, Site> allSites = {
    Constant.kBiliBili: Site(
      id: Constant.kBiliBili,
      logo: "assets/images/bilibili_2.png",
      name: "哔哩哔哩",
      liveSite: BiliBiliSite(),
      index: 0,
    ),
    Constant.kDouyu: Site(
      id: Constant.kDouyu,
      logo: "assets/images/douyu.png",
      name: "斗鱼直播",
      liveSite: DouyuSite(),
      index: 1,
    ),
    Constant.kHuya: Site(
      id: Constant.kHuya,
      logo: "assets/images/huya.png",
      name: "虎牙直播",
      liveSite: HuyaSite(),
      index: 2,
    ),
    Constant.kDouyin: Site(
      id: Constant.kDouyin,
      logo: "assets/images/douyin.png",
      name: "抖音直播",
      liveSite: DouyinSite(),
      index: 3,
    ),
    Constant.kKuaishou: Site(
      id: Constant.kKuaishou,
      logo: "assets/images/kuaishou.png",
      name: "快手直播",
      liveSite: KuaishouSite(),
      index: 4,
    ),
  };

  /// 首页/分类/热门直播展示的平台列表，与手机/电脑/iOS 保持一致：
  /// 内置站（按用户排序，未设置则按注册顺序）+ 自定义直播源 + 飞牛影视库（按添加顺序）。
  static List<Site> get supportSites {
    final raw = AppSettingsController.instance.siteSort;
    final order = raw.isNotEmpty
        ? raw
        : allSites.keys
            .where((k) => !k.startsWith('custom_') && !k.startsWith('fnos_'))
            .toList();
    final builtin = order
        .where((key) =>
            allSites.containsKey(key) &&
            !key.startsWith('custom_') &&
            !key.startsWith('fnos_'))
        .map((key) => allSites[key]!)
        .toList();
    final custom = CustomSourceService.instance.sources
        .map((s) => CustomSourceService.instance.siteForSource(s.id))
        .whereType<Site>()
        .toList();
    final fnos = FnOsService.instance.servers
        .map((s) => FnOsService.instance.siteForServer(s.id))
        .whereType<Site>()
        .toList();
    return [...builtin, ...custom, ...fnos];
  }
}

class Site {
  final String id;
  final String name;
  final String logo;
  final LiveSite liveSite;
  final int index;
  AppFocusNode appFocusNode = AppFocusNode();
  Site({
    required this.id,
    required this.liveSite,
    required this.logo,
    required this.name,
    this.index = 0,
  });
}

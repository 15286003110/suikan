import 'package:simple_live_app/app/constant.dart';
import 'package:simple_live_app/app/controller/app_settings_controller.dart';
import 'package:simple_live_app/app/custom_source/custom_source_service.dart';
import 'package:simple_live_app/app/fnos/fn_os_service.dart';
import 'package:simple_live_core/simple_live_core.dart';

class Sites {
  static final Map<String, Site> allSites = {
    Constant.kBiliBili: Site(
      id: Constant.kBiliBili,
      logo: "assets/images/bilibili_2.png",
      name: "哔哩哔哩",
      liveSite: BiliBiliSite(),
    ),
    Constant.kDouyu: Site(
      id: Constant.kDouyu,
      logo: "assets/images/douyu.png",
      name: "斗鱼直播",
      liveSite: DouyuSite(),
    ),
    Constant.kHuya: Site(
      id: Constant.kHuya,
      logo: "assets/images/huya.png",
      name: "虎牙直播",
      liveSite: HuyaSite(),
    ),
    Constant.kDouyin: Site(
      id: Constant.kDouyin,
      logo: "assets/images/douyin.png",
      name: "抖音直播",
      liveSite: DouyinSite(),
    ),
    Constant.kKuaishou: Site(
      id: Constant.kKuaishou,
      logo: "assets/images/kuaishou.png",
      name: "快手直播",
      liveSite: KuaishouSite(),
    ),
  };

  static List<Site> get supportSites {
    final hidden = AppSettingsController.instance.hiddenSites;
    final builtin = AppSettingsController.instance.siteSort
        .where(
          (key) =>
              allSites.containsKey(key) &&
              !key.startsWith('custom_') &&
              !hidden.contains(key),
        )
        .map((key) => allSites[key]!)
        .toList();
    // 自定义直播源按用户填写的名称显示在首页/分类（仅走浏览页，不进分类子页）。
    final custom = CustomSourceService.instance.sources
        .map((s) => CustomSourceService.instance.siteForSource(s.id))
        .whereType<Site>()
        .where((s) => !hidden.contains(s.id))
        .toList();
    return [...builtin, ...custom];
  }

  /// 首页/分类展示用的站点列表：按「主页设置 → 平台排序」的完整顺序
  /// （内置平台 + 自定义直播源 + 飞牛影视，全部可由用户拖拽排序）。
  /// 运行期新增的源（自定义源/影视库）自动排在末尾，无需重启即可在设置页调整。
  static List<Site> get browseSites {
    final hidden = AppSettingsController.instance.hiddenSites;
    final order = AppSettingsController.instance.effectiveBrowseSiteOrder;
    final result = <Site>[];
    for (final key in order) {
      if (hidden.contains(key)) continue;
      final site = _siteForKey(key);
      if (site != null) result.add(site);
    }
    return result;
  }

  static Site? _siteForKey(String key) {
    if (key.startsWith('custom_')) {
      return CustomSourceService.instance.siteForSource(
        key.substring('custom_'.length),
      );
    }
    if (key.startsWith('fnos_')) {
      return FnOsService.instance.siteForServer(
        key.substring('fnos_'.length),
      );
    }
    return allSites[key];
  }
}

class Site {
  final String id;
  final String name;
  final String logo;
  final LiveSite liveSite;
  Site({
    required this.id,
    required this.liveSite,
    required this.logo,
    required this.name,
  });
}

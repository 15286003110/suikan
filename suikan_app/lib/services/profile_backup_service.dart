import 'dart:convert';
import 'dart:io';

import 'package:get/get.dart';
import 'package:simple_live_app/app/constant.dart';
import 'package:simple_live_app/app/controller/app_settings_controller.dart';
import 'package:simple_live_app/app/custom_source/custom_source_service.dart';
import 'package:simple_live_app/app/event_bus.dart';
import 'package:simple_live_app/app/fnos/fn_os_service.dart';
import 'package:simple_live_app/app/utils.dart';
import 'package:simple_live_app/services/bulk_data_import_service.dart';
import 'package:simple_live_app/services/bilibili_account_service.dart';
import 'package:simple_live_app/services/db_service.dart';
import 'package:simple_live_app/services/douyin_account_service.dart';
import 'package:simple_live_app/services/follow_service.dart';
import 'package:simple_live_app/services/kuaishou_account_service.dart';
import 'package:simple_live_app/services/local_storage_service.dart';
import 'package:simple_live_core/simple_live_core.dart';

class ProfileBackupService extends GetxService {
  static ProfileBackupService get instance => Get.find<ProfileBackupService>();

  static const schema = "simple_live_profile";
  static const schemaVersion = 3;
  static const Set<int> _supportedSchemaVersions = {1, 2, 3};

  static const Set<String> _excludedSettings = {
    LocalStorageService.kFirstRun,
    LocalStorageService.kLastLiveRoom,
    LocalStorageService.kLastLiveRoomResumePending,
    LocalStorageService.kWebDAVUri,
    LocalStorageService.kWebDAVUser,
    LocalStorageService.kWebDAVPassword,
    LocalStorageService.kWebDAVLastUploadTime,
    LocalStorageService.kWebDAVLastRecoverTime,
  };

  Map<String, dynamic> exportProfileMap() {
    final shieldPayload = _exportShieldValues();
    final settingsPayload = _exportSettings();
    final followUsers = DBService.instance
        .getFollowList()
        .map((item) => item.toJson())
        .toList();
    final followUserTags = DBService.instance
        .getFollowTagList()
        .map((item) => item.toJson())
        .toList();
    final histories =
        DBService.instance.getHistores().map((item) => item.toJson()).toList();
    final customSources = _exportCustomSources();
    final fnosServers = _exportFnOsServers();
    return {
      "schema": schema,
      "schemaVersion": schemaVersion,
      "appVersion": Utils.packageInfo.version,
      "platform": Platform.operatingSystem,
      "exportedAt": DateTime.now().toIso8601String(),
      "settings": settingsPayload,
      "accounts": _exportAccounts(),
      "danmuShield": shieldPayload,
      "shieldPresets": _exportShieldPresets(),
      "followUsers": followUsers,
      "followUserTags": followUserTags,
      "histories": histories,
      "customSources": customSources,
      "fnosServers": fnosServers,
      "summary": {
        "settingCount": settingsPayload.length,
        "keywordShieldCount": (shieldPayload["keywords"] as List).length,
        "userShieldCount": (shieldPayload["users"] as List).length,
        "followUserCount": followUsers.length,
        "followTagCount": followUserTags.length,
        "historyCount": histories.length,
        "accountCount": (_exportAccounts()["items"] as List).length,
        "customSourceCount": customSources.length,
        "fnosServerCount": fnosServers.length,
      },
    };
  }

  /// 导出自定义直播源（M3uSource 的 JSON 字符串）。
  List<Map<String, dynamic>> _exportCustomSources() {
    final box = DBService.instance.customSourceBox;
    final result = <Map<String, dynamic>>[];
    for (final key in box.keys) {
      final raw = box.get(key);
      if (raw == null) continue;
      try {
        final map = json.decode(raw) as Map<String, dynamic>;
        result.add(map);
      } catch (_) {}
    }
    return result;
  }

  /// 导出飞牛影视服务器（含地址/用户名/密码，用于换机/备份恢复）。
  List<Map<String, dynamic>> _exportFnOsServers() {
    final box = DBService.instance.fnOsBox;
    final result = <Map<String, dynamic>>[];
    for (final key in box.keys) {
      final raw = box.get(key);
      if (raw == null) continue;
      try {
        final map = json.decode(raw) as Map<String, dynamic>;
        result.add(map);
      } catch (_) {}
    }
    return result;
  }

  String exportProfileJson() {
    return const JsonEncoder.withIndent("  ").convert(exportProfileMap());
  }

  Future<ProfileImportSummary> importProfileJson(
    String content, {
    bool overwrite = false,
    ProfileImportOptions options = const ProfileImportOptions(),
    SyncProgressCallback? onProgress,
  }) async {
    onProgress?.call(const SyncProgress(stage: "解析配置包"));
    final decoded = jsonDecode(content);
    if (decoded is! Map) {
      throw const FormatException("不是随看配置包");
    }
    final payload = decoded.cast<String, dynamic>();
    final schemaName = payload["schema"]?.toString() ?? "";
    final version = (payload["schemaVersion"] as num?)?.toInt() ?? 1;
    if (schemaName == schema || schemaName == "simple_live_profile") {
      if (!_supportedSchemaVersions.contains(version)) {
        throw const FormatException("暂不支持该配置包版本");
      }
      return importProfileMap(
        payload,
        overwrite: overwrite,
        options: options,
        onProgress: onProgress,
      );
    }
    if (payload["type"] == "simple_live") {
      return importLegacyProfileMap(
        payload,
        overwrite: overwrite,
        options: options,
        onProgress: onProgress,
      );
    }
    if (_looksLikeLegacyDataFile(payload)) {
      return importLegacyDataFileMap(
        payload,
        overwrite: overwrite,
        options: options,
        onProgress: onProgress,
      );
    }
    throw const FormatException("不是随看配置包");
  }

  Future<ProfileImportSummary> importLegacyProfileMap(
    Map<String, dynamic> payload, {
    bool overwrite = false,
    ProfileImportOptions options = const ProfileImportOptions(),
    SyncProgressCallback? onProgress,
  }) async {
    final summary = ProfileImportSummary();
    if (options.settings) {
      onProgress?.call(const SyncProgress(stage: "导入设置"));
      await _importSettings(payload["config"], summary, overwrite);
    }
    if (options.shields) {
      await _importShields(
        {"raw": _legacyShieldValues(payload["shield"])},
        summary,
        overwrite,
        onProgress,
      );
    }

    if (options.settings || options.shields || options.shieldPresets) {
      AppSettingsController.instance.reloadFromStorage();
    }
    EventBus.instance.emit(Constant.kUpdateFollow, 0);
    EventBus.instance.emit(Constant.kUpdateHistory, 0);
    // 配置导入后强制落盘（同 TV 端：防覆盖安装强杀导致半写帧损坏、关注列表丢失）。
    await DBService.instance.flushAll();
    return summary;
  }

  bool isSupportedProfileMap(dynamic payload) {
    if (payload is! Map) {
      return false;
    }
    final schemaName = payload["schema"]?.toString() ?? "";
    final version = (payload["schemaVersion"] as num?)?.toInt() ?? 1;
    return (schemaName == schema || schemaName == "simple_live_profile") &&
            _supportedSchemaVersions.contains(version) ||
        payload["type"] == "simple_live" ||
        _looksLikeLegacyDataFile(payload);
  }

  bool _looksLikeLegacyDataFile(dynamic payload) {
    if (payload is! Map) {
      return false;
    }
    if (payload["data"] is List) {
      return true;
    }
    const keys = {
      "followUsers",
      "follows",
      "favorites",
      "followUserTags",
      "tags",
      "histories",
      "history",
    };
    return keys.any((key) {
      final value = payload[key];
      return value is List || (value is Map && value["data"] is List);
    });
  }

  Future<ProfileImportSummary> importLegacyDataFileMap(
    Map<String, dynamic> payload, {
    bool overwrite = false,
    ProfileImportOptions options = const ProfileImportOptions(),
    SyncProgressCallback? onProgress,
  }) async {
    final summary = ProfileImportSummary();
    if (payload["data"] is List) {
      await _importLegacyDataList(
        payload["data"],
        summary,
        overwrite,
        options,
        onProgress,
      );
    } else {
      if (options.follows) {
        await _importFollowUsers(
            _readPayloadList(payload, [
              "followUsers",
              "follows",
              "favorites",
            ]),
            summary,
            overwrite,
            onProgress);
        await _importFollowTags(
            _readPayloadList(payload, [
              "followUserTags",
              "tags",
            ]),
            summary,
            overwrite,
            onProgress);
      }
      if (options.histories) {
        await _importHistories(
            _readPayloadList(payload, [
              "histories",
              "history",
            ]),
            summary,
            overwrite,
            onProgress);
      }
    }

    if (options.follows) {
      await FollowService.instance.loadData(updateStatus: false);
    }
    EventBus.instance.emit(Constant.kUpdateFollow, 0);
    EventBus.instance.emit(Constant.kUpdateHistory, 0);
    // 配置导入后强制落盘（同 TV 端：防覆盖安装强杀导致半写帧损坏、关注列表丢失）。
    await DBService.instance.flushAll();
    return summary;
  }

  List<String> _legacyShieldValues(dynamic rawShield) {
    if (rawShield is! Map) {
      return const [];
    }
    return rawShield.values
        .map((e) => e.toString().trim())
        .where((e) => e.isNotEmpty)
        .toSet()
        .toList()
      ..sort();
  }

  Future<ProfileImportSummary> importProfileMap(
    Map<String, dynamic> payload, {
    bool overwrite = false,
    ProfileImportOptions options = const ProfileImportOptions(),
    SyncProgressCallback? onProgress,
  }) async {
    final summary = ProfileImportSummary();
    if (options.settings) {
      onProgress?.call(const SyncProgress(stage: "导入设置"));
      await _importSettings(payload["settings"], summary, overwrite);
    }
    if (options.shields) {
      await _importShields(
        payload["danmuShield"],
        summary,
        overwrite,
        onProgress,
      );
    }
    await _importAccounts(payload["accounts"]);
    if (options.shieldPresets) {
      onProgress?.call(const SyncProgress(stage: "导入屏蔽预设"));
      await _importShieldPresets(
        payload["shieldPresets"],
        summary,
        overwrite,
      );
    }
    if (options.follows) {
      await _importFollowUsers(
          _readPayloadList(payload, [
            "followUsers",
            "follows",
            "favorites",
          ]),
          summary,
          overwrite,
          onProgress);
      await _importFollowTags(
          _readPayloadList(payload, [
            "followUserTags",
            "tags",
          ]),
          summary,
          overwrite,
          onProgress);
    }
    if (options.histories) {
      await _importHistories(
          _readPayloadList(payload, [
            "histories",
            "history",
          ]),
          summary,
          overwrite,
          onProgress);
    }

    // 自定义直播源与飞牛影视服务器（支持所有平台，独立于上面的开关）。
    await _importCustomSources(payload["customSources"], overwrite, summary);
    await _importFnOsServers(payload["fnosServers"], overwrite, summary);

    if (options.settings || options.shields || options.shieldPresets) {
      AppSettingsController.instance.reloadFromStorage();
    }
    if (options.follows) {
      await FollowService.instance.loadData(updateStatus: false);
    }
    EventBus.instance.emit(Constant.kUpdateFollow, 0);
    EventBus.instance.emit(Constant.kUpdateHistory, 0);
    // 配置导入后强制落盘（同 TV 端：防覆盖安装强杀导致半写帧损坏、关注列表丢失）。
    await DBService.instance.flushAll();
    return summary;
  }

  Map<String, dynamic> _exportSettings() {
    final result = <String, dynamic>{};
    for (final entry
        in LocalStorageService.instance.settingsBox.toMap().entries) {
      final key = entry.key.toString();
      if (_excludedSettings.contains(key)) {
        continue;
      }
      result[key] = _safeJsonValue(entry.value);
    }
    return result;
  }

  Map<String, dynamic> _exportAccounts() {
    return {
      "items": [
        {
          "siteId": Constant.kBiliBili,
          "cookie": LocalStorageService.instance.getValue(
            LocalStorageService.kBilibiliCookie,
            "",
          ),
        },
        {
          "siteId": Constant.kDouyin,
          "cookie": LocalStorageService.instance.getValue(
            LocalStorageService.kDouyinCookie,
            "",
          ),
        },
        {
          "siteId": Constant.kKuaishou,
          "cookie": LocalStorageService.instance.getValue(
            LocalStorageService.kKuaishouCookie,
            "",
          ),
          "kww": LocalStorageService.instance.getValue(
            LocalStorageService.kKuaishouKww,
            "",
          ),
          "cookieExpiresAt": LocalStorageService.instance.getValue(
            LocalStorageService.kKuaishouCookieExpiresAt,
            0,
          ),
        },
      ],
    };
  }

  Map<String, dynamic> _exportShieldValues() {
    final raw = LocalStorageService.instance.shieldBox.values
        .map((e) => e.toString().trim())
        .where((e) => e.isNotEmpty)
        .toList()
      ..sort();
    final keywords = AppSettingsControllerSafe.keywordValues()..sort();
    final userGroups = AppSettingsControllerSafe.userGroups();
    final users = userGroups.values.expand((e) => e).toSet().toList()..sort();
    return {
      "raw": raw,
      "keywords": keywords,
      "users": users,
      "userGroups": userGroups,
    };
  }

  List<Map<String, dynamic>> _exportShieldPresets() {
    final result = <Map<String, dynamic>>[];
    for (final entry
        in LocalStorageService.instance.shieldPresetBox.toMap().entries) {
      dynamic value = entry.value;
      try {
        value = jsonDecode(entry.value.toString());
      } catch (_) {}
      result.add({
        "name": entry.key.toString(),
        "value": _safeJsonValue(value),
      });
    }
    result.sort((a, b) => a["name"].toString().compareTo(b["name"].toString()));
    return result;
  }

  Future<void> _importSettings(
    dynamic rawSettings,
    ProfileImportSummary summary,
    bool overwrite,
  ) async {
    if (rawSettings is! Map) {
      return;
    }
    if (overwrite) {
      // 🔴 只清「配置包里出现的 key」，绝不碰对方端特有的设置。
      // 手机端 121 个设置 key、TV 端 77 个，差异巨大（投屏接收开关
      // kDlnaReceiverEnable 等只在 TV 端存在）。旧逻辑清空整个 settingsBox，
      // 手机包覆盖导入 TV 会把 TV 特有设置全删回默认，反向同理
      // （2026-08-31 排查确认）。
      await _clearImportableSettings(rawSettings);
    }
    final values = <dynamic, dynamic>{};
    for (final entry in rawSettings.entries) {
      final key = entry.key.toString();
      if (_excludedSettings.contains(key)) {
        continue;
      }
      values[key] = entry.value;
    }
    await LocalStorageService.instance.settingsBox.putAll(values);
    summary.settings = values.length;
  }

  Future<void> _clearImportableSettings(dynamic rawSettings) async {
    if (rawSettings is! Map) return;
    // 只删配置包里有的 key —— 它们反正马上要被 putAll 覆盖；
    // 配置包里没有的 key（对方端特有）原样保留，不再误删。
    final keys = LocalStorageService.instance.settingsBox.keys
        .where((key) => rawSettings.containsKey(key.toString()))
        .toList();
    if (keys.isNotEmpty) {
      await LocalStorageService.instance.settingsBox.deleteAll(keys);
    }
  }

  Future<void> _importShields(
    dynamic rawShield,
    ProfileImportSummary summary,
    bool overwrite,
    SyncProgressCallback? onProgress,
  ) async {
    // 仅当包里确实带屏蔽词才清空本机（raw 或 keywords 任一非空），
    // 防止"清空后无内容回填"导致本机屏蔽词被同步清掉。
    final rawValuesList =
        rawShield is Map && rawShield["raw"] is List ? rawShield["raw"] as List : null;
    final keywordsList = rawShield is Map && rawShield["keywords"] is List
        ? rawShield["keywords"] as List
        : null;
    final hasShieldData =
        (rawValuesList?.isNotEmpty ?? false) || (keywordsList?.isNotEmpty ?? false);
    if (overwrite && hasShieldData) {
      await AppSettingsControllerSafe.clearShieldValues();
    }
    if (rawShield is Map) {
      final rawValues = rawShield["raw"];
      if (rawValues is List && rawValues.isNotEmpty) {
        final result = await BulkDataImportService.importShieldValues(
          rawValues,
          overwrite: false,
          onProgress: onProgress,
        );
        summary.shields += result.imported;
        summary.skipped += result.skipped;
        return;
      }
      final keywords = rawShield["keywords"];
      if (keywords is List) {
        for (final keyword in keywords) {
          AppSettingsControllerSafe.addKeyword(keyword.toString());
          summary.shields++;
        }
      }
      final groups = rawShield["userGroups"];
      if (groups is Map) {
        for (final entry in groups.entries) {
          final users = entry.value;
          if (users is! List) {
            continue;
          }
          for (final user in users) {
            AppSettingsControllerSafe.addUser(
              user.toString(),
              siteId: entry.key.toString(),
            );
            summary.shields++;
          }
        }
      }
    }
  }

  Future<void> _importShieldPresets(
    dynamic rawPresets,
    ProfileImportSummary summary,
    bool overwrite,
  ) async {
    // 空数据/非数组都不动本机：避免"先清空却发现没有可导入的内容"。
    if (rawPresets is! List || rawPresets.isEmpty) {
      return;
    }
    if (overwrite) {
      await LocalStorageService.instance.shieldPresetBox.clear();
    }
    for (final item in rawPresets) {
      if (item is! Map) {
        continue;
      }
      final name = item["name"]?.toString().trim() ?? "";
      if (name.isEmpty) {
        continue;
      }
      final value = item["value"];
      await LocalStorageService.instance.shieldPresetBox.put(
        name,
        value is String ? value : jsonEncode(value),
      );
      summary.shieldPresets++;
    }
    AppSettingsControllerSafe.reloadShields();
  }

  Future<void> _importAccounts(dynamic rawAccounts) async {
    if (rawAccounts is! Map) {
      return;
    }
    final items = rawAccounts["items"];
    if (items is! List) {
      return;
    }
    for (final item in items) {
      if (item is! Map) {
        continue;
      }
      final siteId = item["siteId"]?.toString() ?? "";
      final cookie = item["cookie"]?.toString() ?? "";
      switch (siteId) {
        case Constant.kBiliBili:
          BiliBiliAccountService.instance.setCookie(cookie);
          break;
        case Constant.kDouyin:
          if (cookie.isEmpty) {
            DouyinAccountService.instance.clearCookie();
          } else {
            DouyinAccountService.instance.setCookie(cookie);
          }
          break;
        case Constant.kKuaishou:
          final kww = item["kww"]?.toString() ?? "";
          final expiresAtMs = (item["cookieExpiresAt"] as num?)?.toInt() ?? 0;
          if (cookie.isEmpty) {
            KuaishouAccountService.instance.clearCookie();
          } else {
            KuaishouAccountService.instance.setCookie(
              cookie,
              kww: kww.isEmpty ? null : kww,
              expiresAt: expiresAtMs > 0
                  ? DateTime.fromMillisecondsSinceEpoch(expiresAtMs)
                  : null,
            );
          }
          break;
      }
    }
  }

  Future<void> _importFollowUsers(
    dynamic rawUsers,
    ProfileImportSummary summary,
    bool overwrite,
    SyncProgressCallback? onProgress,
  ) async {
    final result = await BulkDataImportService.importFollowUsers(
      rawUsers,
      overwrite: overwrite,
      onProgress: onProgress,
    );
    summary.followUsers += result.imported;
    summary.skipped += result.skipped;
  }

  Future<void> _importFollowTags(
    dynamic rawTags,
    ProfileImportSummary summary,
    bool overwrite,
    SyncProgressCallback? onProgress,
  ) async {
    final result = await BulkDataImportService.importFollowTags(
      rawTags,
      overwrite: overwrite,
      onProgress: onProgress,
    );
    summary.followTags += result.imported;
    summary.skipped += result.skipped;
  }

  Future<void> _importHistories(
    dynamic rawHistories,
    ProfileImportSummary summary,
    bool overwrite,
    SyncProgressCallback? onProgress,
  ) async {
    final result = await BulkDataImportService.importHistories(
      rawHistories,
      overwrite: overwrite,
      onProgress: onProgress,
    );
    summary.histories += result.imported;
    summary.skipped += result.skipped;
  }

  Future<void> _importCustomSources(
    dynamic raw,
    bool overwrite,
    ProfileImportSummary summary,
  ) async {
    if (raw is! List || raw.isEmpty) return;
    final box = DBService.instance.customSourceBox;
    await DBService.runExclusive(() async {
      if (overwrite) {
        await box.clear();
      }
      for (final item in raw) {
        if (item is! Map) continue;
        final id = (item["id"] as String?) ?? '';
        if (id.isEmpty) continue;
        if (!overwrite && box.containsKey(id)) {
          summary.skipped++;
          continue;
        }
        await box.put(id, json.encode(item));
        summary.customSources++;
      }
    });
    // 重新加载服务并通知首页/分类重建标签。
    await CustomSourceService.instance.init();
    EventBus.instance.emit(EventBus.kCustomSourcesChanged, null);
  }

  Future<void> _importFnOsServers(
    dynamic raw,
    bool overwrite,
    ProfileImportSummary summary,
  ) async {
    if (raw is! List || raw.isEmpty) return;
    final box = DBService.instance.fnOsBox;
    await DBService.runExclusive(() async {
      if (overwrite) {
        await box.clear();
      }
      for (final item in raw) {
        if (item is! Map) continue;
        final id = (item["id"] as String?) ?? '';
        if (id.isEmpty) continue;
        if (!overwrite && box.containsKey(id)) {
          summary.skipped++;
          continue;
        }
        await box.put(id, json.encode(item));
        summary.fnosServers++;
      }
    });
    await FnOsService.instance.init();
    EventBus.instance.emit(EventBus.kCustomSourcesChanged, null);
  }

  dynamic _readPayloadList(Map<String, dynamic> payload, List<String> keys) {
    for (final key in keys) {
      final value = payload[key];
      if (value is List) {
        return value;
      }
      if (value is Map && value["data"] is List) {
        return value["data"];
      }
    }
    return null;
  }

  /// 只读预览配置包：解析出各类数据的条数，**不写入任何数据**。
  ///
  /// 存在的理由（2026-08-31）：导入的确认框原本在**选文件之前**就弹了，
  /// 用户回答"要不要覆盖"时根本不知道包里有多少条。于是有人拿着一份旧的
  /// 51 条备份，覆盖掉了本机两百来条较新的关注 —— 覆盖是按预期执行的，
  /// 但用户完全不知情，反馈就是"导入配置文件后关注列表丢失"。
  /// 改成先选文件 → 预览条数 → 再问覆盖，让代价看得见。
  ProfilePreview previewProfile(String jsonContent) {
    try {
      final decoded = json.decode(jsonContent);
      if (decoded is! Map) return const ProfilePreview();
      final raw = decoded["data"] ?? decoded;
      if (raw is! Map) return const ProfilePreview();
      final payload = Map<String, dynamic>.from(raw);

      int countOf(List<String> keys) {
        final v = _readPayloadList(payload, keys);
        return v is List ? v.length : 0;
      }

      var follows = countOf(["followUsers", "follows", "favorites"]);
      var tags = countOf(["followUserTags", "tags"]);
      var histories = countOf(["histories", "history"]);

      // 旧格式：整个 data 就是一个 List，只能按首项字段判断它属于哪一类
      final legacy = payload["data"];
      if (legacy is List && legacy.isNotEmpty) {
        final first = legacy.whereType<Map>().firstOrNull;
        if (first != null) {
          if (first.containsKey("roomId") || first.containsKey("siteId")) {
            follows = legacy.length;
          } else if (first.containsKey("userId") || first.containsKey("tag")) {
            tags = legacy.length;
          } else if (first.containsKey("updateTime")) {
            histories = legacy.length;
          }
        }
      }
      return ProfilePreview(
        follows: follows,
        tags: tags,
        histories: histories,
      );
    } catch (_) {
      // 解析不了就当空包，导入流程自身的错误处理会兜底
      return const ProfilePreview();
    }
  }

  /// 生成导入确认文案：把「本机 N 条 vs 配置包 M 条」讲清楚，让覆盖的代价可见。
  /// 放在 service 里供两个导入入口（设置-其他、同步-配置包）共用，
  /// 免得两处文案各写一份、日后走样。
  String buildImportPrompt(ProfilePreview p) {
    final local = DBService.instance.followBox.length;
    final buf = StringBuffer();
    buf.write("配置包内容：关注 ${p.follows} 条、标签 ${p.tags} 条、"
        "观看记录 ${p.histories} 条。");
    if (local > p.follows) {
      buf.write("\n\n本机现有关注 $local 条，比配置包多 ${local - p.follows} 条。");
      buf.write("\n选「覆盖」后本机将只剩这 ${p.follows} 条，多出来的会被删除。");
      buf.write("\n如果只是想找回丢失的关注，请选「不覆盖」合并导入。");
    } else {
      buf.write("\n\n选「覆盖」会用配置包内容替换本机同类数据；"
          "选「不覆盖」则合并导入、保留本机已有数据。");
    }
    return buf.toString();
  }

  Future<void> _importLegacyDataList(
    dynamic rawList,
    ProfileImportSummary summary,
    bool overwrite,
    ProfileImportOptions options,
    SyncProgressCallback? onProgress,
  ) async {
    if (rawList is! List || rawList.isEmpty) {
      return;
    }
    final firstMap = rawList.whereType<Map>().firstOrNull;
    if (firstMap != null) {
      if (firstMap.containsKey("userId") || firstMap.containsKey("tag")) {
        if (options.follows) {
          await _importFollowTags(rawList, summary, overwrite, onProgress);
        }
        return;
      }
      if (firstMap.containsKey("updateTime")) {
        if (options.histories) {
          await _importHistories(rawList, summary, overwrite, onProgress);
        }
        return;
      }
      if (firstMap.containsKey("roomId") || firstMap.containsKey("siteId")) {
        if (options.follows) {
          await _importFollowUsers(rawList, summary, overwrite, onProgress);
        }
        return;
      }
    }
    if (options.shields && rawList.every((item) => item is String)) {
      await _importShields({"raw": rawList}, summary, overwrite, onProgress);
    }
  }

  dynamic _safeJsonValue(dynamic value) {
    if (value == null || value is String || value is num || value is bool) {
      return value;
    }
    if (value is DateTime) {
      return value.toIso8601String();
    }
    if (value is Iterable) {
      return value.map(_safeJsonValue).toList();
    }
    if (value is Map) {
      return {
        for (final entry in value.entries)
          entry.key.toString(): _safeJsonValue(entry.value),
      };
    }
    return value.toString();
  }
}

class ProfileImportOptions {
  final bool settings;
  final bool shields;
  final bool shieldPresets;
  final bool follows;
  final bool histories;

  const ProfileImportOptions({
    this.settings = true,
    this.shields = true,
    this.shieldPresets = true,
    this.follows = true,
    this.histories = true,
  });
}

/// 配置包的**只读预览**：各类数据的条数，不含内容本身。
class ProfilePreview {
  final int follows;
  final int tags;
  final int histories;

  const ProfilePreview({
    this.follows = 0,
    this.tags = 0,
    this.histories = 0,
  });
}

class ProfileImportSummary {
  int settings = 0;
  int shields = 0;
  int shieldPresets = 0;
  int followUsers = 0;
  int followTags = 0;
  int histories = 0;
  int customSources = 0;
  int fnosServers = 0;
  int skipped = 0;

  String get message {
    final base =
        "设置 $settings 项，屏蔽 $shields 项，预设 $shieldPresets 个，关注 $followUsers 个，标签 $followTags 个，历史 $histories 条";
    final extra = customSources > 0 || fnosServers > 0
        ? "，直播源 $customSources 个，影视库 $fnosServers 个"
        : "";
    return skipped > 0 ? "$base$extra，跳过异常 $skipped 条" : "$base$extra";
  }
}

class AppSettingsControllerSafe {
  static List<String> keywordValues() {
    return AppSettingsController.instance.shieldList.toList();
  }

  static Map<String, List<String>> userGroups() {
    return AppSettingsController.instance.getUserShieldGroupSnapshot();
  }

  static void importShieldValue(String value) {
    AppSettingsController.instance.importShieldValue(value);
  }

  static void addKeyword(String value) {
    AppSettingsController.instance.addShieldList(value);
  }

  static void addUser(String value, {String? siteId}) {
    AppSettingsController.instance.addUserShieldList(value, siteId: siteId);
  }

  static Future<void> clearShieldValues() {
    return AppSettingsController.instance.clearShieldList();
  }

  static void reloadShields() {
    AppSettingsController.instance.refreshShieldData();
  }
}

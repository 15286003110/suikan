import 'dart:io';

import 'package:flutter/widgets.dart';

class DesktopStartupArgs {
  static const secondaryInstanceArg = "--suikan-secondary-instance";
  static const secondaryInstanceEnv = "SIMPLE_LIVE_SECONDARY_INSTANCE";
  static const openSiteArg = "--suikan-open-site";
  static const openRoomArg = "--suikan-open-room";
  static const windowLeftArg = "--suikan-window-left";
  static const windowTopArg = "--suikan-window-top";
  static const windowWidthArg = "--suikan-window-width";
  static const windowHeightArg = "--suikan-window-height";
  static const collapseChatArg = "--suikan-collapse-chat";
  static const framelessTileArg = "--suikan-frameless-tile";

  static List<String> _args = const [];

  static void initialize(List<String> args) {
    _args = List.unmodifiable(args);
  }

  static bool get isSecondaryDesktopInstance {
    if (!(Platform.isWindows || Platform.isMacOS)) {
      return false;
    }
    return _args.contains(secondaryInstanceArg) ||
        Platform.environment[secondaryInstanceEnv] == "1";
  }

  static Map<String, String>? get startupRoom {
    final siteId = _argValue(openSiteArg)?.trim();
    final roomId = _argValue(openRoomArg)?.trim();
    if (siteId == null || siteId.isEmpty || roomId == null || roomId.isEmpty) {
      return null;
    }
    return {
      "siteId": siteId,
      "roomId": roomId,
    };
  }

  static Rect? get startupWindowBounds {
    final left = double.tryParse(_argValue(windowLeftArg) ?? "");
    final top = double.tryParse(_argValue(windowTopArg) ?? "");
    final width = double.tryParse(_argValue(windowWidthArg) ?? "");
    final height = double.tryParse(_argValue(windowHeightArg) ?? "");
    if (left == null || top == null || width == null || height == null) {
      return null;
    }
    if (width < 280 || height < 280) {
      return null;
    }
    return Rect.fromLTWH(left, top, width, height);
  }

  static bool get startupCollapseChat => _args.contains(collapseChatArg);

  static bool get startupFramelessTile => _args.contains(framelessTileArg);

  static String? _argValue(String key) {
    for (var i = 0; i < _args.length; i += 1) {
      final arg = _args[i];
      if (arg == key && i + 1 < _args.length) {
        return _args[i + 1];
      }
      final prefix = "$key=";
      if (arg.startsWith(prefix)) {
        return arg.substring(prefix.length);
      }
    }
    return null;
  }
}

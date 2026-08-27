import 'm3u_models.dart';

/// 解析 M3U / M3U8 直播源文本为频道列表。
/// 支持 #EXTINF 的 tvg-id / tvg-logo / group-title 属性，
/// 以及 #EXTGRP 分组写法；自动去重，未分组归入「未分组」。
List<M3uChannel> parseM3u(String content) {
  final lines = content.split(RegExp(r'\r\n|\n|\r'));
  final channels = <M3uChannel>[];
  final seen = <String>{};
  String? pendingGroup;

  final urlReg = RegExp(r'^(https?://|rtmp://|rtsp://|rtmp\d?://)');
  final tvgIdRe = RegExp(r'tvg-id="([^"]*)"');
  final logoRe = RegExp(r'tvg-logo="([^"]*)"');
  final groupRe = RegExp(r'group-title="([^"]*)"');

  for (int i = 0; i < lines.length; i++) {
    final line = lines[i].trim();
    if (line.isEmpty) continue;
    if (line.startsWith('#EXTM3U')) continue;

    if (line.startsWith('#EXTGRP:')) {
      pendingGroup = line.substring(8).trim();
      continue;
    }

    if (line.startsWith('#EXTINF')) {
      String? name;
      String? logo;
      String? group;
      String? tvgId;

      final tvgIdM = tvgIdRe.firstMatch(line);
      if (tvgIdM != null) tvgId = tvgIdM.group(1);
      final logoM = logoRe.firstMatch(line);
      if (logoM != null) logo = logoM.group(1);
      final groupM = groupRe.firstMatch(line);
      if (groupM != null) group = groupM.group(1);

      final idx = line.lastIndexOf(',');
      if (idx >= 0 && idx + 1 < line.length) {
        name = line.substring(idx + 1).trim();
      }

      // 寻找紧随其后的非注释 URL 行
      String? url;
      for (int j = i + 1; j < lines.length; j++) {
        final l = lines[j].trim();
        if (l.isEmpty) continue;
        if (l.startsWith('#')) {
          if (l.startsWith('#EXTGRP:')) {
            pendingGroup ??= l.substring(8).trim();
          }
          continue;
        }
        url = l;
        i = j;
        break;
      }

      if (url != null && urlReg.hasMatch(url) && !seen.contains(url)) {
        seen.add(url);
        final finalGroup =
            (group ?? pendingGroup ?? '未分组').trim().isEmpty
                ? '未分组'
                : (group ?? pendingGroup ?? '未分组').trim();
        final finalName = (name ?? '').isEmpty ? url : name!;
        channels.add(M3uChannel(
          name: finalName,
          url: url,
          logo: logo,
          group: finalGroup,
          tvgId: tvgId,
        ));
      }
      pendingGroup = null;
      continue;
    }

    // 独立 URL 行（无 EXTINF）按分组归入，避免遗漏
    if (urlReg.hasMatch(line) && !seen.contains(line)) {
      seen.add(line);
      final g = (pendingGroup ?? '未分组').trim().isEmpty
          ? '未分组'
          : (pendingGroup ?? '未分组').trim();
      channels.add(M3uChannel(name: line, url: line, group: g));
      pendingGroup = null;
    }
  }

  return channels;
}

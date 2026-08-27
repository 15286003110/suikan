import 'package:flutter/material.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';
import 'package:simple_live_app/app/custom_source/custom_source_service.dart';
import 'package:simple_live_app/app/custom_source/m3u_models.dart';
import 'package:simple_live_app/widgets/status/app_empty_widget.dart';

import 'custom_source_group_page.dart';

class CustomSourceListPage extends StatelessWidget {
  const CustomSourceListPage({Key? key}) : super(key: key);

  String _formatTime(int? ts) {
    if (ts == null) return '未更新';
    final d = DateTime.fromMillisecondsSinceEpoch(ts);
    String p(int n) => n.toString().padLeft(2, '0');
    return '${d.year}-${p(d.month)}-${p(d.day)} ${p(d.hour)}:${p(d.minute)}';
  }

  Future<void> _showAddDialog(BuildContext context) async {
    final nameCtl = TextEditingController();
    final urlCtl = TextEditingController();
    final result = await Get.dialog<bool>(
      AlertDialog(
        title: const Text('添加直播源'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: nameCtl,
              decoration: const InputDecoration(
                labelText: '名称（选填）',
                hintText: '例如：我的IPTV',
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: urlCtl,
              decoration: const InputDecoration(
                labelText: 'M3U 地址',
                hintText: 'http://.../xxx.m3u',
              ),
              keyboardType: TextInputType.url,
              autocorrect: false,
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Get.back(result: false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Get.back(result: true),
            child: const Text('添加'),
          ),
        ],
      ),
    );
    if (result != true) return;
    final url = urlCtl.text.trim();
    if (url.isEmpty) {
      SmartDialog.showToast('请填写 M3U 地址');
      return;
    }
    final name = nameCtl.text.trim().isEmpty ? url : nameCtl.text.trim();
    SmartDialog.showLoading(msg: '正在拉取直播源…');
    try {
      await CustomSourceService.instance.addSource(name: name, url: url);
      SmartDialog.dismiss();
      SmartDialog.showToast('添加成功');
    } catch (e) {
      SmartDialog.dismiss();
      SmartDialog.showToast('拉取失败：$e');
    }
  }

  Future<void> _refresh(M3uSource src) async {
    SmartDialog.showLoading(msg: '正在刷新…');
    try {
      await CustomSourceService.instance.refreshSource(src.id);
      SmartDialog.dismiss();
      SmartDialog.showToast('已刷新');
    } catch (e) {
      SmartDialog.dismiss();
      SmartDialog.showToast('刷新失败：$e');
    }
  }

  Future<void> _remove(M3uSource src) async {
    final ok = await Get.dialog<bool>(
      AlertDialog(
        title: const Text('删除直播源'),
        content: Text('确定删除「${src.name}」？'),
        actions: [
          TextButton(
            onPressed: () => Get.back(result: false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Get.back(result: true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (ok == true) {
      await CustomSourceService.instance.removeSource(src.id);
      SmartDialog.showToast('已删除');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('自定义直播源')),
      floatingActionButton: FloatingActionButton(
        onPressed: () => _showAddDialog(context),
        tooltip: '添加直播源',
        child: const Icon(Icons.add),
      ),
      body: Obx(
        () {
          final list = CustomSourceService.instance.sources;
          if (list.isEmpty) {
            return AppEmptyWidget(
              message: '还没有自定义直播源\n点击右下角添加 M3U 地址',
              onRefresh: () async {},
            );
          }
          return ListView.separated(
            padding: const EdgeInsets.all(12),
            itemCount: list.length,
            separatorBuilder: (_, __) => const Divider(height: 1),
            itemBuilder: (_, i) {
              final src = list[i];
              return ListTile(
                contentPadding:
                    const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                leading: const Icon(Icons.playlist_play),
                title: Text(src.name.isEmpty ? src.url : src.name),
                subtitle: Text(
                  '${src.groupCountText}\n更新于 ${_formatTime(src.lastUpdated)}',
                ),
                isThreeLine: true,
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    IconButton(
                      icon: const Icon(Icons.refresh),
                      tooltip: '刷新',
                      onPressed: () => _refresh(src),
                    ),
                    IconButton(
                      icon: const Icon(Icons.delete_outline),
                      tooltip: '删除',
                      onPressed: () => _remove(src),
                    ),
                  ],
                ),
                onTap: () => Get.to(() => CustomSourceGroupPage(source: src)),
              );
            },
          );
        },
      ),
    );
  }
}

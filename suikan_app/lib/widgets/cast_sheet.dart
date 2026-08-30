import 'package:flutter/material.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:simple_live_app/app/dlna/dlna_cast_service.dart';
import 'package:simple_live_app/app/utils.dart';

class CastSheet extends StatefulWidget {
  final String url;
  final Map<String, String>? headers;
  final String title;

  const CastSheet({
    super.key,
    required this.url,
    this.headers,
    required this.title,
  });

  @override
  State<CastSheet> createState() => CastSheetState();
}

class CastSheetState extends State<CastSheet> {
  List<DlnaDevice> devices = [];
  bool loading = true;
  DlnaDevice? castingDevice;
  String? error;

  @override
  void initState() {
    super.initState();
    _discover();
  }

  Future<void> _discover() async {
    setState(() {
      loading = true;
      error = null;
    });
    try {
      await DlnaCastService.instance.acquireMulticastLock();
      final list = await DlnaCastService.instance.discover();
      if (mounted) {
        setState(() {
          devices = list;
          loading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          error = e.toString();
          loading = false;
        });
      }
    } finally {
      await DlnaCastService.instance.releaseMulticastLock();
    }
  }

  Future<void> _cast(DlnaDevice d) async {
    SmartDialog.showLoading(msg: "正在投屏…");
    try {
      await DlnaCastService.instance.cast(
        d,
        widget.url,
        headers: widget.headers,
        title: widget.title,
      );
      SmartDialog.dismiss();
      if (mounted) setState(() => castingDevice = d);
      SmartDialog.showToast("已投屏到 ${d.name}");
    } catch (e) {
      SmartDialog.dismiss();
      SmartDialog.showToast("投屏失败：$e");
    }
  }

  Future<void> _stop() async {
    final d = castingDevice;
    if (d == null) return;
    try {
      await DlnaCastService.instance.stop(d);
      SmartDialog.showToast("已停止投屏");
    } catch (e) {
      SmartDialog.showToast("停止失败：$e");
    } finally {
      if (mounted) setState(() => castingDevice = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Utils.bottomSheetSafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ListTile(
            leading: const Icon(Icons.cast),
            title: const Text("投屏到设备"),
            subtitle: castingDevice != null
                ? Text("正在投屏到 ${castingDevice!.name}")
                : null,
            trailing: IconButton(
              icon: const Icon(Icons.refresh),
              tooltip: "重新搜索",
              onPressed: _discover,
            ),
          ),
          const Divider(height: 1),
          if (castingDevice != null)
            ListTile(
              leading: const Icon(Icons.stop_circle_outlined),
              title: const Text("停止投屏"),
              onTap: _stop,
            ),
          if (loading)
            const Padding(
              padding: EdgeInsets.all(24),
              child: Center(child: CircularProgressIndicator()),
            )
          else if (error != null)
            Padding(
              padding: const EdgeInsets.all(16),
              child: Text(
                "搜索失败：$error",
                style: const TextStyle(color: Colors.grey),
              ),
            )
          else if (devices.isEmpty)
            const Padding(
              padding: EdgeInsets.all(24),
              child: Center(
                child: Text(
                  "未发现可用设备\n请确保手机/电脑与电视在同一局域网，且电视已开启投屏接收",
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Colors.grey),
                ),
              ),
            )
          else
            ListView.separated(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              padding: const EdgeInsets.only(bottom: 12),
              itemCount: devices.length,
              separatorBuilder: (_, __) => const Divider(height: 1),
              itemBuilder: (_, i) {
                final d = devices[i];
                final isCasting = castingDevice == d;
                return ListTile(
                  leading: const Icon(Icons.tv),
                  title: Text(d.name),
                  subtitle: d.location != null ? Text(d.location!) : null,
                  trailing: isCasting
                      ? const Chip(label: Text("投屏中"))
                      : const Icon(Icons.chevron_right),
                  onTap: isCasting ? null : () => _cast(d),
                );
              },
            ),
        ],
      ),
    );
  }
}

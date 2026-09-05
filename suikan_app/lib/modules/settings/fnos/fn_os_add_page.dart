import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';
import 'package:simple_live_app/app/custom_source/m3u_models.dart';
import 'package:simple_live_app/app/fnos/fn_os_models.dart';
import 'package:simple_live_app/app/fnos/fn_os_service.dart';

import 'fn_os_browse_page.dart';

/// 「添加/编辑飞牛影视」表单页。
/// UI：左侧标签 + 右侧输入，圆角灰底容器，底部说明 + 大按钮。
class FnOsAddPage extends StatefulWidget {
  final FnOsServer? editServer; // 为 null 表示新增
  const FnOsAddPage({Key? key, this.editServer}) : super(key: key);

  @override
  State<FnOsAddPage> createState() => _FnOsAddPageState();
}

class _FnOsAddPageState extends State<FnOsAddPage> {
  final nameCtl = TextEditingController();
  final addrCtl = TextEditingController();
  final portCtl = TextEditingController(text: '8005');
  final userCtl = TextEditingController();
  final pwdCtl = TextEditingController();
  final intervalCtl = TextEditingController(text: '6');
  final hourCtl = TextEditingController(text: '4');

  String protocol = 'http';
  bool obscure = true;
  bool loading = false;

  bool autoRefresh = false;
  String refreshMode = kRefreshModeInterval;

  @override
  void initState() {
    super.initState();
    final s = widget.editServer;
    if (s != null) {
      nameCtl.text = s.name;
      userCtl.text = s.username;
      pwdCtl.text = s.password;
      autoRefresh = s.autoRefresh;
      refreshMode = s.refreshMode;
      intervalCtl.text = s.refreshIntervalHours.toString();
      hourCtl.text = s.refreshHour.toString();
      // 解析已存地址 http(s)://host:port
      final uri = Uri.tryParse(s.address);
      if (uri != null) {
        protocol = uri.scheme.isEmpty ? 'http' : uri.scheme;
        addrCtl.text = uri.host;
        portCtl.text = uri.port > 0 ? uri.port.toString() : '8005';
      }
    }
  }

  bool get canAdd =>
      addrCtl.text.trim().isNotEmpty && userCtl.text.trim().isNotEmpty;

  Future<void> _save() async {
    if (!canAdd) return;

    var address = addrCtl.text.trim();
    final username = userCtl.text.trim();
    final password = pwdCtl.text.trim();

    var port = portCtl.text.trim();
    if (port.isEmpty) port = '8005';
    final intPort = int.tryParse(port);
    if (intPort == null || intPort <= 0 || intPort > 65535) {
      SmartDialog.showToast('端口号不合法');
      return;
    }

    // 地址栏若误带协议或端口，组装前先剥离，避免拼出 http://http://...:8005。
    if (address.startsWith('https://')) {
      address = address.substring(8);
    } else if (address.startsWith('http://')) {
      address = address.substring(7);
    }
    address = address.replaceFirst(RegExp(r':\d+$'), '');

    final url = '$protocol://$address:$port';
    final name = nameCtl.text.trim();
    final interval = int.tryParse(intervalCtl.text.trim()) ?? 6;
    final hour = (int.tryParse(hourCtl.text.trim()) ?? 4).clamp(0, 23);

    setState(() => loading = true);
    SmartDialog.showLoading(
      msg: widget.editServer == null ? '正在连接并登录…' : '正在保存…',
    );
    try {
      if (widget.editServer == null) {
        final server = await FnOsService.instance.addServer(
          name: name,
          address: url,
          username: username,
          password: password,
        );
        await FnOsService.instance.setRefreshRule(
          server.id,
          autoRefresh: autoRefresh,
          refreshMode: refreshMode,
          refreshIntervalHours: interval,
          refreshHour: hour,
        );
        SmartDialog.dismiss();
        if (mounted) {
          SmartDialog.showToast(
            name.isEmpty ? '添加成功（名称已自动获取）' : '添加成功',
          );
          Get.off(() => FnOsBrowsePage(server: server));
        }
      } else {
        final id = widget.editServer!.id;
        await FnOsService.instance.updateServer(
          id: id,
          name: name,
          address: url,
          username: username,
          password: password,
        );
        await FnOsService.instance.setRefreshRule(
          id,
          autoRefresh: autoRefresh,
          refreshMode: refreshMode,
          refreshIntervalHours: interval,
          refreshHour: hour,
        );
        SmartDialog.dismiss();
        if (mounted) {
          SmartDialog.showToast('已保存');
          Get.back();
        }
      }
    } catch (e) {
      SmartDialog.dismiss();
      SmartDialog.showToast('连接失败：$e');
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  Future<void> _pickProtocol() async {
    final p = await showModalBottomSheet<String>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              title: const Text('HTTP'),
              trailing: protocol == 'http' ? const Icon(Icons.check) : null,
              onTap: () => Navigator.pop(ctx, 'http'),
            ),
            ListTile(
              title: const Text('HTTPS'),
              trailing: protocol == 'https' ? const Icon(Icons.check) : null,
              onTap: () => Navigator.pop(ctx, 'https'),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
    if (p != null && p != protocol) {
      setState(() => protocol = p);
    }
  }

  /// 统一字段行：左侧标签，右侧输入/值，圆角灰底。
  Widget _field({
    required String label,
    bool required = false,
    required Widget child,
    String? helper,
  }) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
          decoration: BoxDecoration(
            color: theme.colorScheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(12),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              SizedBox(
                width: 72,
                child: Row(
                  children: [
                    Text(
                      label,
                      style: const TextStyle(fontSize: 15),
                    ),
                    if (required)
                      Text(
                        '*',
                        style: TextStyle(
                          fontSize: 15,
                          color: theme.colorScheme.error,
                        ),
                      ),
                  ],
                ),
              ),
              Expanded(child: child),
            ],
          ),
        ),
        if (helper != null && helper.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(left: 16, top: 6, bottom: 2),
            child: Text(
              helper,
              style: theme.textTheme.bodySmall?.copyWith(fontSize: 12),
            ),
          ),
      ],
    );
  }

  Widget _input({
    required TextEditingController controller,
    required String hint,
    TextInputType? keyboardType,
    bool obscure = false,
    Widget? suffix,
    VoidCallback? onChanged,
    List<TextInputFormatter>? inputFormatters,
  }) {
    return TextField(
      controller: controller,
      keyboardType: keyboardType,
      obscureText: obscure,
      autocorrect: false,
      inputFormatters: inputFormatters,
      onChanged: (_) => onChanged?.call(),
      decoration: InputDecoration(
        hintText: hint,
        border: InputBorder.none,
        contentPadding: const EdgeInsets.symmetric(vertical: 14),
        suffixIcon: suffix,
        isDense: true,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.editServer == null ? '添加飞牛影视' : '编辑飞牛影视'),
      ),
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _field(
                      label: '名称',
                      child: _input(
                        controller: nameCtl,
                        hint: '选填，自动获取名称',
                      ),
                    ),
                    const SizedBox(height: 16),
                    _field(
                      label: '协议',
                      child: InkWell(
                        onTap: _pickProtocol,
                        child: Padding(
                          padding: const EdgeInsets.symmetric(vertical: 14),
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.end,
                            children: [
                              Text(
                                protocol.toUpperCase(),
                                style: const TextStyle(fontSize: 15),
                              ),
                              const SizedBox(width: 4),
                              const Icon(Icons.chevron_right, size: 20),
                            ],
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 16),
                    _field(
                      label: '地址',
                      required: true,
                      child: _input(
                        controller: addrCtl,
                        hint: '请输入 IP 或域名',
                        keyboardType: TextInputType.url,
                        onChanged: () => setState(() {}),
                      ),
                    ),
                    const SizedBox(height: 16),
                    _field(
                      label: '端口',
                      helper: '飞牛影视端口(而非fnOS)，默认为8005',
                      child: _input(
                        controller: portCtl,
                        hint: '8005',
                        keyboardType: TextInputType.number,
                        inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                      ),
                    ),
                    const SizedBox(height: 16),
                    _field(
                      label: '用户名',
                      required: true,
                      child: _input(
                        controller: userCtl,
                        hint: '必填',
                        onChanged: () => setState(() {}),
                      ),
                    ),
                    const SizedBox(height: 16),
                    _field(
                      label: '密码',
                      child: _input(
                        controller: pwdCtl,
                        hint: '选填',
                        obscure: obscure,
                        suffix: IconButton(
                          icon: Icon(
                            obscure ? Icons.visibility : Icons.visibility_off,
                            size: 20,
                          ),
                          onPressed: () => setState(() => obscure = !obscure),
                        ),
                      ),
                    ),
                    const SizedBox(height: 24),
                    Text(
                      '自动刷新影视库列表',
                      style: theme.textTheme.titleSmall,
                    ),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            '开启后按规则自动重新拉取影视库',
                            style: theme.textTheme.bodySmall,
                          ),
                        ),
                        Transform.scale(
                          scale: 0.75,
                          child: Switch(
                            value: autoRefresh,
                            onChanged: (v) =>
                                setState(() => autoRefresh = v),
                            materialTapTargetSize:
                                MaterialTapTargetSize.shrinkWrap,
                          ),
                        ),
                      ],
                    ),
                    if (autoRefresh) ...[
                      const SizedBox(height: 8),
                      SegmentedButton<String>(
                        segments: const [
                          ButtonSegment(
                            value: kRefreshModeInterval,
                            label: Text('每隔 N 小时'),
                          ),
                          ButtonSegment(
                            value: kRefreshModeDaily,
                            label: Text('每天指定时间'),
                          ),
                        ],
                        selected: {refreshMode},
                        onSelectionChanged: (s) =>
                            setState(() => refreshMode = s.first),
                      ),
                      const SizedBox(height: 12),
                      if (refreshMode == kRefreshModeInterval)
                        _field(
                          label: '间隔',
                          helper: '每隔多少小时刷新一次',
                          child: _input(
                            controller: intervalCtl,
                            hint: '6',
                            keyboardType: TextInputType.number,
                            inputFormatters: [
                              FilteringTextInputFormatter.digitsOnly
                            ],
                          ),
                        )
                      else
                        _field(
                          label: '时间',
                          helper: '每天几点（0-23）刷新',
                          child: _input(
                            controller: hourCtl,
                            hint: '4',
                            keyboardType: TextInputType.number,
                            inputFormatters: [
                              FilteringTextInputFormatter.digitsOnly
                            ],
                          ),
                        ),
                    ],
                    const SizedBox(height: 24),
                    Text(
                      '本应用使用飞牛影视官方 API 直连媒体服务器，使用过程中不会扫描识别媒体库文件',
                      style: theme.textTheme.bodySmall?.copyWith(fontSize: 12),
                    ),
                  ],
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(16),
                child: SizedBox(
                  width: double.infinity,
                  height: 48,
                  child: ElevatedButton(
                    onPressed: canAdd && !loading ? _save : null,
                    child: loading
                        ? const SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: Colors.white,
                            ),
                          )
                        : Text(widget.editServer == null ? '添加' : '保存'),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../acp/acp_config.dart';
import '../../../acp/acp_provisioner.dart';
import '../../../core/providers/settings_provider.dart';
import '../../../utils/app_directories.dart';

/// ACP runtime toggle + API key + on-device sandbox provisioning tile.
class AcpSandboxTile extends StatefulWidget {
  const AcpSandboxTile({super.key});

  @override
  State<AcpSandboxTile> createState() => _AcpSandboxTileState();
}

class _AcpSandboxTileState extends State<AcpSandboxTile> {
  static const String _imageRef = 'docker.m.daocloud.io/library/debian:trixie';

  double _progress = 0;
  String _message = '';
  bool _running = false;
  bool _ready = false;

  Future<void> _configure() async {
    if (_running) return;
    setState(() {
      _running = true;
      _progress = 0;
      _message = 'starting';
    });
    try {
      final dir = await AppDirectories.getAppDataDirectory();
      final provisioner = AcpSandboxProvisioner(
        rootfsDir: '${dir.path}/acp-rootfs',
        imageRef: _imageRef,
        onProgress: (p, m) {
          if (!mounted) return;
          setState(() {
            _progress = p;
            _message = m;
          });
        },
      );
      await provisioner.provision();
      if (!mounted) return;
      setState(() {
        _ready = true;
        _progress = 1;
        _message = 'sandbox ready';
        _running = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _running = false;
        _message = 'failed: $e';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<SettingsProvider>();
    final acpOn = acpEnabled;
    final ready = _ready || _message == 'sandbox ready';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SwitchListTile(
          dense: true,
          title: const Text('启用 ACP Agent'),
          subtitle: const Text('经 PRoot 沙箱运行 pi（需 agent 就绪）'),
          value: acpOn,
          onChanged: (v) => setState(() {
            acpEnabled = v;
          }),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
          child: TextFormField(
            initialValue: settings.acpApiKey,
            obscureText: true,
            decoration: const InputDecoration(
              labelText: 'Agent API Key',
              hintText: 'pi provider key',
              border: OutlineInputBorder(),
              isDense: true,
            ),
            onChanged: (v) => settings.setAcpApiKey(v),
          ),
        ),
        if (_running)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
            child: LinearProgressIndicator(
              value: _progress > 1 ? null : _progress,
            ),
          ),
        ListTile(
          dense: true,
          leading: Icon(
            ready ? Icons.check_circle : Icons.download_for_offline,
            color: ready ? Colors.green : null,
          ),
          title: Text(ready ? 'ACP 沙箱已就绪' : '配置沙箱（下载 pi 环境）'),
          subtitle: Text(_message.isEmpty ? '下载 Debian arm64 rootfs 并安装 pi' : _message),
          trailing: _running
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.chevron_right),
          enabled: !_running,
          onTap: _configure,
        ),
      ],
    );
  }
}

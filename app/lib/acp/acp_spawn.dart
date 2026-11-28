/// Spawns the ACP agent subprocess the kelivo ACP client drives.
///
/// Desktop: launch the ACP server directly (e.g. `pi-acp`).
/// Android: wrap it in the bundled PRoot sandbox (`proot -0 -r <rootfs>`)
/// so the full agent toolchain (node/pi/pi-acp) runs inside the Linux
/// userland with no root required.
///
/// Pure `dart:io`, no Flutter dependency — testable standalone.
library;

import 'dart:io';

/// How to launch the ACP agent for the current platform.
class AcpSpawnConfig {
  const AcpSpawnConfig({
    required this.agentCommand,
    this.useProot = false,
    this.rootfs,
    this.workspaceDir = '/workspace',
    this.prootPath = 'proot',
    this.env,
  });

  /// The ACP server command inside the sandbox, e.g. `['pi-acp']`.
  final List<String> agentCommand;

  /// Wrap [agentCommand] in the PRoot sandbox (Android / mobile).
  final bool useProot;

  /// Path to the unpacked Linux rootfs (must contain node + pi + pi-acp).
  final String? rootfs;

  /// Working directory inside the sandbox (the bound workspace).
  final String workspaceDir;

  /// Path to the PRoot binary (bundled assets path, or on PATH).
  final String prootPath;

  /// Extra environment variables for the agent process (e.g. provider keys).
  final Map<String, String>? env;

  /// Build the full argv for [Process.start].
  List<String> buildArgs() {
    if (useProot && rootfs != null) {
      final inner =
          'export PATH=/usr/local/bin:/usr/bin:/bin; exec ${agentCommand.join(' ')}';
      return [
        prootPath,
        '-0',
        '-r', rootfs!,
        '-b', '/proc',
        '-b', '/dev',
        '-b', '/sys',
        '-b', '/etc/resolv.conf',
        '-w', workspaceDir,
        '/bin/sh',
        '-c', inner,
      ];
    }
    return agentCommand;
  }

  String get command => useProot && rootfs != null ? prootPath : agentCommand.first;

  /// Spawn the agent process.
  Future<Process> start() {
    final args = buildArgs();
    return Process.start(
      args.first,
      args.sublist(1),
      mode: ProcessStartMode.normal,
      runInShell: false,
      // Merge into the inherited environment — passing a bare map would
      // replace PATH/HOME and break the agent launch. Local copy so the
      // public field can be promoted.
      environment: () {
        final extra = env;
        return extra == null
            ? null
            : <String, String>{...Platform.environment, ...extra};
      }(),
    );
  }
}

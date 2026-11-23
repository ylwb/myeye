/// Owns the ACP agent process + session lifecycle for one conversation's
/// generation. chat_actions injects this (or leaves it null to fall back to
/// the provider path). Pure Dart — no Flutter dependency.
library;

import 'dart:io';

import 'acp_client.dart';
import 'acp_spawn.dart';
import 'acp_to_chunk.dart';

/// Manages a single ACP agent subprocess and session.
class AcpSessionManager {
  AcpSessionManager({
    this.agentCommand = const ['pi-acp'],
    this.useProot = false,
    this.rootfs,
    this.workspaceDir = '/workspace',
  });

  final List<String> agentCommand;
  final bool useProot;
  final String? rootfs;
  final String workspaceDir;

  AcpClient? client;
  final AcpChunkConverter converter = AcpChunkConverter();

  /// Routes normalized ACP events to the caller (chat_actions).
  void Function(AcpEvent event)? onEvent;

  bool _started = false;

  /// Spawn the agent, initialize, and open a session (idempotent).
  Future<void> ensureSession({String? cwd}) async {
    if (_started && client?.isRunning == true) return;
    final config = AcpSpawnConfig(
      agentCommand: agentCommand,
      useProot: useProot,
      rootfs: rootfs,
      workspaceDir: workspaceDir,
    );
    final args = config.buildArgs();
    final acp = AcpClient(onEvent: (e) => onEvent?.call(e));
    await acp.start(args.first, args.sublist(1));
    await acp.initialize();
    await acp.sessionNew(cwd: cwd ?? Directory.current.path);
    client = acp;
    _started = true;
  }

  /// Send the user prompt; results arrive via [onEvent].
  Future<void> prompt(String text) async {
    final acp = client;
    if (acp == null) throw StateError('ACP session not started');
    await acp.sessionPrompt(text);
  }

  /// Tear down the agent process.
  Future<void> stop() async {
    _started = false;
    await client?.stop();
    client = null;
  }
}

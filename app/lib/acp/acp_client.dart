/// ACP client for kelivo — speaks Agent Client Protocol (JSON-RPC 2.0
/// over stdio / NDJSON) to an ACP server (e.g. `pi-acp` which spawns
/// `pi --mode rpc`).
///
/// Pure protocol layer: no Flutter dependency, testable standalone.
///
/// Verified contract (against pi-acp 0.0.35):
///   C->A  initialize({protocolVersion: 1})
///   C->A  session/new  {cwd, mcpServers}          -> {sessionId, models, configOptions}
///   C->A  session/prompt {sessionId, prompt:[{type:'text',text}]}
///   A->C  session/update {sessionId, update:{sessionUpdate, ...}}
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// A model the agent exposes (from `session/new` result `models.availableModels`).
class AcpModel {
  const AcpModel({required this.id, required this.name, this.description});

  final String id;
  final String name;
  final String? description;

  factory AcpModel.fromJson(Map<String, dynamic> json) => AcpModel(
        id: (json['modelId'] ?? json['id'] ?? '') as String,
        name: (json['name'] ?? json['modelId'] ?? '') as String,
        description: json['description'] as String?,
      );
}

/// Normalized ACP session events (subset kelivo needs).
sealed class AcpEvent {
  const AcpEvent();
}

/// Streaming assistant text delta.
final class AcpTextDelta extends AcpEvent {
  const AcpTextDelta(this.text);
  final String text;
}

/// Assistant emitted a non-text content block (image / tool call / reasoning).
final class AcpContentBlock extends AcpEvent {
  const AcpContentBlock(this.block);
  final Map<String, dynamic> block;
}

/// Agent reported context/token usage.
final class AcpUsageUpdate extends AcpEvent {
  const AcpUsageUpdate(this.used, this.total);
  final int used;
  final int total;
}

/// Session metadata changed (model, cwd, etc.).
final class AcpSessionInfo extends AcpEvent {
  const AcpSessionInfo(this.info);
  final Map<String, dynamic> info;
}

/// Available commands / slash commands updated.
final class AcpAvailableCommands extends AcpEvent {
  const AcpAvailableCommands(this.commands);
  final List<dynamic> commands;
}

/// Tool permission request from the agent (needs a permission_response reply).
final class AcpPermissionRequest extends AcpEvent {
  const AcpPermissionRequest(this.requestId, this.toolCall);
  final String requestId;
  final Map<String, dynamic> toolCall;
}

/// Agent finished a turn.
final class AcpTurnEnd extends AcpEvent {
  const AcpTurnEnd();
}

/// Agent cancelled.
final class AcpCancelled extends AcpEvent {
  const AcpCancelled();
}

/// ACP client errors surfaced to the UI.
final class AcpError extends AcpEvent {
  const AcpError(this.message);
  final String message;
}

/// Stateful ACP client.
class AcpClient {
  AcpClient({
    required this.onEvent,
    this.onExit,
    this.log,
  });

  /// Called for every normalized [AcpEvent].
  /// May be reassigned by an [AcpAgent] to route events through a bridge.
  void Function(AcpEvent event) onEvent;

  /// Called when the agent subprocess exits.
  final void Function(int? exitCode)? onExit;

  /// Optional diagnostics sink (stderr from agent + protocol errors).
  final void Function(String line)? log;

  Process? _proc;
  StreamSubscription<String>? _stdoutSub;
  StreamSubscription<String>? _stderrSub;
  int _reqId = 0;
  final Map<String, Completer<Map<String, dynamic>>> _pending = {};

  String? sessionId;
  List<AcpModel> models = const [];
  Map<String, dynamic>? configOptions;
  bool _closed = false;

  bool get isRunning => _proc != null;

  /// Spawn the ACP server.
  ///
  /// [command]/[args] is the full spawn: e.g. on desktop `['pi-acp']`, on
  /// Android `['proot', '-0', '-r', rootfs, ..., '/bin/sh', '-c', 'pi-acp']`.
  /// The caller decides the sandbox wrapper; this class only owns the pipe.
  Future<void> start(String command, List<String> args) async {
    final proc = await Process.start(command, args,
        mode: ProcessStartMode.normal, runInShell: false);
    _proc = proc;
    _stdoutSub = proc.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(_onLine, onError: _onStreamError);
    _stderrSub = proc.stderr
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((l) => log?.call(l));
    proc.exitCode.then((code) {
      _proc = null;
      if (!_closed) {
        onExit?.call(code);
      }
    });
  }

  void _onStreamError(Object e) => log?.call('stdout error: $e');

  /// Send a JSON-RPC request and await its response, correlating by id.
  Future<Map<String, dynamic>> call(
    String method,
    Map<String, dynamic> params, {
    Duration timeout = const Duration(seconds: 30),
  }) async {
    final proc = _proc;
    if (proc == null) {
      throw StateError('ACP client not started');
    }
    final id = 'c${++_reqId}';
    final completer = Completer<Map<String, dynamic>>();
    _pending[id] = completer;
    final timer = Timer(timeout, () {
      if (_pending.remove(id) != null) {
        completer.completeError(TimeoutException('ACP call timed out: $method'));
      }
    });
    try {
      final req = <String, dynamic>{
        'jsonrpc': '2.0',
        'id': id,
        'method': method,
        'params': params,
      };
      proc.stdin.writeln(jsonEncode(req));
      await proc.stdin.flush();
      return await completer.future;
    } finally {
      timer.cancel();
    }
  }

  /// Handshake. Must be called before [sessionNew].
  Future<Map<String, dynamic>> initialize() =>
      call('initialize', {'protocolVersion': 1});

  /// Create a session. Stores [sessionId], [models], [configOptions].
  Future<Map<String, dynamic>> sessionNew({
    required String cwd,
    List<Map<String, dynamic>> mcpServers = const [],
  }) async {
    final result = await call('session/new', {
      'cwd': cwd,
      'mcpServers': mcpServers,
    });
    sessionId = result['sessionId'] as String?;
    final modelsJson = result['models'];
    if (modelsJson is Map<String, dynamic>) {
      final avail = modelsJson['availableModels'];
      if (avail is List) {
        models = avail
            .whereType<Map<String, dynamic>>()
            .map(AcpModel.fromJson)
            .toList();
      }
    }
    if (result['configOptions'] is List) {
      configOptions = result;
    }
    return result;
  }

  /// Send a prompt to the session. Results arrive via [onEvent] streams.
  Future<void> sessionPrompt(
    String text, {
    List<Map<String, dynamic>> images = const [],
  }) async {
    final sid = sessionId;
    if (sid == null) throw StateError('No active session');
    final prompt = <Map<String, dynamic>>[
      if (text.isNotEmpty) {'type': 'text', 'text': text},
      ...images,
    ];
    await call('session/prompt', {
      'sessionId': sid,
      'prompt': prompt,
    });
  }

  /// Reply to a permission request.
  Future<void> permissionResponse(String requestId, bool allowed) async {
    final sid = sessionId;
    if (sid == null) return;
    // TODO(kelivo): verify the exact ACP permission reply method on pi-acp.
    await call('session/update', {
      'sessionId': sid,
      'update': {
        'sessionUpdate': 'permission_response',
        'requestId': requestId,
        'allowed': allowed,
      },
    });
  }

  /// Graceful shutdown: close stdin, wait for exit, then kill if needed.
  Future<void> stop() async {
    _closed = true;
    final proc = _proc;
    if (proc == null) return;
    try {
      await proc.stdin.close();
      await proc.exitCode.timeout(const Duration(seconds: 5),
          onTimeout: () {
        proc.kill(ProcessSignal.sigterm);
        return proc.exitCode;
      });
    } catch (_) {
      proc.kill(ProcessSignal.sigkill);
    }
    await _stdoutSub?.cancel();
    await _stderrSub?.cancel();
  }

  void _onLine(String line) {
    if (line.trim().isEmpty) return;
    final Map<String, dynamic> rec;
    try {
      rec = jsonDecode(line) as Map<String, dynamic>;
    } catch (e) {
      log?.call('bad json: $line');
      return;
    }

    // Correlated response.
    final id = rec['id'];
    if (id != null && _pending.containsKey(id)) {
      final completer = _pending.remove(id)!;
      if (rec['error'] != null) {
        final err = rec['error'] as Map<String, dynamic>;
        completer.completeError(StateError('${err['message']}'));
      } else {
        final result = rec['result'];
        completer.complete(
            result is Map<String, dynamic> ? result : <String, dynamic>{});
      }
      return;
    }

    // Agent -> client notification.
    if (rec['method'] == 'session/update') {
      final params = rec['params'];
      final update = params is Map<String, dynamic> ? params['update'] : null;
      if (update is Map<String, dynamic>) {
        _dispatchUpdate(update);
      }
    }
  }

  void _dispatchUpdate(Map<String, dynamic> update) {
    final kind = update['sessionUpdate'];
    switch (kind) {
      case 'agent_message_chunk':
        final content = update['content'];
        if (content is Map<String, dynamic> && content['type'] == 'text') {
          onEvent(AcpTextDelta((content['text'] ?? '') as String));
        } else if (content is Map<String, dynamic>) {
          onEvent(AcpContentBlock(content));
        }
        break;
      case 'agent_message':
        // Terminal/empty marker or image block.
        onEvent(AcpTurnEnd());
        break;
      case 'usage_update':
        final used = (update['used'] ?? 0) as int;
        final total = (update['size'] ?? 0) as int;
        onEvent(AcpUsageUpdate(used, total));
        break;
      case 'session_info_update':
        onEvent(AcpSessionInfo(update));
        break;
      case 'available_commands_update':
        final cmds = update['availableCommands'];
        onEvent(AcpAvailableCommands(
            cmds is List ? cmds : const <dynamic>[]));
        break;
      case 'permission_request':
        onEvent(AcpPermissionRequest(
          (update['requestId'] ?? '') as String,
          (update['toolCall'] ?? const {}) as Map<String, dynamic>,
        ));
        break;
      case 'cancelled':
        onEvent(const AcpCancelled());
        break;
      default:
        // Unmapped events are dropped silently; extend as needed.
        log?.call('unmapped sessionUpdate: $kind');
    }
  }
}

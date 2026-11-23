/// ACP runtime smoke test for the kelivo ACP bridge.
///
/// Exercises AcpSessionManager end-to-end against a real `pi-acp` agent:
///   spawn -> initialize -> session/new  (no model key required)
///   -> session/prompt -> agent_message_chunk  (requires MODEL_API_KEY)
///
/// Run: dart run tool/acp_smoke.dart
library;

import 'dart:async';
import 'dart:io';

import '../lib/acp/acp_client.dart';
import '../lib/acp/acp_session.dart';

Future<void> main() async {
  final withPrompt = Platform.environment['MODEL_API_KEY'] != null;
  final manager = AcpSessionManager();
  final turnDone = Completer<void>();
  var textReceived = false;

  manager.onEvent = (event) {
    if (event is AcpTextDelta) {
      textReceived = true;
      stdout.write(event.text);
    } else if (event is AcpUsageUpdate) {
      stdout.writeln('\n[usage] ${event.used}/${event.total}');
    } else if (event is AcpTurnEnd) {
      if (!turnDone.isCompleted) turnDone.complete();
    }
  };

  stdout.writeln('[smoke] starting pi-acp...');
  try {
    await manager.ensureSession();
  } catch (e) {
    // No model key configured: the agent refuses auth. That still proves the
    // spawn -> initialize -> session/new wire works, so treat it as healthy
    // (mirrors the Node handshake job's auth-aware pass).
    if (e.toString().contains('Authentication required')) {
      stdout.writeln('[smoke] OK: reached agent (auth required, no key)');
      await manager.stop();
      return;
    }
    rethrow;
  }
  stdout.writeln('[smoke] session/new ok (models=${manager.client?.models.length})');

  if (withPrompt) {
    stdout.writeln('[smoke] prompt (MODEL_API_KEY set)...');
    await manager.prompt('Reply with exactly: ACP-SMOKE-OK');
    await Future.any([
      turnDone.future,
      Future<void>.delayed(const Duration(seconds: 30)),
    ]);
    stdout.writeln();
    if (!textReceived) {
      stderr.writeln('[smoke] FAIL: no assistant text received');
      exitCode = 1;
    } else {
      stdout.writeln('[smoke] OK: got assistant text');
    }
  } else {
    stdout.writeln('[smoke] OK (handshake only; set MODEL_API_KEY for prompt)');
  }

  await manager.stop();
}

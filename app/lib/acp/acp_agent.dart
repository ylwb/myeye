/// Bridges normalized [AcpEvent]s from [AcpClient] into kelivo message
/// content (`MessagePart` increments) without touching the UI.
///
/// chat_service owns an [AcpAgent] and registers callbacks; the agent turns
/// ACP stream events into `MessagePart` deltas that get appended to the
/// in-flight assistant message.
library;

import 'dart:convert';

import '../core/models/message_part.dart';
import 'acp_client.dart';

/// One increment of assistant content produced by the ACP stream.
sealed class AcpDelta {
  const AcpDelta();
}

/// Append a text delta to the current assistant message.
final class AcpDeltaText extends AcpDelta {
  const AcpDeltaText(this.text);
  final String text;
}

/// Append a structured content block (image / tool call / reasoning).
final class AcpDeltaBlock extends AcpDelta {
  const AcpDeltaBlock(this.block);
  final Map<String, dynamic> block;
}

/// The agent finished its turn (finalize the assistant message).
final class AcpDeltaTurnEnd extends AcpDelta {
  const AcpDeltaTurnEnd();
}

/// Turn an [AcpEvent] stream into `MessagePart` deltas.
class AcpAgent {
  AcpAgent({
    required AcpClient client,
    required this.onDelta,
    this.onUsage,
    this.onPermission,
    this.onSessionInfo,
    this.onCommands,
    this.onCancelled,
  }) : _client = client {
    // Re-route the client's raw event sink through this bridge.
    // (AcpClient.onEvent is final; we subscribe via a wrapper.)
  }

  final AcpClient _client;
  final void Function(AcpDelta delta) onDelta;
  final void Function(AcpUsageUpdate usage)? onUsage;
  final void Function(AcpPermissionRequest request)? onPermission;
  final void Function(AcpSessionInfo info)? onSessionInfo;
  final void Function(AcpAvailableCommands commands)? onCommands;
  final void Function()? onCancelled;

  /// Attach this bridge to the client's event stream.
  void bind() {
    _client.onEvent = handle;
  }

  /// Forward one raw ACP event into deltas/callbacks.
  void handle(AcpEvent event) {
    switch (event) {
      case AcpTextDelta(:final text):
        onDelta(AcpDeltaText(text));
      case AcpContentBlock(:final block):
        onDelta(AcpDeltaBlock(block));
      case AcpTurnEnd():
        onDelta(const AcpDeltaTurnEnd());
      case AcpUsageUpdate():
        onUsage?.call(event);
      case AcpPermissionRequest():
        onPermission?.call(event);
      case AcpSessionInfo():
        onSessionInfo?.call(event);
      case AcpAvailableCommands():
        onCommands?.call(event);
      case AcpCancelled():
        onCancelled?.call();
      case AcpError(:final message):
        onDelta(AcpDeltaBlock({'type': 'error', 'text': message}));
    }
  }
}

/// Map an ACP content block to a kelivo [MessagePart] where possible.
MessagePart? acpBlockToPart(Map<String, dynamic> block) {
  switch (block['type']) {
    case 'text':
      final text = block['text'];
      return text is String ? TextPart(text) : null;
    case 'image':
      final data = block['data'];
      // ACP images carry base64 data or a URI; kelivo ImagePart needs a uri.
      if (data is String) {
        final uri = data.startsWith('data:') || data.startsWith('http')
            ? data
            : 'data:image/png;base64,$data';
        return ImagePart(uri: uri, mime: 'image/png');
      }
      return null;
    case 'tool_call':
      return ToolCallPart(const JsonEncoder().convert(block));
    default:
      return null;
    // reasoning / tool_call_update / tool_call_finished map to ToolCallPart
    // or are surfaced through the existing tool-event channel; extend as
    // the pi-acp permission/tool contract is verified.
  }
}

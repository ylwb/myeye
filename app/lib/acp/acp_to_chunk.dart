/// Converts normalized [AcpEvent]s into kelivo [StreamChunk]s so the existing
/// streaming pipeline (`_handleStreamChunk` → `partsHandler`/`streamController`)
/// renders ACP output with **zero UI changes**.
///
/// Stateful: tracks text start/end and tool call ids across the stream.
library;

import '../core/models/token_usage.dart';
import '../core/services/api/stream/stream_chunk.dart';
import 'acp_client.dart';

/// Maps a stream of [AcpEvent]s to [StreamChunk]s.
class AcpChunkConverter {
  AcpChunkConverter({this.textId = 'acp'});

  final String textId;
  bool _textStarted = false;
  int _toolSeq = 0;

  /// Convert one ACP event into zero or more chunks.
  List<StreamChunk> convert(AcpEvent event) {
    switch (event) {
      case AcpTextDelta(:final text):
        final chunks = <StreamChunk>[];
        if (!_textStarted) {
          chunks.add(TextStart(textId));
          _textStarted = true;
        }
        chunks.add(TextDelta(id: textId, text: text));
        return chunks;

      case AcpContentBlock(:final block):
        return _convertBlock(block);

      case AcpUsageUpdate(:final total):
        // ACP reports context size; kelivo Usage is token-based. Report as an
        // estimated usage so the context meter updates without billing claims.
        return [
          Usage(TokenUsage(totalTokens: total), estimated: true),
        ];

      case AcpTurnEnd():
        final chunks = <StreamChunk>[];
        if (_textStarted) {
          chunks.add(TextEnd(textId));
          _textStarted = false;
        }
        chunks.add(const Finish());
        return chunks;

      case AcpCancelled():
        return [
          if (_textStarted) TextEnd(textId),
          const Finish(),
        ];

      default:
        return const [];
    }
  }

  List<StreamChunk> _convertBlock(Map<String, dynamic> block) {
    switch (block['type']) {
      case 'tool_call':
        final tid = 'tool${++_toolSeq}';
        final name = (block['name'] ?? block['toolName'] ?? 'tool').toString();
        return [ToolCallStart(id: tid, toolName: name)];

      case 'tool_call_finished':
        // Best-effort: close the latest tool call seen so far.
        final tid = 'tool$_toolSeq';
        return [ToolCallEnd(tid)];

      case 'image':
        final data = (block['data'] ?? '').toString();
        return [
          ImageStart(id: textId, mimeType: 'image/png'),
          ImageDelta(id: textId, data: data),
          ImageEnd(textId),
        ];

      default:
        return const [];
    }
  }
}

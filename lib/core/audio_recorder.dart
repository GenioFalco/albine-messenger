import 'dart:js_interop';
import 'dart:typed_data';

import 'package:record/record.dart';
import 'package:web/web.dart' as web;

/// A finished voice recording, ready to feed straight into the existing
/// encrypt → upload media pipeline (`ChatRepository.sendMediaMessage`).
class RecordedVoice {
  const RecordedVoice({
    required this.bytes,
    required this.mime,
    required this.duration,
  });

  final Uint8List bytes;
  final String mime;
  final Duration duration;
}

/// Voice-message capture tuned for a clean, "top" sound rather than the muddy
/// low-bitrate voice notes of VK/WhatsApp (~16–24 kbps): Opus at 48 kHz, mono,
/// ~96 kbps, with the browser's echo-cancel + noise-suppression + auto-gain.
/// Opus is transparent at this bitrate for speech, so there are no codec
/// artifacts — the difference the user asked for is almost entirely the higher
/// bitrate plus a modern codec.
///
/// Web-only for now (matches the PWA target). `record` hands back a blob URL on
/// `stop()`; we fetch it into bytes so the rest of the app never has to know
/// audio came from anywhere special — it's just encrypted media like a photo.
class VoiceRecorder {
  final AudioRecorder _rec = AudioRecorder();
  DateTime? _startedAt;

  Future<bool> hasPermission() => _rec.hasPermission();

  Future<void> start() async {
    _startedAt = DateTime.now();
    await _rec.start(
      const RecordConfig(
        encoder: AudioEncoder.opus,
        sampleRate: 48000,
        bitRate: 96000,
        numChannels: 1,
        echoCancel: true,
        noiseSuppress: true,
        autoGain: true,
      ),
      // Ignored on web (record returns a blob URL from stop()); required by the
      // cross-platform signature.
      path: '',
    );
  }

  /// Stops and returns the recording, or null if nothing was captured.
  Future<RecordedVoice?> stop() async {
    final url = await _rec.stop();
    final duration = _startedAt == null
        ? Duration.zero
        : DateTime.now().difference(_startedAt!);
    _startedAt = null;
    if (url == null) return null;
    final bytes = await _blobUrlToBytes(url);
    if (bytes.isEmpty) return null;
    return RecordedVoice(
      bytes: bytes,
      mime: 'audio/webm;codecs=opus',
      duration: duration,
    );
  }

  /// Discards the in-progress recording without producing a message.
  Future<void> cancel() async {
    _startedAt = null;
    try {
      await _rec.cancel();
    } catch (_) {
      // Nothing recording / already stopped — nothing to clean up.
    }
  }

  Future<bool> isRecording() => _rec.isRecording();

  void dispose() => _rec.dispose();

  Future<Uint8List> _blobUrlToBytes(String url) async {
    final resp = await web.window.fetch(url.toJS).toDart;
    final buffer = (await resp.arrayBuffer().toDart).toDart;
    return buffer.asUint8List();
  }
}

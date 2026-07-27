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
    required this.waveform,
  });

  final Uint8List bytes;
  final String mime;
  final Duration duration;

  /// Compact amplitude envelope (each value 0–100, ~40 buckets) for the
  /// Telegram/VK-style bars. Empty if analysis failed (bubble draws flat bars).
  final List<int> waveform;
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

    // Analyze the just-recorded audio once, here on the recording device
    // (Web Audio decode works in Chrome/Firefox/Android), so the waveform +
    // exact duration travel with the message and every viewer can draw the
    // bars without decoding anything.
    var finalDuration = duration;
    var waveform = const <int>[];
    try {
      final analyzed = await analyzeVoice(bytes);
      waveform = analyzed.$2;
      if (analyzed.$1 > Duration.zero) finalDuration = analyzed.$1;
    } catch (_) {
      // Fall back to the wall-clock elapsed time and flat bars.
    }

    return RecordedVoice(
      bytes: bytes,
      mime: 'audio/webm;codecs=opus',
      duration: finalDuration,
      waveform: waveform,
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

/// Decodes [bytes] (any browser-playable audio) and returns its (duration,
/// waveform) — the waveform is [buckets] peak-amplitude values scaled to
/// 0–100. Web-only (Web Audio API). Throws if the browser can't decode the
/// format (e.g. WebM on iOS Safari) — callers should treat that as "no
/// waveform" rather than fatal.
Future<(Duration, List<int>)> analyzeVoice(
  Uint8List bytes, {
  int buckets = 40,
}) async {
  final ctx = web.AudioContext();
  try {
    // Fresh copy so we own the ArrayBuffer decodeAudioData will detach.
    final copy = Uint8List.fromList(bytes);
    final decoded = await ctx.decodeAudioData(copy.buffer.toJS).toDart;
    final duration = Duration(milliseconds: (decoded.duration * 1000).round());

    final channel = decoded.getChannelData(0).toDart;
    if (channel.isEmpty) return (duration, <int>[]);

    final per = (channel.length / buckets).ceil().clamp(1, channel.length);
    final peaks = <double>[];
    var maxPeak = 0.0;
    for (var b = 0; b < buckets; b++) {
      var peak = 0.0;
      final start = b * per;
      final end = (start + per).clamp(0, channel.length);
      for (var i = start; i < end; i++) {
        final a = channel[i].abs();
        if (a > peak) peak = a;
      }
      peaks.add(peak);
      if (peak > maxPeak) maxPeak = peak;
    }

    final scale = maxPeak == 0 ? 0.0 : 100.0 / maxPeak;
    return (duration, [for (final p in peaks) (p * scale).round().clamp(0, 100)]);
  } finally {
    ctx.close();
  }
}

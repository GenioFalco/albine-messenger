import 'dart:async';
import 'dart:js_interop';
import 'dart:typed_data';

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
  /// Telegram/VK-style bars.
  final List<int> waveform;
}

/// Records voice notes as uncompressed **16-bit PCM WAV** captured through the
/// Web Audio graph (getUserMedia → ScriptProcessor), rather than via
/// MediaRecorder/Opus.
///
/// Why WAV and not Opus: iOS Safari cannot decode Opus/WebM at all — neither in
/// an `<audio>` element nor via Web Audio — so an Opus voice note recorded on a
/// desktop (or even on the iPhone itself) simply never plays back on an iPhone.
/// WAV/PCM is the one format every target browser plays, and as a bonus it's
/// lossless — the cleanest possible sound, which is exactly the "not muddy like
/// VK" bar we're aiming for. The size cost is acceptable for short notes.
///
/// Mono, at the AudioContext's native rate (usually 48 kHz), with the browser's
/// echo-cancel / noise-suppress / auto-gain enabled on the input track.
class VoiceRecorder {
  web.MediaStream? _stream;
  web.AudioContext? _ctx;
  web.MediaStreamAudioSourceNode? _source;
  web.BiquadFilterNode? _highpass;
  web.DynamicsCompressorNode? _compressor;
  web.ScriptProcessorNode? _processor;
  web.GainNode? _sink;
  JSFunction? _onAudio;
  final List<Float32List> _chunks = [];
  int _sampleRate = 48000;

  Future<bool> hasPermission() async {
    // Permission is requested implicitly by getUserMedia in start(); if it's
    // denied that throws and start() surfaces it. Nothing to pre-check here.
    return true;
  }

  Future<void> start() async {
    _chunks.clear();

    final constraints = web.MediaStreamConstraints(
      audio: {
        'echoCancellation': true,
        'noiseSuppression': true,
        'autoGainControl': true,
        // Newer Chrome ML voice isolation; unknown constraints are ignored by
        // browsers that don't support it, so this is safe to always request.
        'voiceIsolation': true,
        'channelCount': 1,
      }.jsify()!,
    );
    final stream = await web.window.navigator.mediaDevices
        .getUserMedia(constraints)
        .toDart;
    _stream = stream;

    final ctx = web.AudioContext();
    _ctx = ctx;
    // A user gesture is what triggered start(), so resume() is allowed here.
    await ctx.resume().toDart;
    _sampleRate = ctx.sampleRate.round();

    final source = ctx.createMediaStreamSource(stream);
    _source = source;

    // Processing chain, applied before capture (Telegram-style "clean" voice):
    //   high-pass  — cuts low rumble / plosives / desk thumps below ~85 Hz
    //   compressor — evens out loudness (quiet speech pulled up, peaks tamed);
    //                this is the main thing that makes a voice note sound
    //                "produced" rather than raw
    // Final peak normalization happens offline in stop().
    final highpass = ctx.createBiquadFilter();
    highpass.type = 'highpass';
    highpass.frequency.value = 85;
    _highpass = highpass;

    final comp = ctx.createDynamicsCompressor();
    comp.threshold.value = -24;
    comp.knee.value = 30;
    comp.ratio.value = 4;
    comp.attack.value = 0.003;
    comp.release.value = 0.25;
    _compressor = comp;

    final processor = ctx.createScriptProcessor(4096, 1, 1);
    _processor = processor;
    // Route through a muted gain node so the mic never feeds back to the
    // speakers, while still keeping the processor connected to the
    // destination (required for onaudioprocess to fire in some browsers).
    final sink = ctx.createGain();
    sink.gain.value = 0;
    _sink = sink;

    _onAudio = ((web.AudioProcessingEvent e) {
      final data = e.inputBuffer.getChannelData(0).toDart;
      _chunks.add(Float32List.fromList(data));
    }).toJS;
    processor.onaudioprocess = _onAudio;

    source.connect(highpass);
    highpass.connect(comp);
    comp.connect(processor);
    processor.connect(sink);
    sink.connect(ctx.destination);
  }

  /// Stops and returns the recording, or null if nothing was captured.
  Future<RecordedVoice?> stop() async {
    final samples = _teardown();
    if (samples == null || samples.isEmpty) return null;

    _normalizePeak(samples);

    final wav = _encodeWav(samples, _sampleRate);
    final duration = Duration(
      milliseconds: (samples.length / _sampleRate * 1000).round(),
    );
    return RecordedVoice(
      bytes: wav,
      mime: 'audio/wav',
      duration: duration,
      waveform: _computeWaveform(samples),
    );
  }

  Future<void> cancel() async {
    _teardown();
  }

  Future<bool> isRecording() async => _processor != null;

  void dispose() {
    _teardown();
  }

  /// Disconnects the graph, stops the mic, and returns the concatenated PCM.
  Float32List? _teardown() {
    final processor = _processor;
    if (processor != null) {
      processor.onaudioprocess = null;
      try {
        processor.disconnect();
      } catch (_) {}
    }
    try {
      _source?.disconnect();
    } catch (_) {}
    try {
      _highpass?.disconnect();
    } catch (_) {}
    try {
      _compressor?.disconnect();
    } catch (_) {}
    try {
      _sink?.disconnect();
    } catch (_) {}
    for (final track in _tracks(_stream)) {
      track.stop();
    }
    final ctx = _ctx;
    if (ctx != null) {
      try {
        ctx.close();
      } catch (_) {}
    }

    _processor = null;
    _source = null;
    _highpass = null;
    _compressor = null;
    _sink = null;
    _stream = null;
    _ctx = null;
    _onAudio = null;

    if (_chunks.isEmpty) return null;
    final total = _chunks.fold<int>(0, (n, c) => n + c.length);
    final out = Float32List(total);
    var offset = 0;
    for (final c in _chunks) {
      out.setRange(offset, offset + c.length, c);
      offset += c.length;
    }
    _chunks.clear();
    return out;
  }

  List<web.MediaStreamTrack> _tracks(web.MediaStream? stream) {
    if (stream == null) return const [];
    final tracks = stream.getAudioTracks().toDart;
    return [for (final t in tracks) t];
  }

  /// Peak-normalizes in place so every voice note lands at a consistent
  /// loudness (~-0.3 dB). Only ever boosts, and the gain is capped so a
  /// near-silent recording doesn't get its background hiss amplified to full
  /// scale.
  static void _normalizePeak(Float32List samples) {
    var peak = 0.0;
    for (final s in samples) {
      final a = s.abs();
      if (a > peak) peak = a;
    }
    if (peak <= 0) return;
    final gain = (0.97 / peak).clamp(1.0, 8.0);
    if (gain == 1.0) return;
    for (var i = 0; i < samples.length; i++) {
      samples[i] = (samples[i] * gain).clamp(-1.0, 1.0);
    }
  }

  static Uint8List _encodeWav(Float32List samples, int sampleRate) {
    const channels = 1;
    const bitsPerSample = 16;
    final byteRate = sampleRate * channels * bitsPerSample ~/ 8;
    final blockAlign = channels * bitsPerSample ~/ 8;
    final dataLen = samples.length * 2;
    final buffer = ByteData(44 + dataLen);

    void writeString(int offset, String s) {
      for (var i = 0; i < s.length; i++) {
        buffer.setUint8(offset + i, s.codeUnitAt(i));
      }
    }

    writeString(0, 'RIFF');
    buffer.setUint32(4, 36 + dataLen, Endian.little);
    writeString(8, 'WAVE');
    writeString(12, 'fmt ');
    buffer.setUint32(16, 16, Endian.little);
    buffer.setUint16(20, 1, Endian.little); // PCM
    buffer.setUint16(22, channels, Endian.little);
    buffer.setUint32(24, sampleRate, Endian.little);
    buffer.setUint32(28, byteRate, Endian.little);
    buffer.setUint16(32, blockAlign, Endian.little);
    buffer.setUint16(34, bitsPerSample, Endian.little);
    writeString(36, 'data');
    buffer.setUint32(40, dataLen, Endian.little);

    var offset = 44;
    for (final s in samples) {
      final v = (s.clamp(-1.0, 1.0) * 32767).round();
      buffer.setInt16(offset, v, Endian.little);
      offset += 2;
    }
    return buffer.buffer.asUint8List();
  }

  static List<int> _computeWaveform(Float32List samples, {int buckets = 40}) {
    if (samples.isEmpty) return const [];
    final per = (samples.length / buckets).ceil().clamp(1, samples.length);
    final peaks = <double>[];
    var maxPeak = 0.0;
    for (var b = 0; b < buckets; b++) {
      var peak = 0.0;
      final start = b * per;
      final end = (start + per).clamp(0, samples.length);
      for (var i = start; i < end; i++) {
        final a = samples[i].abs();
        if (a > peak) peak = a;
      }
      peaks.add(peak);
      if (peak > maxPeak) maxPeak = peak;
    }
    final scale = maxPeak == 0 ? 0.0 : 100.0 / maxPeak;
    return [for (final p in peaks) (p * scale).round().clamp(0, 100)];
  }
}

import 'dart:async';
import 'dart:js_interop';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:just_audio/just_audio.dart';
import 'package:web/web.dart' as web;

import '../../core/theme/albine_theme.dart';
import '../../data/providers.dart';
import '../../domain/models.dart';

/// Ensures only one voice note plays at a time across the whole chat: whenever
/// a bubble starts, the previously-playing one is paused first — same as
/// Telegram/WhatsApp.
class _VoicePlaybackCoordinator {
  static _VoiceMessageBubbleState? _active;

  static void activate(_VoiceMessageBubbleState s) {
    if (_active != null && !identical(_active, s)) {
      _active!._pauseFromCoordinator();
    }
    _active = s;
  }

  static void deactivate(_VoiceMessageBubbleState s) {
    if (identical(_active, s)) _active = null;
  }
}

/// Telegram/VK-style voice bubble: circular play/pause, amplitude bars that
/// double as a seek bar (tap or drag to scrub), a playback-speed toggle
/// (1× → 1.5× → 2×), and the elapsed/total time. Waveform + duration come from
/// the message metadata so the bars and length show immediately; the encrypted
/// audio itself is fetched+decrypted lazily on first play.
class VoiceMessageBubble extends ConsumerStatefulWidget {
  const VoiceMessageBubble({
    super.key,
    required this.message,
    required this.mine,
    required this.colors,
  });

  final ChatMessage message;
  final bool mine;
  final AlbineColors colors;

  @override
  ConsumerState<VoiceMessageBubble> createState() => _VoiceMessageBubbleState();
}

class _VoiceMessageBubbleState extends ConsumerState<VoiceMessageBubble> {
  /// Playback speed persists across the whole session and every voice bubble:
  /// pick 2× on one note and all of them play at 2× until changed again.
  static double _rememberedSpeed = 1.0;

  final AudioPlayer _player = AudioPlayer();
  String? _objectUrl;
  bool _preparing = false;
  bool _prepared = false;
  bool _failed = false;
  late double _speed = _rememberedSpeed;
  StreamSubscription<PlayerState>? _stateSub;

  @override
  void initState() {
    super.initState();
    // Eagerly fetch+decrypt+load so that when the user taps play, play() runs
    // synchronously inside the tap's user-gesture window. iOS Safari refuses
    // an <audio>.play() that comes after an async gap (network/decrypt), so a
    // lazy "download on first tap" never actually plays there.
    Future.microtask(_prepare);
  }

  static const _defaultBars = <int>[
    18, 30, 22, 45, 60, 38, 52, 70, 40, 28,
    55, 72, 48, 33, 62, 80, 50, 36, 44, 66,
    30, 24, 58, 42, 68, 35, 50, 74, 46, 26,
    54, 38, 64, 48, 30, 56, 40, 22, 34, 20,
  ];

  List<int> get _bars {
    final w = widget.message.mediaWaveform;
    return (w != null && w.isNotEmpty) ? w : _defaultBars;
  }

  Duration get _storedDuration =>
      Duration(milliseconds: widget.message.mediaDurationMs ?? 0);

  @override
  void dispose() {
    _VoicePlaybackCoordinator.deactivate(this);
    _stateSub?.cancel();
    _player.dispose();
    if (_objectUrl != null) web.URL.revokeObjectURL(_objectUrl!);
    super.dispose();
  }

  void _pauseFromCoordinator() {
    if (_player.playing) _player.pause();
  }

  Future<bool> _prepare() async {
    if (_prepared) return true;
    if (_preparing) return false;
    setState(() {
      _preparing = true;
      _failed = false;
    });

    final chat = ref.read(chatRepositoryProvider);
    final bytes = await chat?.fetchAndDecryptMedia(widget.message);
    if (!mounted) return false;
    if (bytes == null || bytes.isEmpty) {
      setState(() {
        _preparing = false;
        _failed = true;
      });
      return false;
    }

    final mime = widget.message.mediaMimeHint ?? 'audio/webm';
    final blob = web.Blob(
      <JSAny>[bytes.toJS].toJS,
      web.BlobPropertyBag(type: mime),
    );
    final url = web.URL.createObjectURL(blob);
    _objectUrl = url;

    try {
      await _player.setUrl(url);
      await _player.setSpeed(_speed);
    } catch (_) {
      if (!mounted) return false;
      setState(() {
        _preparing = false;
        _failed = true;
      });
      return false;
    }

    _stateSub = _player.playerStateStream.listen((s) {
      if (s.processingState == ProcessingState.completed) {
        // Reset to the start so the play button works again — without the
        // seek, just_audio stays in the `completed` state and a second play()
        // is a no-op until the chat is reopened.
        _player.pause();
        _player.seek(Duration.zero);
        _VoicePlaybackCoordinator.deactivate(this);
      }
      if (mounted) setState(() {});
    });

    if (!mounted) return false;
    setState(() {
      _preparing = false;
      _prepared = true;
    });
    return true;
  }

  Future<void> _toggle() async {
    if (!await _prepare()) return;
    if (_player.playing) {
      await _player.pause();
    } else {
      // Finished (or parked at the end) → rewind before replaying, otherwise
      // just_audio's `completed` state swallows play().
      final total = _player.duration;
      if (_player.processingState == ProcessingState.completed ||
          (total != null && _player.position >= total)) {
        await _player.seek(Duration.zero);
      }
      _VoicePlaybackCoordinator.activate(this);
      await _player.play();
    }
  }

  Future<void> _seekToFraction(double fraction) async {
    if (!await _prepare()) return;
    final total = _player.duration ?? _storedDuration;
    if (total <= Duration.zero) return;
    final target = total * fraction.clamp(0.0, 1.0);
    await _player.seek(target);
  }

  void _cycleSpeed() {
    final next = _speed >= 2.0 ? 1.0 : (_speed >= 1.5 ? 2.0 : 1.5);
    _rememberedSpeed = next;
    setState(() => _speed = next);
    if (_prepared) _player.setSpeed(next);
  }

  String _fmt(Duration d) {
    final m = d.inMinutes;
    final s = d.inSeconds % 60;
    return '$m:${s.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final colors = widget.colors;
    final fg = widget.mine ? colors.textOnAccent : colors.textPrimary;
    final accent = widget.mine ? colors.textOnAccent : colors.accent;
    final muted = fg.withValues(alpha: 0.3);
    final playing = _player.playing;

    return StreamBuilder<Duration>(
      stream: _player.positionStream,
      builder: (context, posSnap) {
        final pos = _prepared ? (posSnap.data ?? Duration.zero) : Duration.zero;
        final total = (_player.duration ?? _storedDuration);
        final progress = total.inMilliseconds == 0
            ? 0.0
            : (pos.inMilliseconds / total.inMilliseconds).clamp(0.0, 1.0);
        final timeLabel = (_prepared && (playing || pos > Duration.zero))
            ? _fmt(pos)
            : _fmt(total);

        return SizedBox(
          width: 240,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              GestureDetector(
                onTap: _toggle,
                child: Container(
                  width: 44,
                  height: 44,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: accent.withValues(alpha: widget.mine ? 0.3 : 0.15),
                  ),
                  child: _preparing
                      ? Padding(
                          padding: const EdgeInsets.all(13),
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: accent,
                          ),
                        )
                      : Icon(
                          _failed
                              ? Icons.error_outline
                              : (playing ? Icons.pause : Icons.play_arrow),
                          color: accent,
                          size: 26,
                        ),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    SizedBox(
                      height: 30,
                      child: LayoutBuilder(
                        builder: (context, c) {
                          void seekAt(double dx) =>
                              _seekToFraction(dx / c.maxWidth);
                          return GestureDetector(
                            behavior: HitTestBehavior.opaque,
                            onTapDown: (d) => seekAt(d.localPosition.dx),
                            onHorizontalDragUpdate: (d) =>
                                seekAt(d.localPosition.dx),
                            child: CustomPaint(
                              size: Size(c.maxWidth, 30),
                              painter: _WaveformPainter(
                                samples: _bars,
                                progress: progress,
                                playedColor: accent,
                                bgColor: muted,
                              ),
                            ),
                          );
                        },
                      ),
                    ),
                    const SizedBox(height: 4),
                    Row(
                      children: [
                        Text(
                          _failed ? 'Не удалось загрузить' : timeLabel,
                          style: TextStyle(
                            fontSize: 12,
                            color: fg.withValues(alpha: 0.75),
                          ),
                        ),
                        const Spacer(),
                        // Speed toggle — only worth showing once there's audio
                        // loaded to apply it to.
                        if (_prepared)
                          GestureDetector(
                            onTap: _cycleSpeed,
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 8,
                                vertical: 2,
                              ),
                              decoration: BoxDecoration(
                                color: accent.withValues(alpha: 0.18),
                                borderRadius: BorderRadius.circular(10),
                              ),
                              child: Text(
                                _speed == 1.0
                                    ? '1×'
                                    : (_speed == 1.5 ? '1.5×' : '2×'),
                                style: TextStyle(
                                  fontSize: 11,
                                  fontWeight: FontWeight.w700,
                                  color: accent,
                                ),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _WaveformPainter extends CustomPainter {
  _WaveformPainter({
    required this.samples,
    required this.progress,
    required this.playedColor,
    required this.bgColor,
  });

  final List<int> samples;
  final double progress;
  final Color playedColor;
  final Color bgColor;

  @override
  void paint(Canvas canvas, Size size) {
    final n = samples.length;
    if (n == 0) return;
    const gap = 2.0;
    final barW = ((size.width - gap * (n - 1)) / n).clamp(1.5, 6.0);
    final maxH = size.height;
    final playedBars = progress * n;

    for (var i = 0; i < n; i++) {
      final v = (samples[i] / 100.0).clamp(0.0, 1.0);
      final h = (v * maxH).clamp(3.0, maxH);
      final x = i * (barW + gap);
      final top = (maxH - h) / 2;
      final paint = Paint()..color = i < playedBars ? playedColor : bgColor;
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(x, top, barW, h),
          Radius.circular(barW / 2),
        ),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(_WaveformPainter old) =>
      old.progress != progress ||
      old.playedColor != playedColor ||
      old.bgColor != bgColor ||
      old.samples != samples;
}

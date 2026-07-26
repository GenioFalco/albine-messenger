import 'dart:async';
import 'dart:js_interop';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:just_audio/just_audio.dart';
import 'package:web/web.dart' as web;

import '../../core/theme/albine_theme.dart';
import '../../data/providers.dart';
import '../../domain/models.dart';

/// Inline player for a `content_type == 'voice'` message. Lazily downloads and
/// decrypts the audio the first time it's played (so a screen full of voice
/// notes doesn't fetch them all at once), then plays the bytes via a blob URL —
/// just_audio's web backend only accepts a URL, and the plaintext must never
/// touch disk, so an in-memory object URL (revoked on dispose) is the right fit.
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
  final AudioPlayer _player = AudioPlayer();
  String? _objectUrl;
  bool _preparing = false;
  bool _prepared = false;
  bool _failed = false;
  StreamSubscription<PlayerState>? _stateSub;

  @override
  void dispose() {
    _stateSub?.cancel();
    _player.dispose();
    if (_objectUrl != null) web.URL.revokeObjectURL(_objectUrl!);
    super.dispose();
  }

  Future<void> _prepare() async {
    if (_prepared || _preparing) return;
    setState(() {
      _preparing = true;
      _failed = false;
    });

    final chat = ref.read(chatRepositoryProvider);
    final bytes = await chat?.fetchAndDecryptMedia(widget.message);
    if (!mounted) return;
    if (bytes == null || bytes.isEmpty) {
      setState(() {
        _preparing = false;
        _failed = true;
      });
      return;
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
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _preparing = false;
        _failed = true;
      });
      return;
    }

    _stateSub = _player.playerStateStream.listen((s) {
      if (s.processingState == ProcessingState.completed) {
        // Rewind to the start so the play button works again for a replay.
        _player.pause();
        _player.seek(Duration.zero);
      }
      if (mounted) setState(() {});
    });

    if (!mounted) return;
    setState(() {
      _preparing = false;
      _prepared = true;
    });
  }

  Future<void> _toggle() async {
    if (!_prepared) {
      await _prepare();
      if (!_prepared) return;
    }
    if (_player.playing) {
      await _player.pause();
    } else {
      await _player.play();
    }
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
    final playing = _player.playing;

    return StreamBuilder<Duration>(
      stream: _player.positionStream,
      builder: (context, posSnap) {
        final pos = posSnap.data ?? Duration.zero;
        final total = _player.duration ?? Duration.zero;
        final progress = total.inMilliseconds == 0
            ? 0.0
            : (pos.inMilliseconds / total.inMilliseconds).clamp(0.0, 1.0);

        return SizedBox(
          width: 220,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              GestureDetector(
                onTap: _toggle,
                child: Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: accent.withValues(alpha: widget.mine ? 0.28 : 0.15),
                  ),
                  child: _preparing
                      ? Padding(
                          padding: const EdgeInsets.all(11),
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
                        ),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    ClipRRect(
                      borderRadius: BorderRadius.circular(2),
                      child: LinearProgressIndicator(
                        value: _prepared ? progress : 0.0,
                        minHeight: 4,
                        backgroundColor: fg.withValues(alpha: 0.25),
                        valueColor: AlwaysStoppedAnimation<Color>(accent),
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      _failed
                          ? 'Не удалось загрузить'
                          : (_prepared
                                ? '${_fmt(pos)} / ${_fmt(total)}'
                                : '🎤 Голосовое сообщение'),
                      style: TextStyle(
                        fontSize: 12,
                        color: fg.withValues(alpha: 0.8),
                      ),
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

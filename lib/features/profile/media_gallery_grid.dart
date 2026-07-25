import 'dart:typed_data';

import 'package:flutter/cupertino.dart' show CupertinoIcons;
import 'package:flutter/material.dart';

import '../../core/media_download.dart';
import '../../core/theme/albine_theme.dart';
import '../../data/chat_repository.dart';
import '../../domain/models.dart';

/// Shared-media grid used by both the contact profile and group info
/// screens — every photo/video/file ever sent in a conversation, newest
/// first. Tapping a photo opens a minimal full-screen viewer (pinch-zoom +
/// implicit download via the top-level "..." elsewhere); video/file
/// thumbnails download directly on tap. This is a secondary "browse what's
/// been shared" view, not the primary chat experience, so it deliberately
/// doesn't reuse chat_screen's full reply/forward/delete viewer chrome —
/// those actions don't map cleanly onto "look at everything ever shared."
class MediaGalleryGrid extends StatefulWidget {
  const MediaGalleryGrid({
    super.key,
    required this.chat,
    required this.conversationId,
  });

  final ChatRepository chat;
  final String conversationId;

  @override
  State<MediaGalleryGrid> createState() => _MediaGalleryGridState();
}

class _MediaGalleryGridState extends State<MediaGalleryGrid> {
  late final Future<List<ChatMessage>> _future = widget.chat.fetchMediaMessages(
    widget.conversationId,
  );

  Future<void> _openOrDownload(ChatMessage message) async {
    final bytes = await widget.chat.fetchAndDecryptMedia(message);
    if (bytes == null || !mounted) return;
    if (message.contentType == 'image') {
      await showDialog<void>(
        context: context,
        barrierColor: Colors.black,
        builder: (_) => _SimpleImageViewer(bytes: bytes),
      );
      return;
    }
    final mime = message.mediaMimeHint ?? 'application/octet-stream';
    await saveMediaBytes(
      bytes: bytes,
      mime: mime,
      filename: suggestedMediaFilename(mime),
    );
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).extension<AlbineColors>()!;
    return FutureBuilder<List<ChatMessage>>(
      future: _future,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return const Padding(
            padding: EdgeInsets.all(24),
            child: Center(
              child: SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            ),
          );
        }
        final items = snapshot.data ?? const <ChatMessage>[];
        if (items.isEmpty) {
          return Padding(
            padding: const EdgeInsets.all(24),
            child: Center(
              child: Text(
                'Медиа ещё не отправляли',
                style: TextStyle(color: colors.textSecondary),
              ),
            ),
          );
        }
        return GridView.builder(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          padding: const EdgeInsets.all(2),
          gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: 3,
            crossAxisSpacing: 2,
            mainAxisSpacing: 2,
          ),
          itemCount: items.length,
          itemBuilder: (context, index) {
            final message = items[index];
            final isVideo =
                message.mediaMimeHint?.startsWith('video/') ?? false;
            final isImage = message.contentType == 'image';
            return InkWell(
              onTap: () => _openOrDownload(message),
              child: isImage
                  ? FutureBuilder<Uint8List?>(
                      future: widget.chat.fetchAndDecryptMedia(message),
                      builder: (context, snap) {
                        final bytes = snap.data;
                        if (bytes == null) {
                          return Container(color: colors.surface);
                        }
                        return Image.memory(bytes, fit: BoxFit.cover);
                      },
                    )
                  : Container(
                      color: colors.surface,
                      child: Icon(
                        isVideo
                            ? CupertinoIcons.play_circle_fill
                            : CupertinoIcons.doc_fill,
                        color: colors.textSecondary,
                        size: 28,
                      ),
                    ),
            );
          },
        );
      },
    );
  }
}

/// A minimal photo viewer for the gallery — pinch-zoom + close, no reply/
/// forward/delete chrome (see the class doc comment above for why).
class _SimpleImageViewer extends StatelessWidget {
  const _SimpleImageViewer({required this.bytes});

  final Uint8List bytes;

  @override
  Widget build(BuildContext context) {
    return Dialog.fullscreen(
      backgroundColor: Colors.black,
      child: SafeArea(
        child: Stack(
          children: [
            Center(
              child: LayoutBuilder(
                builder: (context, constraints) => InteractiveViewer(
                  child: SizedBox(
                    width: constraints.maxWidth,
                    height: constraints.maxHeight,
                    child: Image.memory(bytes, fit: BoxFit.contain),
                  ),
                ),
              ),
            ),
            Positioned(
              top: 4,
              left: 4,
              child: IconButton(
                icon: const Icon(
                  CupertinoIcons.xmark,
                  color: Colors.white,
                  size: 26,
                ),
                onPressed: () => Navigator.of(context).pop(),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

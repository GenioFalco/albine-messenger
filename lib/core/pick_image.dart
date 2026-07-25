import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';

/// Picked image bytes + a best-guess MIME type from the file extension —
/// shared by both avatar-upload flows (personal profile, group).
class PickedImage {
  const PickedImage({required this.bytes, required this.mime});

  final Uint8List bytes;
  final String mime;
}

Future<PickedImage?> pickImageBytes() async {
  final result = await FilePicker.pickFiles(
    type: FileType.image,
    withData: true,
  );
  final file = result?.files.singleOrNull;
  final bytes = file?.bytes;
  if (file == null || bytes == null) return null;

  final mime = switch (file.extension?.toLowerCase()) {
    'png' => 'image/png',
    'gif' => 'image/gif',
    'webp' => 'image/webp',
    'heic' => 'image/heic',
    _ => 'image/jpeg',
  };
  return PickedImage(bytes: bytes, mime: mime);
}

import 'dart:html' as html;
import 'dart:js_interop';
import 'dart:typed_data';

import 'package:web/web.dart' as web;

/// Extension a downloaded file should get so it actually opens/previews as
/// what it is — without this, the browser saves everything under a bare
/// name with no extension at all, so the OS has nothing to associate it with
/// and it just looks like a generic, nameless blob.
String extensionForMime(String mime) {
  switch (mime) {
    case 'image/png':
      return 'png';
    case 'image/jpeg':
      return 'jpg';
    case 'image/gif':
      return 'gif';
    case 'image/webp':
      return 'webp';
    case 'image/heic':
      return 'heic';
    case 'video/mp4':
      return 'mp4';
    case 'video/quicktime':
      return 'mov';
    case 'video/webm':
      return 'webm';
    case 'video/x-matroska':
      return 'mkv';
    case 'application/pdf':
      return 'pdf';
  }
  return 'bin';
}

/// A reasonable default filename ("photo.jpg", "video.mp4", "file.pdf", …)
/// for a downloaded attachment whose real name isn't known client-side.
String suggestedMediaFilename(String mime) {
  final baseName = mime.startsWith('image/')
      ? 'photo'
      : (mime.startsWith('video/') ? 'video' : 'file');
  return '$baseName.${extensionForMime(mime)}';
}

/// Tries the Web Share API's file-sharing capability so mobile browsers show
/// their own native OS share/save sheet — the same "Save Image"/"Save to
/// Photos" prompt a native app gets — instead of a silent, unprompted
/// download. Desktop browsers generally don't support sharing files at all,
/// so `canShare` naturally comes back false there and the caller falls
/// through to the classic download-link trick, which is the normal/expected
/// desktop behavior.
///
/// Returns true once a real native sheet was shown — whatever the user then
/// chose there (including cancelling) counts as "handled", since there's no
/// reason to also silently fall through to a second download right after
/// someone dismissed a real prompt. Only returns false when the browser
/// doesn't support sharing files at all (`canShare` itself is the standard
/// feature-detection call for this).
Future<bool> _tryNativeShare(
  Uint8List bytes,
  String mime,
  String filename,
) async {
  final navigator = web.window.navigator;
  final file = web.File(
    [bytes.toJS].toJS,
    filename,
    web.FilePropertyBag(type: mime),
  );
  final shareData = web.ShareData(files: [file].toJS);
  bool canShare;
  try {
    canShare = navigator.canShare(shareData);
  } catch (_) {
    return false;
  }
  if (!canShare) return false;
  try {
    await navigator.share(shareData).toDart;
  } catch (_) {
    // Covers the user cancelling the native sheet (an AbortError) as well as
    // any other failure once the real prompt was already shown.
  }
  return true;
}

/// Saves [bytes] to the user's device — the native share/save sheet where
/// supported (mobile), falling back to the classic Blob + `<a download>`
/// trick otherwise (desktop, or a browser without file-sharing support;
/// Flutter Web has no filesystem access, so this is the standard way to
/// trigger a download of in-memory bytes).
Future<void> saveMediaBytes({
  required Uint8List bytes,
  required String mime,
  required String filename,
}) async {
  if (await _tryNativeShare(bytes, mime, filename)) return;

  final blob = html.Blob([bytes], mime);
  final url = html.Url.createObjectUrlFromBlob(blob);
  html.AnchorElement(href: url)
    ..setAttribute('download', filename)
    ..click();
  html.Url.revokeObjectUrl(url);
}

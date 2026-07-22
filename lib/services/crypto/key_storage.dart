import 'dart:convert';
import 'dart:typed_data';

import 'package:shared_preferences/shared_preferences.dart';

import 'crypto_models.dart';

/// Where the wrapped (Argon2id-encrypted) private key lives on this device.
///
/// v1 implementation note: this uses `shared_preferences`, which on Flutter
/// Web is backed by `localStorage` rather than IndexedDB as originally
/// sketched in the design doc. Both have identical risk properties for our
/// purposes (cleared by "clear site data", private browsing, etc. — there is
/// no server-side escrow either way) so this is a simplification, not a
/// weakening: swapping to raw IndexedDB later means touching only this file.
abstract class KeyStorage {
  Future<void> saveWrappedPrivateKey(String userId, WrappedSecret wrapped);
  Future<WrappedSecret?> loadWrappedPrivateKey(String userId);
  Future<void> clear(String userId);

  /// The *unwrapped* identity secret key, cached locally once the user has
  /// successfully unlocked with their password, so a full page reload skips
  /// re-entering it. Only [clearUnlockedSecretKey] (called on explicit
  /// sign-out) removes it — a deliberate trade-off the user chose: browser/
  /// device compromise can now read this without the password, same model
  /// WhatsApp/Telegram/Signal Web already use. The server-side backup and
  /// the password-wrapped copy above still protect against a genuinely new
  /// device and against a server-side breach either way.
  Future<void> saveUnlockedSecretKey(String userId, Uint8List secretKeyBytes);
  Future<Uint8List?> loadUnlockedSecretKey(String userId);
  Future<void> clearUnlockedSecretKey(String userId);

  /// Identity secret keys retired by "rotate my key" (see
  /// `SessionController.rotateIdentityKey`), most-recent first, tried in
  /// order when the *current* key fails to decrypt an old message. Local-
  /// only, deliberately not backed up server-side — rotating is meant to cut
  /// a suspected-compromised key off from the server-recoverable path
  /// entirely, not just add another copy of it there.
  Future<void> addRetiredSecretKey(String userId, Uint8List secretKeyBytes);
  Future<List<Uint8List>> loadRetiredSecretKeys(String userId);
}

class LocalKeyStorage implements KeyStorage {
  static const _maxRetiredKeys = 10;

  String _keyFor(String userId) => 'albine.wrapped_identity_key.$userId';
  String _unlockedKeyFor(String userId) =>
      'albine.unlocked_identity_key.$userId';
  String _retiredKeysFor(String userId) =>
      'albine.retired_identity_keys.$userId';

  @override
  Future<void> saveWrappedPrivateKey(
    String userId,
    WrappedSecret wrapped,
  ) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_keyFor(userId), jsonEncode(wrapped.toJson()));
  }

  @override
  Future<WrappedSecret?> loadWrappedPrivateKey(String userId) async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_keyFor(userId));
    if (raw == null) return null;
    return WrappedSecret.fromJson(jsonDecode(raw) as Map<String, dynamic>);
  }

  @override
  Future<void> clear(String userId) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_keyFor(userId));
  }

  @override
  Future<void> saveUnlockedSecretKey(
    String userId,
    Uint8List secretKeyBytes,
  ) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _unlockedKeyFor(userId),
      base64Encode(secretKeyBytes),
    );
  }

  @override
  Future<Uint8List?> loadUnlockedSecretKey(String userId) async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_unlockedKeyFor(userId));
    if (raw == null) return null;
    return base64Decode(raw);
  }

  @override
  Future<void> clearUnlockedSecretKey(String userId) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_unlockedKeyFor(userId));
  }

  @override
  Future<void> addRetiredSecretKey(
    String userId,
    Uint8List secretKeyBytes,
  ) async {
    final prefs = await SharedPreferences.getInstance();
    final key = _retiredKeysFor(userId);
    final raw = prefs.getString(key);
    final list = raw == null
        ? <String>[]
        : List<String>.from(jsonDecode(raw) as List);
    list.insert(0, base64Encode(secretKeyBytes));
    if (list.length > _maxRetiredKeys) {
      list.removeRange(_maxRetiredKeys, list.length);
    }
    await prefs.setString(key, jsonEncode(list));
  }

  @override
  Future<List<Uint8List>> loadRetiredSecretKeys(String userId) async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_retiredKeysFor(userId));
    if (raw == null) return [];
    final list = List<String>.from(jsonDecode(raw) as List);
    return [for (final s in list) base64Decode(s)];
  }
}

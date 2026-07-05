import 'dart:convert';

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
}

class LocalKeyStorage implements KeyStorage {
  String _keyFor(String userId) => 'albine.wrapped_identity_key.$userId';

  @override
  Future<void> saveWrappedPrivateKey(String userId, WrappedSecret wrapped) async {
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
}

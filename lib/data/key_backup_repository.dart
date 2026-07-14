import 'dart:convert';

import 'package:supabase_flutter/supabase_flutter.dart';

import '../services/crypto/crypto_models.dart';

/// Server-side counterpart to `KeyStorage`: the same `WrappedSecret` shape,
/// just persisted in Supabase instead of `shared_preferences` so a new
/// device can recover it with the account password. See
/// `supabase/migrations/0002_key_backup.sql` for the RLS story (owner-only).
class KeyBackupRepository {
  KeyBackupRepository(this._client);

  final SupabaseClient _client;

  Future<WrappedSecret?> fetchBackup(String userId) async {
    final row = await _client.from('key_backups').select().eq('user_id', userId).maybeSingle();
    if (row == null) return null;
    return WrappedSecret(
      salt: base64Decode(row['wrapped_salt'] as String),
      nonce: base64Decode(row['wrapped_nonce'] as String),
      ciphertext: base64Decode(row['wrapped_ciphertext'] as String),
    );
  }

  Future<void> upsertBackup(String userId, WrappedSecret wrapped) {
    return _client.from('key_backups').upsert({
      'user_id': userId,
      'wrapped_salt': base64Encode(wrapped.salt),
      'wrapped_nonce': base64Encode(wrapped.nonce),
      'wrapped_ciphertext': base64Encode(wrapped.ciphertext),
      'updated_at': DateTime.now().toUtc().toIso8601String(),
    });
  }
}

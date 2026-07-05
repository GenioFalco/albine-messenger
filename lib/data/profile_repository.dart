import 'dart:convert';
import 'dart:typed_data';

import 'package:supabase_flutter/supabase_flutter.dart';

import '../domain/models.dart';

class ProfileRepository {
  ProfileRepository(this._client);

  final SupabaseClient _client;

  Future<AppProfile?> fetchProfile(String userId) async {
    final row = await _client.from('profiles').select().eq('id', userId).maybeSingle();
    return row == null ? null : AppProfile.fromRow(row);
  }

  Future<AppProfile?> findByUsername(String username) async {
    final row = await _client
        .from('profiles')
        .select()
        .eq('username', username.trim().toLowerCase())
        .maybeSingle();
    return row == null ? null : AppProfile.fromRow(row);
  }

  Future<bool> isUsernameTaken(String username) async {
    final row = await _client
        .from('profiles')
        .select('id')
        .eq('username', username.trim().toLowerCase())
        .maybeSingle();
    return row != null;
  }

  Future<AppProfile> createProfile({
    required String id,
    required String username,
    required String displayName,
    required Uint8List identityPubkey,
  }) async {
    final row = await _client
        .from('profiles')
        .insert({
          'id': id,
          'username': username.trim().toLowerCase(),
          'display_name': displayName.trim(),
          'identity_pubkey': base64Encode(identityPubkey),
        })
        .select()
        .single();
    return AppProfile.fromRow(row);
  }

  /// Overwrites the public key on file for this account — used when a
  /// device has no local wrapped private key (new device, cleared storage)
  /// and a fresh keypair was generated to replace the unrecoverable old one.
  Future<void> updateIdentityPubkey({required String userId, required Uint8List identityPubkey}) {
    return _client
        .from('profiles')
        .update({'identity_pubkey': base64Encode(identityPubkey)})
        .eq('id', userId);
  }
}

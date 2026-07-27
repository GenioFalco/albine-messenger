import 'dart:convert';
import 'dart:typed_data';

import 'package:libsignal_protocol_dart/libsignal_protocol_dart.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../domain/models.dart';

/// Everything a [PreKeyBundle] needs for [peer], fetched fresh (the
/// one-time prekey, if any, is atomically claimed and will never be handed
/// out again — see `claim_one_time_prekey` in
/// `supabase/migrations/0003_signal_prekeys.sql`).
class SignalBundleRow {
  const SignalBundleRow({
    required this.registrationId,
    required this.signedPreKeyId,
    required this.signedPreKeyPublic,
    required this.signedPreKeySignature,
    this.oneTimePreKeyId,
    this.oneTimePreKeyPublic,
  });

  final int registrationId;
  final int signedPreKeyId;
  final Uint8List signedPreKeyPublic;
  final Uint8List signedPreKeySignature;
  final int? oneTimePreKeyId;
  final Uint8List? oneTimePreKeyPublic;
}

/// The server-facing half of forward secrecy: publishing this device's own
/// prekey bundle, and fetching a contact's bundle to start a session with
/// them. All the actual Double Ratchet logic stays in `SignalService` /
/// `SignalLocalStore` — this is pure network I/O, same split as
/// `ProfileRepository`/`KeyBackupRepository`.
class SignalDirectoryRepository {
  SignalDirectoryRepository(this._client);

  final SupabaseClient _client;

  Future<void> upsertRegistrationId(String userId, int registrationId) {
    return _client
        .from('profiles')
        .update({'signal_registration_id': registrationId})
        .eq('id', userId);
  }

  Future<void> upsertSignedPreKey({
    required String userId,
    required int keyId,
    required Uint8List publicKey,
    required Uint8List signature,
  }) {
    return _client.from('signed_prekeys').upsert({
      'user_id': userId,
      'key_id': keyId,
      'public_key': base64Encode(publicKey),
      'signature': base64Encode(signature),
      'created_at': DateTime.now().toUtc().toIso8601String(),
    });
  }

  /// Deletes this account's entire published prekey bundle (signed + all
  /// one-time). Used when the local store is fresh/reset but the server still
  /// holds prekeys whose private halves are gone — republishing over a clean
  /// slate is the only way to stop peers claiming dead prekeys (see
  /// `SignalService.ensureBootstrapped` / `republishOwnPreKeys`). Needs the
  /// owner-delete policies added in 0013_prekey_repair_and_read_rpc.sql.
  Future<void> deleteAllOwnPreKeys(String userId) async {
    await _client.from('one_time_prekeys').delete().eq('user_id', userId);
    await _client.from('signed_prekeys').delete().eq('user_id', userId);
  }

  Future<int> countOwnOneTimePreKeys(String userId) async {
    final rows = await _client
        .from('one_time_prekeys')
        .select('key_id')
        .eq('user_id', userId);
    return rows.length;
  }

  Future<void> insertOneTimePreKeys(
    String userId,
    List<PreKeyRecord> records,
  ) async {
    if (records.isEmpty) return;
    await _client.from('one_time_prekeys').insert([
      for (final r in records)
        {
          'user_id': userId,
          'key_id': r.id,
          'public_key': base64Encode(r.getKeyPair().publicKey.serialize()),
        },
    ]);
  }

  /// Null means [peer] hasn't bootstrapped their Signal key material yet
  /// (no `signed_prekeys` row) — caller should fall back to crypto_box.
  Future<SignalBundleRow?> fetchBundle(AppProfile peer) async {
    final registrationId = peer.signalRegistrationId;
    if (registrationId == null) return null;

    final signedRow = await _client
        .from('signed_prekeys')
        .select()
        .eq('user_id', peer.id)
        .maybeSingle();
    if (signedRow == null) return null;

    // One-time prekeys are deliberately no longer used (see
    // SignalService.republishOwnPreKeys for the full rationale): they were the
    // sole cause of the recurring "No such prekey" desync. X3DH establishes a
    // session from the signed prekey alone, so we never claim one here — the
    // bundle always goes out with a null one-time prekey.
    return SignalBundleRow(
      registrationId: registrationId,
      signedPreKeyId: signedRow['key_id'] as int,
      signedPreKeyPublic: base64Decode(signedRow['public_key'] as String),
      signedPreKeySignature: base64Decode(signedRow['signature'] as String),
      oneTimePreKeyId: null,
      oneTimePreKeyPublic: null,
    );
  }
}

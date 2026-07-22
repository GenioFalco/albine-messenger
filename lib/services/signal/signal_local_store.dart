import 'dart:convert';

import 'package:libsignal_protocol_dart/libsignal_protocol_dart.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Local persistence for one account's Signal (Double Ratchet) key material:
/// identity keypair, signed prekey, unconsumed one-time prekeys, and one
/// ratchet session per contact. Backed by `shared_preferences`, same trust
/// model as `KeyStorage` (v1 threat model is server compromise, not local
/// device compromise — see `key_storage.dart`'s doc comment).
///
/// Deliberately not password-wrapped like the legacy identity key: Signal's
/// SessionCipher needs to sign/decrypt continuously without prompting for a
/// password on every message, matching how real Signal clients rely on
/// device-level storage protection rather than a passphrase gate.
class SignalLocalStore implements SignalProtocolStore {
  SignalLocalStore(this.userId);

  final String userId;

  String get _identityKey => 'albine.signal.identity.$userId';
  String get _regIdKey => 'albine.signal.regid.$userId';
  String get _signedPreKeysKey => 'albine.signal.signedprekeys.$userId';
  String get _currentSignedPreKeyIdKey =>
      'albine.signal.signedprekey.current.$userId';
  String get _preKeysKey => 'albine.signal.prekeys.$userId';
  String get _preKeyCounterKey => 'albine.signal.prekeycounter.$userId';
  String get _sessionsKey => 'albine.signal.sessions.$userId';

  Future<Map<String, dynamic>> _readMap(String key) async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(key);
    if (raw == null) return {};
    return jsonDecode(raw) as Map<String, dynamic>;
  }

  Future<void> _writeMap(String key, Map<String, dynamic> map) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(key, jsonEncode(map));
  }

  // ---- bootstrap bookkeeping ----

  Future<bool> hasIdentity() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.containsKey(_identityKey);
  }

  Future<void> saveIdentityKeyPair(
    IdentityKeyPair pair,
    int registrationId,
  ) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_identityKey, base64Encode(pair.serialize()));
    await prefs.setInt(_regIdKey, registrationId);
  }

  Future<int?> currentSignedPreKeyId() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getInt(_currentSignedPreKeyIdKey);
  }

  Future<void> setCurrentSignedPreKeyId(int id) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_currentSignedPreKeyIdKey, id);
  }

  Future<int> unconsumedPreKeyCount() async =>
      (await _readMap(_preKeysKey)).length;

  /// Full reset — used by "rotate my key" (see
  /// `SessionController.rotateIdentityKey`): a suspected-compromised device
  /// may have had its *session* states copied too, not just the identity
  /// key, so this clears everything (identity, registration id, signed/
  /// one-time prekeys, and every contact's session) rather than just the
  /// identity, forcing a completely fresh bootstrap and fresh X3DH
  /// handshakes with everyone going forward.
  Future<void> resetAll() async {
    final prefs = await SharedPreferences.getInstance();
    for (final key in [
      _identityKey,
      _regIdKey,
      _signedPreKeysKey,
      _currentSignedPreKeyIdKey,
      _preKeysKey,
      _preKeyCounterKey,
      _sessionsKey,
    ]) {
      await prefs.remove(key);
    }
  }

  /// Reserves [count] fresh, never-reused one-time-prekey ids for this
  /// account (a monotonic counter, independent of how many earlier ids have
  /// since been consumed+removed) so newly generated prekeys can never
  /// collide with ones already published server-side.
  Future<int> reserveNextPreKeyIds(int count) async {
    final prefs = await SharedPreferences.getInstance();
    final start = (prefs.getInt(_preKeyCounterKey) ?? 0) + 1;
    await prefs.setInt(_preKeyCounterKey, start + count - 1);
    return start;
  }

  // ---- IdentityKeyStore ----

  @override
  Future<IdentityKeyPair> getIdentityKeyPair() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_identityKey);
    if (raw == null) {
      throw StateError('Signal identity not bootstrapped for $userId');
    }
    return IdentityKeyPair.fromSerialized(base64Decode(raw));
  }

  @override
  Future<int> getLocalRegistrationId() async {
    final prefs = await SharedPreferences.getInstance();
    final id = prefs.getInt(_regIdKey);
    if (id == null) {
      throw StateError('Signal registration id not bootstrapped for $userId');
    }
    return id;
  }

  @override
  Future<bool> saveIdentity(
    SignalProtocolAddress address,
    IdentityKey? identityKey,
  ) async {
    // v1: trust-on-first-use, no persistent per-contact identity pinning or
    // safety-number UI exists yet — same posture as the legacy crypto_box
    // path, which re-trusts whatever `profiles.identity_pubkey` says on
    // every unlock. Nothing to persist.
    return true;
  }

  @override
  Future<bool> isTrustedIdentity(
    SignalProtocolAddress address,
    IdentityKey? identityKey,
    Direction direction,
  ) async => true;

  @override
  Future<IdentityKey?> getIdentity(SignalProtocolAddress address) async => null;

  // ---- SignedPreKeyStore ----

  @override
  Future<SignedPreKeyRecord> loadSignedPreKey(int signedPreKeyId) async {
    final map = await _readMap(_signedPreKeysKey);
    final raw = map['$signedPreKeyId'] as String?;
    if (raw == null)
      throw InvalidKeyIdException('No such signed prekey: $signedPreKeyId');
    return SignedPreKeyRecord.fromSerialized(base64Decode(raw));
  }

  @override
  Future<List<SignedPreKeyRecord>> loadSignedPreKeys() async {
    final map = await _readMap(_signedPreKeysKey);
    return [
      for (final raw in map.values)
        SignedPreKeyRecord.fromSerialized(base64Decode(raw as String)),
    ];
  }

  @override
  Future<void> storeSignedPreKey(
    int signedPreKeyId,
    SignedPreKeyRecord record,
  ) async {
    final map = await _readMap(_signedPreKeysKey);
    map['$signedPreKeyId'] = base64Encode(record.serialize());
    await _writeMap(_signedPreKeysKey, map);
  }

  @override
  Future<bool> containsSignedPreKey(int signedPreKeyId) async {
    final map = await _readMap(_signedPreKeysKey);
    return map.containsKey('$signedPreKeyId');
  }

  @override
  Future<void> removeSignedPreKey(int signedPreKeyId) async {
    final map = await _readMap(_signedPreKeysKey);
    map.remove('$signedPreKeyId');
    await _writeMap(_signedPreKeysKey, map);
  }

  // ---- PreKeyStore ----

  @override
  Future<PreKeyRecord> loadPreKey(int preKeyId) async {
    final map = await _readMap(_preKeysKey);
    final raw = map['$preKeyId'] as String?;
    if (raw == null) throw InvalidKeyIdException('No such prekey: $preKeyId');
    return PreKeyRecord.fromBuffer(base64Decode(raw));
  }

  @override
  Future<void> storePreKey(int preKeyId, PreKeyRecord record) async {
    final map = await _readMap(_preKeysKey);
    map['$preKeyId'] = base64Encode(record.serialize());
    await _writeMap(_preKeysKey, map);
  }

  @override
  Future<bool> containsPreKey(int preKeyId) async {
    final map = await _readMap(_preKeysKey);
    return map.containsKey('$preKeyId');
  }

  @override
  Future<void> removePreKey(int preKeyId) async {
    final map = await _readMap(_preKeysKey);
    map.remove('$preKeyId');
    await _writeMap(_preKeysKey, map);
  }

  // ---- SessionStore ----

  String _addressKey(SignalProtocolAddress address) =>
      '${address.getName()}:${address.getDeviceId()}';

  @override
  Future<SessionRecord> loadSession(SignalProtocolAddress address) async {
    final map = await _readMap(_sessionsKey);
    final raw = map[_addressKey(address)] as String?;
    if (raw == null) return SessionRecord();
    return SessionRecord.fromSerialized(base64Decode(raw));
  }

  @override
  Future<List<int>> getSubDeviceSessions(String name) async {
    final map = await _readMap(_sessionsKey);
    return [
      for (final k in map.keys)
        if (k.startsWith('$name:')) int.parse(k.split(':').last),
    ];
  }

  @override
  Future<void> storeSession(
    SignalProtocolAddress address,
    SessionRecord record,
  ) async {
    final map = await _readMap(_sessionsKey);
    map[_addressKey(address)] = base64Encode(record.serialize());
    await _writeMap(_sessionsKey, map);
  }

  @override
  Future<bool> containsSession(SignalProtocolAddress address) async {
    final map = await _readMap(_sessionsKey);
    return map.containsKey(_addressKey(address));
  }

  @override
  Future<void> deleteSession(SignalProtocolAddress address) async {
    final map = await _readMap(_sessionsKey);
    map.remove(_addressKey(address));
    await _writeMap(_sessionsKey, map);
  }

  @override
  Future<void> deleteAllSessions(String name) async {
    final map = await _readMap(_sessionsKey);
    map.removeWhere((k, _) => k.startsWith('$name:'));
    await _writeMap(_sessionsKey, map);
  }
}

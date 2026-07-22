import 'dart:async';
import 'dart:typed_data';

import 'package:libsignal_protocol_dart/libsignal_protocol_dart.dart';

import '../../data/signal_directory_repository.dart';
import '../../domain/models.dart';
import 'signal_local_store.dart';

class SignalMessageEnvelope {
  const SignalMessageEnvelope({
    required this.serialized,
    required this.messageType,
  });
  final Uint8List serialized;
  final int messageType;
}

/// The only thing other code calls for forward-secret 1:1 messaging —
/// mirrors how `crypto_service.dart` is the sole libsodium boundary for the
/// legacy path. Owns bootstrapping this device's key material and
/// establishing/using a Double Ratchet session per contact via
/// `libsignal_protocol_dart` (X3DH + Double Ratchet + XEdDSA).
class SignalService {
  SignalService({
    required SignalLocalStore store,
    required SignalDirectoryRepository directory,
    required String myUserId,
  }) : _store = store,
       _directory = directory,
       _myUserId = myUserId;

  final SignalLocalStore _store;
  final SignalDirectoryRepository _directory;
  final String _myUserId;

  static const _oneTimePreKeyTarget = 20;
  static const _oneTimePreKeyLowWaterMark = 10;
  static const _signedPreKeyMaxAge = Duration(days: 7);

  /// Serializes every operation that touches a given lock key (a contact's
  /// session, or one user's own prekey bootstrap) so overlapping callers
  /// never race to read-modify-write the same `SignalLocalStore` blob — the
  /// root cause of a real production regression (two independent async
  /// pipelines — the conversation list and an open chat — both prewarming
  /// the same contact's session concurrently desynced the Double Ratchet
  /// for both parties, since `SessionCipher.encrypt()`/`decrypt()` each do
  /// their own `loadSession()` ... `storeSession()` with async work between,
  /// so the critical section spans outside any single store method).
  ///
  /// Deliberately `static` rather than an instance field: `SessionController`
  /// constructs its own short-lived `SignalService` for `ensureBootstrapped`
  /// separately from the one `signalServiceProvider` hands to `ChatRepository`
  /// — both operate on the same underlying storage keys, so only a lock
  /// shared across instances actually closes the race.
  static final Map<String, Future<void>> _locks = {};

  Future<T> _withLock<T>(String key, Future<T> Function() action) {
    final previous = _locks[key] ?? Future<void>.value();
    final done = Completer<void>();
    _locks[key] = done.future;
    return previous.then((_) async {
      try {
        return await action();
      } finally {
        done.complete();
      }
    });
  }

  String _contactLockKey(String contactId) => 'contact:$_myUserId:$contactId';

  /// Generates (once) and periodically refreshes this device's Signal key
  /// material, publishing the public halves. Cheap to call every time the
  /// session becomes ready — a no-op most of the time.
  ///
  /// [identitySecretKeyBytes] is the already-unlocked legacy X25519 identity
  /// secret key: the same long-term key backs both the crypto_box path and
  /// Signal's X3DH/ratchet (via XEdDSA), so there's only ever one identity
  /// key to manage or back up, not two.
  Future<void> ensureBootstrapped(Uint8List identitySecretKeyBytes) {
    return _withLock('bootstrap:$_myUserId', () async {
      if (!await _store.hasIdentity()) {
        final identityKeyPair = generateIdentityKeyPairFromPrivate(
          identitySecretKeyBytes,
        );
        final registrationId = generateRegistrationId(false);
        await _store.saveIdentityKeyPair(identityKeyPair, registrationId);
        await _directory.upsertRegistrationId(_myUserId, registrationId);
      }

      final identityKeyPair = await _store.getIdentityKeyPair();
      await _rotateSignedPreKeyIfNeeded(identityKeyPair);
      await _topUpOneTimePreKeys();
    });
  }

  Future<void> _rotateSignedPreKeyIfNeeded(
    IdentityKeyPair identityKeyPair,
  ) async {
    final currentId = await _store.currentSignedPreKeyId();
    if (currentId != null) {
      final record = await _store.loadSignedPreKey(currentId);
      final age = DateTime.now().difference(
        DateTime.fromMillisecondsSinceEpoch(record.timestamp.toInt()),
      );
      if (age < _signedPreKeyMaxAge) return;
    }

    final nextId = (currentId ?? 0) + 1;
    final record = generateSignedPreKey(identityKeyPair, nextId);
    await _store.storeSignedPreKey(nextId, record);
    await _store.setCurrentSignedPreKeyId(nextId);
    await _directory.upsertSignedPreKey(
      userId: _myUserId,
      keyId: nextId,
      publicKey: record.getKeyPair().publicKey.serialize(),
      signature: record.signature,
    );
  }

  Future<void> _topUpOneTimePreKeys() async {
    final remaining = await _directory.countOwnOneTimePreKeys(_myUserId);
    if (remaining >= _oneTimePreKeyLowWaterMark) return;

    final toGenerate = _oneTimePreKeyTarget - remaining;
    final startId = await _store.reserveNextPreKeyIds(toGenerate);
    final records = generatePreKeys(startId, toGenerate);
    for (final record in records) {
      await _store.storePreKey(record.id, record);
    }
    await _directory.insertOneTimePreKeys(_myUserId, records);
  }

  /// Encrypts [plaintext] for [peer], establishing a session first if none
  /// exists yet. Returns null if [peer] hasn't published Signal key
  /// material at all (hasn't opened the app since forward secrecy shipped)
  /// — the caller should fall back to the legacy crypto_box path for this
  /// send. Any other failure (network error, invalid signature, ...)
  /// propagates instead of silently downgrading an otherwise-viable send.
  Future<SignalMessageEnvelope?> encryptForContact(
    AppProfile peer,
    Uint8List plaintext,
  ) {
    return _withLock(_contactLockKey(peer.id), () async {
      final address = SignalProtocolAddress(peer.id, 1);

      if (!await _store.containsSession(address)) {
        final bundleRow = await _directory.fetchBundle(peer);
        if (bundleRow == null) return null;

        final bundle = PreKeyBundle(
          bundleRow.registrationId,
          1,
          bundleRow.oneTimePreKeyId,
          bundleRow.oneTimePreKeyPublic == null
              ? null
              : Curve.decodePoint(bundleRow.oneTimePreKeyPublic!, 0),
          bundleRow.signedPreKeyId,
          Curve.decodePoint(bundleRow.signedPreKeyPublic, 0),
          bundleRow.signedPreKeySignature,
          IdentityKey(DjbECPublicKey(peer.identityPubkey)),
        );

        await SessionBuilder.fromSignalStore(
          _store,
          address,
        ).processPreKeyBundle(bundle);
      }

      final cipher = SessionCipher.fromStore(_store, address);
      final message = await cipher.encrypt(plaintext);
      return SignalMessageEnvelope(
        serialized: message.serialize(),
        messageType: message.getType(),
      );
    });
  }

  Future<Uint8List> decryptFromContact(
    String peerId,
    Uint8List ciphertext,
    int messageType,
  ) {
    return _withLock(_contactLockKey(peerId), () async {
      final address = SignalProtocolAddress(peerId, 1);
      final cipher = SessionCipher.fromStore(_store, address);
      if (messageType == CiphertextMessage.prekeyType) {
        return cipher.decrypt(PreKeySignalMessage(ciphertext));
      }
      return cipher.decryptFromSignal(SignalMessage.fromSerialized(ciphertext));
    });
  }

  /// Deletes the local session with [contactId], so the *next* message
  /// to/from them triggers a fresh X3DH handshake instead of the
  /// conversation staying permanently broken. Used as self-healing after a
  /// decrypt failure (see `ChatRepository._prewarmSignalDecryption`) — the
  /// message that already failed stays unrecoverable (that's forward
  /// secrecy working as intended), but the conversation recovers going
  /// forward without any manual action.
  Future<void> resetSessionWith(String contactId) {
    return _withLock(_contactLockKey(contactId), () {
      return _store.deleteSession(SignalProtocolAddress(contactId, 1));
    });
  }
}

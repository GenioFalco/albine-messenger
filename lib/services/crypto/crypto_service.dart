import 'dart:convert';
import 'dart:typed_data';

import 'package:sodium/sodium_sumo.dart';

import 'crypto_models.dart';

/// Everything the app needs from libsodium, behind one interface so the
/// primitives (and only the primitives) are the single place the E2E
/// guarantee lives or dies. Nothing outside this file should touch `Sodium`
/// directly.
abstract class CryptoService {
  Future<void> ensureReady();

  /// New X25519 identity keypair, generated once at profile creation.
  IdentityKeyPair generateIdentityKeyPair();

  /// Rebuilds a keypair from a raw secret key unwrapped from local storage
  /// and verifies it against the public key stored server-side in `profiles`.
  IdentityKeyPair? restoreIdentityKeyPair({
    required Uint8List secretKeyBytes,
    required Uint8List expectedPublicKey,
  });

  /// Encrypts [secret] with a key derived from [passphrase] via Argon2id.
  /// This is what turns a raw private key into something safe to put in
  /// local storage.
  WrappedSecret wrapSecret({required Uint8List secret, required String passphrase});

  /// Reverses [wrapSecret]. Throws [SodiumException] if [passphrase] is wrong.
  Uint8List unwrapSecret({required WrappedSecret wrapped, required String passphrase});

  /// 1:1 messages: crypto_box (X25519 + XSalsa20-Poly1305) — libsodium's
  /// standard authenticated-encryption box for exactly this two-party case.
  EncryptedPayload encryptDirectMessage({
    required SecureKey mySecretKey,
    required Uint8List theirPublicKey,
    required Uint8List plaintext,
  });

  Uint8List decryptDirectMessage({
    required SecureKey mySecretKey,
    required Uint8List theirPublicKey,
    required EncryptedPayload payload,
  });

  /// Groups: one random symmetric key per group.
  SecureKey generateGroupKey();

  /// Wraps [groupKey] so only the holder of [memberPublicKey]'s private key
  /// can open it (crypto_box_seal — anonymous sealed box).
  Uint8List sealGroupKeyForMember({
    required Uint8List memberPublicKey,
    required SecureKey groupKey,
  });

  SecureKey openSealedGroupKey({
    required IdentityKeyPair myKeyPair,
    required Uint8List sealed,
  });

  /// Group messages: true symmetric AEAD (XChaCha20-Poly1305), bound to the
  /// conversation id via additionalData.
  EncryptedPayload encryptGroupMessage({
    required SecureKey groupKey,
    required String conversationId,
    required Uint8List plaintext,
  });

  Uint8List decryptGroupMessage({
    required SecureKey groupKey,
    required String conversationId,
    required EncryptedPayload payload,
  });
}

class SodiumCryptoService implements CryptoService {
  SodiumSumo? _sodium;

  SodiumSumo get _s {
    final sodium = _sodium;
    if (sodium == null) {
      throw StateError('CryptoService.ensureReady() was not called yet.');
    }
    return sodium;
  }

  @override
  Future<void> ensureReady() async {
    _sodium ??= await SodiumSumoInit.init();
  }

  @override
  IdentityKeyPair generateIdentityKeyPair() {
    final pair = _s.crypto.box.keyPair();
    return IdentityKeyPair(publicKey: pair.publicKey, secretKey: pair.secretKey);
  }

  @override
  IdentityKeyPair? restoreIdentityKeyPair({
    required Uint8List secretKeyBytes,
    required Uint8List expectedPublicKey,
  }) {
    final secretKey = _s.secureCopy(secretKeyBytes);
    final derivedPublicKey = _s.crypto.scalarmult.base(n: secretKey);
    if (!_bytesEqual(derivedPublicKey, expectedPublicKey)) {
      secretKey.dispose();
      return null;
    }
    return IdentityKeyPair(publicKey: derivedPublicKey, secretKey: secretKey);
  }

  @override
  WrappedSecret wrapSecret({required Uint8List secret, required String passphrase}) {
    final pwhash = _s.crypto.pwhash;
    final aead = _s.crypto.aeadXChaCha20Poly1305IETF;

    final salt = _s.randombytes.buf(pwhash.saltBytes);
    final derivedKey = pwhash(
      outLen: aead.keyBytes,
      password: passphrase.toCharArray(),
      salt: salt,
      opsLimit: pwhash.opsLimitInteractive,
      memLimit: pwhash.memLimitInteractive,
      alg: CryptoPwhashAlgorithm.argon2id13,
    );

    final nonce = _s.randombytes.buf(aead.nonceBytes);
    try {
      final ciphertext = aead.encrypt(message: secret, nonce: nonce, key: derivedKey);
      return WrappedSecret(salt: salt, nonce: nonce, ciphertext: ciphertext);
    } finally {
      derivedKey.dispose();
    }
  }

  @override
  Uint8List unwrapSecret({required WrappedSecret wrapped, required String passphrase}) {
    final pwhash = _s.crypto.pwhash;
    final aead = _s.crypto.aeadXChaCha20Poly1305IETF;

    final derivedKey = pwhash(
      outLen: aead.keyBytes,
      password: passphrase.toCharArray(),
      salt: wrapped.salt,
      opsLimit: pwhash.opsLimitInteractive,
      memLimit: pwhash.memLimitInteractive,
      alg: CryptoPwhashAlgorithm.argon2id13,
    );
    try {
      return aead.decrypt(cipherText: wrapped.ciphertext, nonce: wrapped.nonce, key: derivedKey);
    } finally {
      derivedKey.dispose();
    }
  }

  @override
  EncryptedPayload encryptDirectMessage({
    required SecureKey mySecretKey,
    required Uint8List theirPublicKey,
    required Uint8List plaintext,
  }) {
    final box = _s.crypto.box;
    final nonce = _s.randombytes.buf(box.nonceBytes);
    final precalculated = box.precalculate(publicKey: theirPublicKey, secretKey: mySecretKey);
    try {
      final ciphertext = precalculated.easy(message: plaintext, nonce: nonce);
      return EncryptedPayload(ciphertext: ciphertext, nonce: nonce);
    } finally {
      precalculated.dispose();
    }
  }

  @override
  Uint8List decryptDirectMessage({
    required SecureKey mySecretKey,
    required Uint8List theirPublicKey,
    required EncryptedPayload payload,
  }) {
    final box = _s.crypto.box;
    final precalculated = box.precalculate(publicKey: theirPublicKey, secretKey: mySecretKey);
    try {
      return precalculated.openEasy(cipherText: payload.ciphertext, nonce: payload.nonce);
    } finally {
      precalculated.dispose();
    }
  }

  @override
  SecureKey generateGroupKey() => _s.crypto.aeadXChaCha20Poly1305IETF.keygen();

  @override
  Uint8List sealGroupKeyForMember({
    required Uint8List memberPublicKey,
    required SecureKey groupKey,
  }) {
    final rawKey = groupKey.extractBytes();
    return _s.crypto.box.seal(message: rawKey, publicKey: memberPublicKey);
  }

  @override
  SecureKey openSealedGroupKey({
    required IdentityKeyPair myKeyPair,
    required Uint8List sealed,
  }) {
    final rawKey = _s.crypto.box.sealOpen(
      cipherText: sealed,
      publicKey: myKeyPair.publicKey,
      secretKey: myKeyPair.secretKey,
    );
    return _s.secureCopy(rawKey);
  }

  @override
  EncryptedPayload encryptGroupMessage({
    required SecureKey groupKey,
    required String conversationId,
    required Uint8List plaintext,
  }) {
    final aead = _s.crypto.aeadXChaCha20Poly1305IETF;
    final nonce = _s.randombytes.buf(aead.nonceBytes);
    final ciphertext = aead.encrypt(
      message: plaintext,
      nonce: nonce,
      key: groupKey,
      additionalData: utf8.encode(conversationId),
    );
    return EncryptedPayload(ciphertext: ciphertext, nonce: nonce);
  }

  @override
  Uint8List decryptGroupMessage({
    required SecureKey groupKey,
    required String conversationId,
    required EncryptedPayload payload,
  }) {
    final aead = _s.crypto.aeadXChaCha20Poly1305IETF;
    return aead.decrypt(
      cipherText: payload.ciphertext,
      nonce: payload.nonce,
      key: groupKey,
      additionalData: utf8.encode(conversationId),
    );
  }

  bool _bytesEqual(Uint8List a, Uint8List b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}

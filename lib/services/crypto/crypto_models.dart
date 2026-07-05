import 'dart:convert';
import 'dart:typed_data';

import 'package:sodium/sodium_sumo.dart';

/// An unlocked identity keypair, held in memory only for the lifetime of the
/// browser tab/app session. Never persisted in this form.
class IdentityKeyPair {
  const IdentityKeyPair({required this.publicKey, required this.secretKey});

  final Uint8List publicKey;
  final SecureKey secretKey;

  void dispose() => secretKey.dispose();
}

/// A private key (or group key) encrypted at rest with a key derived from the
/// user's password via Argon2id. This is what actually lives in local
/// storage.
class WrappedSecret {
  const WrappedSecret({
    required this.salt,
    required this.nonce,
    required this.ciphertext,
  });

  final Uint8List salt;
  final Uint8List nonce;
  final Uint8List ciphertext;

  Map<String, String> toJson() => {
    'salt': base64Encode(salt),
    'nonce': base64Encode(nonce),
    'ciphertext': base64Encode(ciphertext),
  };

  static WrappedSecret fromJson(Map<String, dynamic> json) => WrappedSecret(
    salt: base64Decode(json['salt'] as String),
    nonce: base64Decode(json['nonce'] as String),
    ciphertext: base64Decode(json['ciphertext'] as String),
  );
}

/// A message ciphertext + the nonce it was sealed with. Both travel together
/// in the `messages` row (see `messages.ciphertext` / `messages.nonce`).
class EncryptedPayload {
  const EncryptedPayload({required this.ciphertext, required this.nonce});

  final Uint8List ciphertext;
  final Uint8List nonce;
}

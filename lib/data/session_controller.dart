import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../core/errors/humanize_error.dart';
import '../domain/models.dart';
import '../services/crypto/crypto_models.dart';
import '../services/crypto/crypto_service.dart';
import '../services/crypto/key_storage.dart';
import '../services/supabase/supabase_providers.dart';
import 'profile_repository.dart';
import 'providers.dart';

enum SessionStatus {
  /// Checking Supabase session / profile / local key on startup.
  loading,
  signedOut,

  /// Signed in, but no `profiles` row yet — first-ever login for this account.
  needsProfileSetup,

  /// Signed in, profile exists. Either this device already has a wrapped key
  /// and needs the password to unlock it, or it doesn't (new device /
  /// cleared storage) and one gets generated transparently once the
  /// password is entered — same screen either way, no manual key handling.
  needsPassword,

  /// Identity key is decrypted and held in memory. The app is usable.
  ready,
}

class SessionState {
  const SessionState({required this.status, this.profile, this.identityKeyPair});

  final SessionStatus status;
  final AppProfile? profile;
  final IdentityKeyPair? identityKeyPair;

  SessionState _copyWith({SessionStatus? status, AppProfile? profile, IdentityKeyPair? identityKeyPair}) {
    return SessionState(
      status: status ?? this.status,
      profile: profile ?? this.profile,
      identityKeyPair: identityKeyPair ?? this.identityKeyPair,
    );
  }
}

class SessionController extends Notifier<SessionState> {
  WrappedSecret? _wrappedKeyCache;

  /// Password from the sign-in/sign-up form, held in memory only for the
  /// few seconds between authenticating and the key being generated/wrapped
  /// — exactly like a real messenger, there's no separate "encryption
  /// password" for the user to invent; it's the same account password.
  String? _pendingPassword;

  @override
  SessionState build() {
    ref.listen(authStateProvider, (previous, next) {
      next.whenData((_) => _refresh());
    });
    Future.microtask(_refresh);
    return const SessionState(status: SessionStatus.loading);
  }

  SupabaseClient get _client => ref.read(supabaseClientProvider);
  CryptoService get _crypto => ref.read(cryptoServiceProvider);
  KeyStorage get _storage => ref.read(keyStorageProvider);
  ProfileRepository get _profiles => ref.read(profileRepositoryProvider);

  /// Called right after a successful sign-in/sign-up so later steps in this
  /// same session don't have to ask for the password again.
  void cachePassword(String password) => _pendingPassword = password;

  Future<void> _refresh() async {
    final user = _client.auth.currentUser;
    if (user == null) {
      state.identityKeyPair?.dispose();
      state = const SessionState(status: SessionStatus.signedOut);
      return;
    }

    await _crypto.ensureReady();
    final profile = await _profiles.fetchProfile(user.id);
    if (profile == null) {
      state = const SessionState(status: SessionStatus.needsProfileSetup);
      return;
    }

    _wrappedKeyCache = await _storage.loadWrappedPrivateKey(user.id);

    // If we just signed in this session (password still cached in memory),
    // unlock silently instead of asking for the same password a second
    // time. Deliberately stay in `loading` — not `needsPassword` — while
    // doing this: Argon2id is slow on purpose, and briefly setting
    // `needsPassword` first would flash the password screen for the second
    // or so it takes, only to immediately redirect away from it again.
    final cachedPassword = _pendingPassword;
    if (cachedPassword != null) {
      state = SessionState(status: SessionStatus.loading, profile: profile);
      final error = await unlock(cachedPassword);
      _pendingPassword = null;
      if (error == null) return; // unlock() already set state to ready
      // Silent unlock genuinely failed (e.g. stale cached password) — fall
      // through to ask explicitly, same as a fresh page load would.
    }

    state = SessionState(status: SessionStatus.needsPassword, profile: profile);
  }

  /// Unlocks (or, on a new device, transparently creates) the identity key
  /// for this session. Returns an error message, or null on success.
  Future<String?> unlock(String password) async {
    final user = _client.auth.currentUser;
    final profile = state.profile;
    if (user == null || profile == null) return 'Внутренняя ошибка сессии';

    final wrapped = _wrappedKeyCache;
    if (wrapped != null) {
      try {
        final secretBytes = _crypto.unwrapSecret(wrapped: wrapped, passphrase: password);
        final keyPair = _crypto.restoreIdentityKeyPair(
          secretKeyBytes: secretBytes,
          expectedPublicKey: profile.identityPubkey,
        );
        if (keyPair == null) {
          // Locally wrapped key doesn't match the server-side public key
          // anymore (e.g. it was regenerated from another device). Fall
          // through and treat this like a new device below.
        } else {
          state = state._copyWith(status: SessionStatus.ready, identityKeyPair: keyPair);
          return null;
        }
      } catch (_) {
        return 'Неверный пароль';
      }
    }

    // New device, or the local key no longer matches: generate a fresh
    // keypair transparently, the same way a normal messenger would when you
    // log in on a device that never had your keys. Old message history
    // becomes unreadable on this device — there is no server-side escrow.
    final keyPair = _crypto.generateIdentityKeyPair();
    try {
      await _profiles.updateIdentityPubkey(userId: user.id, identityPubkey: keyPair.publicKey);
    } catch (e) {
      keyPair.dispose();
      return 'Не удалось создать ключ для этого устройства. ${humanizeError(e)}';
    }

    final secretBytes = keyPair.secretKey.extractBytes();
    final newWrapped = _crypto.wrapSecret(secret: secretBytes, passphrase: password);
    await _storage.saveWrappedPrivateKey(user.id, newWrapped);
    _wrappedKeyCache = newWrapped;

    state = state._copyWith(
      status: SessionStatus.ready,
      profile: AppProfile(
        id: profile.id,
        username: profile.username,
        displayName: profile.displayName,
        identityPubkey: keyPair.publicKey,
        avatarUrl: profile.avatarUrl,
      ),
      identityKeyPair: keyPair,
    );
    return null;
  }

  /// Forgets whatever key is wrapped locally and re-runs [unlock], which
  /// then takes the "new device" path and generates a fresh keypair. Used
  /// when the account password was reset via email — the old local key was
  /// wrapped with a password that no longer exists, so unlocking normally
  /// always fails with "wrong password" for reasons the user can't fix.
  Future<String?> resetLocalKeyAndUnlock(String password) async {
    final user = _client.auth.currentUser;
    if (user != null) await _storage.clear(user.id);
    _wrappedKeyCache = null;
    return unlock(password);
  }

  /// First-ever login: creates the profile and the identity keypair, using
  /// the password already cached from sign-up via [cachePassword].
  Future<String?> setUpProfile({required String username, required String displayName}) async {
    final user = _client.auth.currentUser;
    final password = _pendingPassword;
    if (user == null) return 'Нет активной сессии';
    if (password == null) return 'Сессия истекла — войди снова';

    if (username.trim().length < 3) return 'Имя пользователя — минимум 3 символа';
    if (await _profiles.isUsernameTaken(username)) return 'Это имя пользователя уже занято';

    final keyPair = _crypto.generateIdentityKeyPair();
    AppProfile profile;
    try {
      profile = await _profiles.createProfile(
        id: user.id,
        username: username,
        displayName: displayName.trim().isEmpty ? username : displayName,
        identityPubkey: keyPair.publicKey,
      );
    } catch (e) {
      keyPair.dispose();
      return 'Не удалось создать профиль. ${humanizeError(e)}';
    }

    final secretBytes = keyPair.secretKey.extractBytes();
    final wrapped = _crypto.wrapSecret(secret: secretBytes, passphrase: password);
    await _storage.saveWrappedPrivateKey(user.id, wrapped);
    _pendingPassword = null;

    state = SessionState(status: SessionStatus.ready, profile: profile, identityKeyPair: keyPair);
    return null;
  }

  Future<void> signOut() async {
    state.identityKeyPair?.dispose();
    _pendingPassword = null;
    await _client.auth.signOut();
    state = const SessionState(status: SessionStatus.signedOut);
  }
}

final sessionControllerProvider = NotifierProvider<SessionController, SessionState>(
  SessionController.new,
);

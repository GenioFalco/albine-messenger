import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';

import '../domain/models.dart';
import '../services/crypto/crypto_service.dart';
import '../services/crypto/key_storage.dart';
import '../services/signal/signal_local_store.dart';
import '../services/signal/signal_service.dart';
import '../services/supabase/supabase_providers.dart';
import 'auth_repository.dart';
import 'chat_repository.dart';
import 'key_backup_repository.dart';
import 'profile_repository.dart';
import 'session_controller.dart';
import 'signal_directory_repository.dart';

final cryptoServiceProvider = Provider<CryptoService>((ref) => SodiumCryptoService());

final keyStorageProvider = Provider<KeyStorage>((ref) => LocalKeyStorage());

final authRepositoryProvider = Provider<AuthRepository>((ref) {
  return AuthRepository(ref.watch(supabaseClientProvider));
});

final profileRepositoryProvider = Provider<ProfileRepository>((ref) {
  return ProfileRepository(ref.watch(supabaseClientProvider));
});

final keyBackupRepositoryProvider = Provider<KeyBackupRepository>((ref) {
  return KeyBackupRepository(ref.watch(supabaseClientProvider));
});

final signalDirectoryRepositoryProvider = Provider<SignalDirectoryRepository>((ref) {
  return SignalDirectoryRepository(ref.watch(supabaseClientProvider));
});

/// `null` until the session is ready, same lifetime as [chatRepositoryProvider]
/// — rebuilt (with a fresh local store) whenever the signed-in account
/// changes, since `SignalLocalStore` is scoped to one user id.
final signalServiceProvider = Provider<SignalService?>((ref) {
  final session = ref.watch(sessionControllerProvider);
  final profile = session.profile;
  if (session.status != SessionStatus.ready || profile == null) {
    return null;
  }
  return SignalService(
    store: SignalLocalStore(profile.id),
    directory: ref.watch(signalDirectoryRepositoryProvider),
    myUserId: profile.id,
  );
});

/// `null` until the session is fully unlocked (profile loaded + identity key
/// decrypted in memory). Screens should treat a null repository as "not
/// ready yet" — the router only lets you reach screens that need it once
/// [SessionStatus.ready] is true anyway.
final chatRepositoryProvider = Provider<ChatRepository?>((ref) {
  final session = ref.watch(sessionControllerProvider);
  final keyPair = session.identityKeyPair;
  final signal = ref.watch(signalServiceProvider);
  if (session.status != SessionStatus.ready || keyPair == null || signal == null) {
    return null;
  }
  final client = ref.watch(supabaseClientProvider);
  return ChatRepository(
    client: client,
    crypto: ref.watch(cryptoServiceProvider),
    myKeyPair: keyPair,
    myUserId: client.auth.currentUser!.id,
    signal: signal,
  );
});

final conversationsStreamProvider = StreamProvider.autoDispose<List<ConversationSummary>>((ref) {
  final repo = ref.watch(chatRepositoryProvider);
  if (repo == null) return const Stream.empty();
  return repo.watchConversations();
});

final messagesStreamProvider = StreamProvider.autoDispose.family<List<ChatMessage>, String>((
  ref,
  conversationId,
) {
  final repo = ref.watch(chatRepositoryProvider);
  if (repo == null) return const Stream.empty();
  return repo.watchMessages(conversationId);
});

final conversationSummaryProvider = FutureProvider.autoDispose.family<ConversationSummary?, String>((
  ref,
  conversationId,
) {
  final repo = ref.watch(chatRepositoryProvider);
  if (repo == null) return Future.value(null);
  return repo.fetchConversationSummary(conversationId);
});

/// Which conversation is shown inline in the desktop 3-pane layout's detail
/// column. Unused on narrow/mobile layouts, which push `/chats/:id` instead.
final selectedConversationIdProvider = StateProvider<String?>((ref) => null);

import 'dart:convert';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'dart:typed_data';

import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:web/web.dart' as web;

/// Web Push subscription management — request permission, subscribe via the
/// browser's own `PushManager`, save the subscription server-side so the
/// `notify-new-message` edge function can reach this device. Strict E2E
/// still holds throughout: the push payload the server ever sends is a
/// generic "new message" notice (see `web/push_sw.js`), never plaintext —
/// there's no server-side content to leak in the first place.
class PushRepository {
  PushRepository(this._client, this._userId);

  final SupabaseClient _client;
  final String _userId;

  /// False on browsers with no Push API at all (e.g. Safari on iOS unless
  /// this PWA has been added to the Home Screen) — callers should hide the
  /// notifications toggle entirely in that case rather than show a button
  /// that can never work.
  bool get isSupported =>
      web.window.has('PushManager') &&
      web.window.has('Notification') &&
      web.window.navigator.has('serviceWorker');

  /// Standard VAPID key transform — browsers want the
  /// `applicationServerKey` as raw bytes, not the base64url string a VAPID
  /// keypair is normally generated/shared as.
  Uint8List _urlBase64ToBytes(String base64String) {
    final padded = base64String.padRight(
      base64String.length + (4 - base64String.length % 4) % 4,
      '=',
    );
    final normalized = padded.replaceAll('-', '+').replaceAll('_', '/');
    return base64Decode(normalized);
  }

  /// True if this device already has an active push subscription.
  Future<bool> isSubscribed() async {
    if (!isSupported) return false;
    final registration = await web.window.navigator.serviceWorker.ready.toDart;
    final existing = await registration.pushManager.getSubscription().toDart;
    return existing != null;
  }

  /// Requests notification permission (if not already granted) and
  /// subscribes this device, saving the subscription via an upsert keyed on
  /// `endpoint` (re-subscribing, e.g. after clearing browser data, just
  /// overwrites the same conceptual row rather than accumulating dupes).
  /// Returns false if permission was denied or the browser doesn't support
  /// push at all.
  Future<bool> subscribe(String vapidPublicKey) async {
    if (!isSupported) return false;

    final permission = await web.Notification.requestPermission().toDart;
    if (permission.toDart != 'granted') return false;

    final registration = await web.window.navigator.serviceWorker.ready.toDart;
    final existing = await registration.pushManager.getSubscription().toDart;
    final subscription =
        existing ??
        await registration.pushManager
            .subscribe(
              web.PushSubscriptionOptionsInit(
                userVisibleOnly: true,
                applicationServerKey: _urlBase64ToBytes(vapidPublicKey).toJS,
              ),
            )
            .toDart;

    final p256dh = subscription.getKey('p256dh');
    final auth = subscription.getKey('auth');
    if (p256dh == null || auth == null) return false;

    await _client.from('push_subscriptions').upsert({
      'user_id': _userId,
      'endpoint': subscription.endpoint,
      'p256dh': base64Encode(p256dh.toDart.asUint8List()),
      'auth_key': base64Encode(auth.toDart.asUint8List()),
    }, onConflict: 'endpoint');

    return true;
  }

  /// Unsubscribes this device and removes its row server-side.
  Future<void> unsubscribe() async {
    if (!isSupported) return;
    final registration = await web.window.navigator.serviceWorker.ready.toDart;
    final existing = await registration.pushManager.getSubscription().toDart;
    if (existing == null) return;
    final endpoint = existing.endpoint;
    await existing.unsubscribe().toDart;
    await _client.from('push_subscriptions').delete().eq('endpoint', endpoint);
  }
}

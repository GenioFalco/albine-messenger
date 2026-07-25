import 'package:flutter_dotenv/flutter_dotenv.dart';

class Env {
  Env._();

  static Future<void> load() => dotenv.load(fileName: '.env');

  static String get supabaseUrl => dotenv.get('SUPABASE_URL');

  static String get supabaseAnonKey => dotenv.get('SUPABASE_ANON_KEY');

  /// Null until set up (see ROADMAP.md's M4 section) — callers should treat
  /// that as "push notifications aren't configured yet" rather than crash;
  /// `dotenv.env[...]` (not `.get`) returns null for a missing key instead
  /// of throwing.
  static String? get vapidPublicKey => dotenv.env['VAPID_PUBLIC_KEY'];
}

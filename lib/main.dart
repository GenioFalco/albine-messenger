import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'app.dart';
import 'core/config/env.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Env.load();
  await Supabase.initialize(url: Env.supabaseUrl, publishableKey: Env.supabaseAnonKey);
  runApp(const ProviderScope(child: AlbineApp()));
}

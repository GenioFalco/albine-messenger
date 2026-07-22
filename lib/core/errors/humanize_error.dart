import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// Turns a raw exception (Supabase auth/Postgrest errors, or anything else)
/// into a short Russian sentence safe to show in the UI. The original
/// exception is still logged to the console for debugging — it just never
/// reaches the screen as raw English/technical text.
String humanizeError(Object error) {
  if (error is AuthException) return _humanizeAuth(error);
  if (error is PostgrestException) return _humanizePostgrest(error);

  debugPrint('Unhandled error shown to user: $error');
  return 'Что-то пошло не так. Попробуй ещё раз.';
}

String _humanizeAuth(AuthException e) {
  final code = e.code ?? '';
  final message = e.message.toLowerCase();

  if (code == 'over_email_send_rate_limit' || message.contains('rate limit')) {
    return 'Слишком много попыток за короткое время — сервер почты Supabase '
        'временно ограничивает отправку писем. Подожди немного (обычно '
        'помогает через несколько минут) и попробуй снова.';
  }
  if (code == 'invalid_credentials' ||
      message.contains('invalid login credentials')) {
    return 'Неверный email или пароль.';
  }
  if (code == 'user_already_exists' || message.contains('already registered')) {
    return 'Этот email уже зарегистрирован — попробуй войти.';
  }
  if (code == 'email_not_confirmed' ||
      message.contains('email not confirmed')) {
    return 'Email не подтверждён — проверь почту и перейди по ссылке из письма.';
  }
  if (message.contains('password') && message.contains('character')) {
    return 'Пароль слишком короткий — минимум 6 символов.';
  }
  if (message.contains('email') && message.contains('valid')) {
    return 'Проверь, правильно ли указан email.';
  }

  debugPrint(
    'Unhandled AuthException shown to user: code=$code message=${e.message}',
  );
  return 'Не получилось выполнить это действие. Попробуй ещё раз чуть позже.';
}

String _humanizePostgrest(PostgrestException e) {
  switch (e.code) {
    case '23505':
      return 'Такая запись уже существует.';
    case '42501':
      return 'Недостаточно прав для этого действия.';
    default:
      debugPrint('Unhandled PostgrestException shown to user: $e');
      return 'Не удалось получить данные с сервера. Попробуй ещё раз.';
  }
}

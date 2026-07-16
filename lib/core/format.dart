/// Short timestamp for a chat-list row: HH:mm if it's today, "вчера" for
/// yesterday, otherwise DD.MM. No intl dependency — hand-formatted.
String formatChatTimestamp(DateTime time, DateTime now) {
  final today = DateTime(now.year, now.month, now.day);
  final day = DateTime(time.year, time.month, time.day);
  final diffDays = today.difference(day).inDays;

  if (diffDays == 0) {
    final h = time.hour.toString().padLeft(2, '0');
    final m = time.minute.toString().padLeft(2, '0');
    return '$h:$m';
  }
  if (diffDays == 1) return 'вчера';
  final d = time.day.toString().padLeft(2, '0');
  final mo = time.month.toString().padLeft(2, '0');
  return '$d.$mo';
}

/// HH:mm stamp shown under/beside each message bubble — always just the
/// time, since the date is carried by the day separator above it instead.
String formatMessageTime(DateTime time) {
  final h = time.hour.toString().padLeft(2, '0');
  final m = time.minute.toString().padLeft(2, '0');
  return '$h:$m';
}

/// Day-separator label shown above the first message of each calendar day
/// in a chat, newest section at the bottom — "Сегодня"/"Вчера" for the
/// last two days, DD.MM.YYYY otherwise.
String formatDateSeparator(DateTime day, DateTime now) {
  final today = DateTime(now.year, now.month, now.day);
  final diffDays = today.difference(day).inDays;
  if (diffDays == 0) return 'Сегодня';
  if (diffDays == 1) return 'Вчера';
  final d = day.day.toString().padLeft(2, '0');
  final mo = day.month.toString().padLeft(2, '0');
  return '$d.$mo.${day.year}';
}

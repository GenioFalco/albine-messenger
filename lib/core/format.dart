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

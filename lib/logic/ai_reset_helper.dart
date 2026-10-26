class AiResetHelper {
  // Matches AiQuotaService's local calendar-day document key. This is the
  // app counter reset, not a prediction of Groq provider rate limits.
  static Map<String, String> getResetInfo({DateTime? now}) {
    final current = now ?? DateTime.now();
    final resetTime = DateTime(current.year, current.month, current.day + 1);
    final diff = resetTime.difference(current);
    return {
      'countdown': '${diff.inHours}h ${diff.inMinutes.remainder(60)}m',
      'timeText': 'Velora request counter resets at 00:00 local time',
    };
  }
}

/// Shared calendar-day policy for inventory expiry classification and labels.
abstract final class InventoryExpiryPolicy {
  static const int nearExpiryDays = 3;

  static DateTime calendarDate(DateTime value) =>
      DateTime(value.year, value.month, value.day);

  static int daysUntil(DateTime expiryDate, {DateTime? now}) {
    final today = calendarDate(now ?? DateTime.now());
    final expiry = calendarDate(expiryDate);
    return expiry.difference(today).inDays;
  }

  static bool isExpired(DateTime expiryDate, {DateTime? now}) =>
      daysUntil(expiryDate, now: now) < 0;

  static bool isNearExpiry(DateTime expiryDate, {DateTime? now}) {
    final days = daysUntil(expiryDate, now: now);
    return days >= 0 && days <= nearExpiryDays;
  }

  static String label(DateTime expiryDate, {DateTime? now}) {
    final days = daysUntil(expiryDate, now: now);
    if (days < 0) return 'Expired ${days.abs()} days ago';
    if (days == 0) return 'Expires today';
    if (days == 1) return 'Expires tomorrow';
    return 'Expires in $days days';
  }
}

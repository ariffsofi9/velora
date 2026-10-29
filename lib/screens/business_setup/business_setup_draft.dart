/// In-memory UI draft only. Never persisted or used as workspace authority.
class BusinessSetupDraft {
  static const businessTypes = [
    'Restaurant',
    'Caf\u00e9',
    'Bakery',
    'Catering',
    'Cloud Kitchen',
    'Other',
  ];
  static const units = ['kg', 'g', 'L', 'ml', 'pcs'];

  String businessName = '';
  String? businessType;
  String address = '';
  String unit = 'kg';
  bool lowStockAlerts = true;
  bool expiryReminders = true;
  int reminderDays = 3;
}

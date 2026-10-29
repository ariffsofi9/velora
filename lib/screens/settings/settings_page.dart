import '../../core/theme/app_tokens.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../services/user_profile_service.dart';
import '../auth/login_page.dart';
import '../team/team_management_page.dart';
import 'appearance_page.dart';
import 'widgets_settings/app_info_card.dart';
import 'widgets_settings/edit_profile_dialog.dart';
import 'widgets_settings/logout_card.dart';
import 'widgets_settings/notification_settings_card.dart';
import 'widgets_settings/preferences_settings_card.dart';
import 'widgets_settings/profile_header_card.dart';
import 'widgets_settings/settings_section_card.dart';

class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  final UserProfileService _userProfileService = UserProfileService();

  bool nearExpiryAlerts = true;
  bool lowStockAlerts = true;
  bool activityUpdates = false;
  bool darkModePrep = false;

  @override
  void initState() {
    super.initState();
    _loadSettings();
    _createUserProfile();
  }

  Future<void> _createUserProfile() async {
    final user = FirebaseAuth.instance.currentUser;

    if (user == null) return;

    await _userProfileService.createUserProfileIfNeeded(user);
  }

  Future<void> _loadSettings() async {
    final prefs = await SharedPreferences.getInstance();

    setState(() {
      nearExpiryAlerts = prefs.getBool('nearExpiryAlerts') ?? true;
      lowStockAlerts = prefs.getBool('lowStockAlerts') ?? true;
      activityUpdates = prefs.getBool('activityUpdates') ?? false;
      darkModePrep = prefs.getBool('darkModePrep') ?? false;
    });
  }

  Future<void> _saveBool(String key, bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(key, value);
  }

  Future<void> _openEditProfile(User user) async {
    final updated = await showDialog<bool>(
      context: context,
      builder: (_) => EditProfileDialog(user: user),
    );

    if (updated == true && mounted) {
      await FirebaseAuth.instance.currentUser?.reload();
      setState(() {});
    }
  }

  Future<void> _handleLogout() async {
    await FirebaseAuth.instance.signOut();

    if (!mounted) return;

    Navigator.pushAndRemoveUntil(
      context,
      MaterialPageRoute(builder: (_) => const LoginPage()),
      (route) => false,
    );
  }

  void _openTeamManagement() {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const TeamManagementPage()),
    );
  }

  void _openAppearance() {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => AppearancePage(
          initialDarkModePreference: darkModePrep,
          onPreferenceChanged: (value) {
            setState(() => darkModePrep = value);
            _saveBool('darkModePrep', value);
          },
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final user = FirebaseAuth.instance.currentUser;

    return Scaffold(
      backgroundColor: AppColors.background,
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 680),
            child: ListView(
              padding: const EdgeInsets.fromLTRB(18, 16, 18, 24),
              children: [
                const Text(
                  'Profile',
                  style: TextStyle(
                    fontSize: 26,
                    fontWeight: FontWeight.w700,
                    color: AppColors.textPrimary,
                  ),
                ),
                const SizedBox(height: 4),
                const Text(
                  'Manage your Velora account and app preferences.',
                  style: TextStyle(
                    fontSize: 14,
                    color: AppColors.textSecondary,
                  ),
                ),
                const SizedBox(height: 18),

                ProfileHeaderCard(
                  user: user,
                  onEdit: user == null ? null : () => _openEditProfile(user),
                ),

                const SizedBox(height: 18),

                SettingsSectionCard(
                  title: 'Account',
                  children: [
                    const _AccountTile(
                      icon: Icons.person_outline_rounded,
                      title: 'Edit Profile',
                      subtitle: 'Tap profile card to update name and photo',
                    ),
                    const _AccountTile(
                      icon: Icons.admin_panel_settings_outlined,
                      title: 'Account Role',
                      subtitle: 'Current user is prepared as Owner by default',
                    ),
                    _AccountTile(
                      icon: Icons.groups_2_outlined,
                      title: 'Team Management',
                      subtitle: 'View verified café membership',
                      onTap: _openTeamManagement,
                    ),
                  ],
                ),

                const SizedBox(height: 16),

                NotificationSettingsCard(
                  nearExpiryAlerts: nearExpiryAlerts,
                  lowStockAlerts: lowStockAlerts,
                  activityUpdates: activityUpdates,
                  onNearExpiryChanged: (value) {
                    setState(() => nearExpiryAlerts = value);
                    _saveBool('nearExpiryAlerts', value);
                  },
                  onLowStockChanged: (value) {
                    setState(() => lowStockAlerts = value);
                    _saveBool('lowStockAlerts', value);
                  },
                  onActivityChanged: (value) {
                    setState(() => activityUpdates = value);
                    _saveBool('activityUpdates', value);
                  },
                ),

                const SizedBox(height: 16),

                PreferencesSettingsCard(
                  darkModePrep: darkModePrep,
                  onOpenAppearance: _openAppearance,
                ),

                const SizedBox(height: 16),

                const AppInfoCard(),

                const SizedBox(height: 16),

                LogoutCard(onLogout: _handleLogout),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _AccountTile extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback? onTap;

  const _AccountTile({
    required this.icon,
    required this.title,
    required this.subtitle,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return ListTile(
      onTap: onTap,
      contentPadding: EdgeInsets.zero,
      leading: Container(
        height: 42,
        width: 42,
        decoration: BoxDecoration(
          color: AppColors.nude,
          borderRadius: BorderRadius.circular(14),
        ),
        child: Icon(icon, color: AppColors.primary),
      ),
      title: Text(
        title,
        style: const TextStyle(
          fontWeight: FontWeight.w700,
          color: AppColors.textPrimary,
        ),
      ),
      subtitle: Text(
        subtitle,
        style: const TextStyle(fontSize: 12, color: AppColors.textSecondary),
      ),
      trailing: onTap == null ? null : const Icon(Icons.chevron_right_rounded),
    );
  }
}

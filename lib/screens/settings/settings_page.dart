import 'dart:async';

import '../../core/theme/app_tokens.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../services/user_profile_service.dart';
import '../../services/workspace_session.dart';
import '../auth/login_page.dart';
import '../team/team_management_page.dart';
import '../menu/menu_page.dart';
import 'appearance_page.dart';
import 'widgets_settings/app_info_card.dart';
import 'widgets_settings/edit_profile_dialog.dart';
import 'widgets_settings/logout_card.dart';
import 'widgets_settings/notification_settings_card.dart';
import 'widgets_settings/preferences_settings_card.dart';
import 'widgets_settings/profile_header_card.dart';
import 'widgets_settings/settings_section_card.dart';

class SettingsPage extends StatefulWidget {
  final WorkspaceSession? workspaceSession;
  final FirebaseAuth? auth;
  final UserProfileService? profileService;
  final Future<SharedPreferences> Function()? preferences;
  const SettingsPage({
    super.key,
    this.workspaceSession,
    this.auth,
    this.profileService,
    this.preferences,
  });

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  FirebaseAuth get _auth => widget.auth ?? FirebaseAuth.instance;
  StreamSubscription<User?>? _authChanges;
  int _generation = 0;
  bool _loggingOut = false, _saving = false, _preferencesReady = false;
  String? _preferencesError;
  bool get _authorized =>
      !_loggingOut &&
      widget.workspaceSession?.isActive == true &&
      _auth.currentUser?.uid == widget.workspaceSession?.uid &&
      _auth.currentUser?.emailVerified == true;
  bool _current(int generation) =>
      mounted && generation == _generation && _authorized;
  Future<SharedPreferences> _preferences() =>
      (widget.preferences ?? SharedPreferences.getInstance)();
  void _feedback(String message) {
    if (mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(message)));
    }
  }

  bool nearExpiryAlerts = true;
  bool lowStockAlerts = true;
  bool activityUpdates = false;
  bool darkModePrep = false;

  @override
  void initState() {
    super.initState();
    _authChanges = _auth.idTokenChanges().listen(
      (user) {
        if (user?.uid != widget.workspaceSession?.uid ||
            user?.emailVerified != true) {
          _generation++;
          widget.workspaceSession?.invalidate();
        }
        if (mounted) setState(() {});
      },
      onError: (Object _) {
        _generation++;
        widget.workspaceSession?.invalidate();
        if (mounted) setState(() {});
      },
    );
    _loadSettings();
    _createUserProfile();
  }

  Future<void> _createUserProfile() async {
    if (!_authorized) return;
    final generation = _generation;
    try {
      await (widget.profileService ?? UserProfileService())
          .createUserProfileIfNeeded(_auth.currentUser!);
    } catch (_) {
      if (_current(generation)) {
        _feedback('Profile could not be loaded. Please retry later.');
      }
    }
  }

  Future<void> _loadSettings() async {
    if (!_authorized) return;
    final generation = _generation;
    try {
      final prefs = await _preferences();
      if (!_current(generation)) return;
      setState(() {
        nearExpiryAlerts = prefs.getBool('nearExpiryAlerts') ?? true;
        lowStockAlerts = prefs.getBool('lowStockAlerts') ?? true;
        activityUpdates = prefs.getBool('activityUpdates') ?? false;
        darkModePrep = prefs.getBool('darkModePrep') ?? false;
        _preferencesReady = true;
        _preferencesError = null;
      });
    } catch (_) {
      if (_current(generation)) {
        setState(() {
          _preferencesReady = false;
          _preferencesError = 'Local preferences could not be loaded.';
        });
      }
    }
  }

  bool _value(String key) => switch (key) {
    'nearExpiryAlerts' => nearExpiryAlerts,
    'lowStockAlerts' => lowStockAlerts,
    'activityUpdates' => activityUpdates,
    _ => darkModePrep,
  };
  void _setValue(String key, bool value) {
    switch (key) {
      case 'nearExpiryAlerts':
        nearExpiryAlerts = value;
      case 'lowStockAlerts':
        lowStockAlerts = value;
      case 'activityUpdates':
        activityUpdates = value;
      case 'darkModePrep':
        darkModePrep = value;
    }
  }

  Future<void> _saveBool(String key, bool value) async {
    if (!_authorized || !_preferencesReady || _saving) return;
    final generation = _generation, previous = _value(key);
    setState(() {
      _saving = true;
      _setValue(key, value);
    });
    try {
      final prefs = await _preferences();
      if (!_current(generation)) return;
      if (!await prefs.setBool(key, value)) {
        throw StateError('Preference not saved');
      }
    } catch (_) {
      if (_current(generation)) {
        setState(() => _setValue(key, previous));
        _feedback('Preference could not be saved. Please retry.');
      }
    } finally {
      if (mounted && generation == _generation) setState(() => _saving = false);
    }
  }

  Future<void> _openEditProfile(User user) async {
    if (!_authorized || _auth.currentUser?.uid != user.uid) return;
    final generation = _generation;
    final updated = await showDialog<bool>(
      context: context,
      builder: (_) => EditProfileDialog(user: user),
    );

    if (updated == true && _current(generation)) {
      try {
        await user.reload();
        if (_current(generation)) setState(() {});
      } catch (_) {
        if (_current(generation)) _feedback('Profile could not be refreshed.');
      }
    }
  }

  Future<void> _handleLogout() async {
    if (_loggingOut) return;
    _generation++;
    widget.workspaceSession?.invalidate();
    setState(() => _loggingOut = true);
    try {
      await _auth.signOut();
    } catch (_) {
      if (mounted) {
        setState(() => _loggingOut = false);
        _feedback('Sign out failed. Please retry.');
      }
      return;
    }

    if (!mounted) return;
    if (_auth.currentUser != null) {
      setState(() => _loggingOut = false);
      _feedback('Session changed. Please sign out again.');
      return;
    }

    Navigator.pushAndRemoveUntil(
      context,
      MaterialPageRoute(builder: (_) => const LoginPage()),
      (route) => false,
    );
  }

  void _openTeamManagement() {
    if (!_authorized) return;
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const TeamManagementPage()),
    );
  }

  void _openAppearance() {
    if (!_authorized || !_preferencesReady || _saving) return;
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => AppearancePage(
          initialDarkModePreference: darkModePrep,
          onPreferenceChanged: (value) {
            _saveBool('darkModePrep', value);
          },
        ),
      ),
    );
  }

  @override
  void didUpdateWidget(covariant SettingsPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.workspaceSession, widget.workspaceSession)) {
      _generation++;
      _saving = false;
      _preferencesReady = false;
      _loadSettings();
      _createUserProfile();
    }
  }

  @override
  void dispose() {
    _generation++;
    _authChanges?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final authorized = _authorized;
    final user = authorized ? _auth.currentUser : null;

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
                    _AccountTile(
                      icon: Icons.admin_panel_settings_outlined,
                      title: 'Account Role',
                      subtitle: authorized
                          ? 'Verified workspace role: ${widget.workspaceSession!.isOwner ? 'Owner' : 'Staff'}'
                          : 'Workspace access not verified',
                    ),
                    _AccountTile(
                      icon: Icons.groups_2_outlined,
                      title: 'Team Management',
                      subtitle: 'View verified café membership',
                      onTap: authorized ? _openTeamManagement : null,
                    ),
                    _AccountTile(
                      icon: Icons.restaurant_menu_rounded,
                      title: 'Menu Management',
                      subtitle: 'View menu items and availability',
                      onTap: !authorized
                          ? null
                          : () {
                              if (!_authorized) return;
                              Navigator.push(
                                context,
                                MaterialPageRoute(
                                  builder: (_) => const MenuPage(),
                                ),
                              );
                            },
                    ),
                  ],
                ),

                const SizedBox(height: 16),

                const Text(
                  'Notification choices are stored on this device only. Scheduling and delivery are not enabled here.',
                ),
                if (_preferencesError != null && authorized) ...[
                  Text(_preferencesError!),
                  TextButton(
                    onPressed: _loadSettings,
                    child: const Text('Retry preferences'),
                  ),
                ],
                IgnorePointer(
                  ignoring: !authorized || !_preferencesReady || _saving,
                  child: NotificationSettingsCard(
                    nearExpiryAlerts: nearExpiryAlerts,
                    lowStockAlerts: lowStockAlerts,
                    activityUpdates: activityUpdates,
                    onNearExpiryChanged: (value) {
                      _saveBool('nearExpiryAlerts', value);
                    },
                    onLowStockChanged: (value) {
                      _saveBool('lowStockAlerts', value);
                    },
                    onActivityChanged: (value) {
                      _saveBool('activityUpdates', value);
                    },
                  ),
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

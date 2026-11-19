import '../../../core/theme/app_tokens.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import '../../auth/workspace_gate.dart';
import '../../../services/android_pilot_policy.dart';

class EditProfileDialog extends StatefulWidget {
  final AndroidPilotAuthDependencies? pilot;
  final User user;

  const EditProfileDialog({super.key, required this.user, this.pilot});

  @override
  State<EditProfileDialog> createState() => _EditProfileDialogState();
}

class _EditProfileDialogState extends State<EditProfileDialog> {
  AndroidPilotAuthDependencies? get _pilot =>
      widget.pilot ?? AndroidPilotAuthScope.read(context);
  bool get _editable =>
      _pilot?.allows(AndroidPilotCapability.profileWrites) ?? true;
  late final TextEditingController nameController;
  late final TextEditingController photoController;

  bool isSaving = false;

  @override
  void initState() {
    super.initState();

    nameController = TextEditingController(text: widget.user.displayName ?? '');

    photoController = TextEditingController(text: widget.user.photoURL ?? '');
  }

  @override
  void dispose() {
    nameController.dispose();
    photoController.dispose();
    super.dispose();
  }

  Future<void> _saveProfile() async {
    if (!mounted || isSaving || !_editable) return;
    final pilot = _pilot;
    bool current() =>
        mounted &&
        _editable &&
        identical(pilot, _pilot) &&
        (pilot == null || pilot.auth.currentUser?.uid == widget.user.uid);
    if (!current()) return;
    final name = nameController.text.trim();
    final photoUrl = photoController.text.trim();

    setState(() => isSaving = true);

    try {
      await widget.user.updateDisplayName(name.isEmpty ? null : name);
      if (!current()) return;
      await widget.user.updatePhotoURL(photoUrl.isEmpty ? null : photoUrl);
      if (!current()) return;
      await widget.user.reload();

      if (!mounted) return;
      Navigator.pop(context, true);
    } catch (_) {
      if (!mounted) return;

      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Failed to update profile.')),
      );
    } finally {
      if (mounted) {
        setState(() => isSaving = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!_editable) {
      return AlertDialog(
        title: const Text('Profile editing unavailable'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
        ],
      );
    }
    return AlertDialog(
      backgroundColor: Colors.white,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
      title: const Text(
        'Edit Profile',
        style: TextStyle(
          fontWeight: FontWeight.w600,
          color: AppColors.textPrimary,
        ),
      ),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _InputField(
            controller: nameController,
            label: 'Username',
            icon: Icons.person_outline_rounded,
          ),
          const SizedBox(height: 12),
          _InputField(
            controller: photoController,
            label: 'Photo URL',
            icon: Icons.image_outlined,
          ),
          const SizedBox(height: 8),
          const Text(
            'For now, paste image URL. Firebase Storage upload can be added later.',
            style: TextStyle(fontSize: 12, color: AppColors.textSecondary),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: isSaving ? null : () => Navigator.pop(context, false),
          child: const Text('Cancel'),
        ),
        ElevatedButton(
          onPressed: isSaving ? null : _saveProfile,
          style: ElevatedButton.styleFrom(
            backgroundColor: AppColors.primary,
            foregroundColor: Colors.white,
          ),
          child: Text(isSaving ? 'Saving...' : 'Save'),
        ),
      ],
    );
  }
}

class _InputField extends StatelessWidget {
  final TextEditingController controller;
  final String label;
  final IconData icon;

  const _InputField({
    required this.controller,
    required this.label,
    required this.icon,
  });

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: controller,
      decoration: InputDecoration(
        prefixIcon: Icon(icon, color: AppColors.primary),
        labelText: label,
        filled: true,
        fillColor: AppColors.background,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: const BorderSide(color: AppColors.border),
        ),
      ),
    );
  }
}

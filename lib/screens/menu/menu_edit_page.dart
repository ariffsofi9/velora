import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import '../../core/theme/app_tokens.dart';
import '../../models/menu_item.dart';
import '../../repositories/workspace_menu_repository.dart';

class MenuEditPage extends StatefulWidget {
  final MenuRepository repository;
  final MenuItem? item;
  const MenuEditPage({super.key, required this.repository, this.item});
  @override
  State<MenuEditPage> createState() => _MenuEditPageState();
}

class _MenuEditPageState extends State<MenuEditPage> {
  final _form = GlobalKey<FormState>();
  final _name = TextEditingController(),
      _category = TextEditingController(),
      _price = TextEditingController();
  StreamSubscription<void>? _session;
  MenuItem? _item;
  bool _available = true, _busy = false, _blocked = false, _needsReload = false;
  String? _message, _key, _fingerprint;
  @override
  void initState() {
    super.initState();
    _item = widget.item;
    _fill();
    _session = widget.repository.sessionChanges.listen(
      (_) {
        if (mounted) {
          setState(() {
            _blocked = true;
            _message = const MenuException(MenuFailure.session).message;
          });
        }
      },
      onError: (Object _) {
        if (mounted) setState(() => _blocked = true);
      },
    );
  }

  void _fill() {
    final item = _item;
    if (item == null) return;
    _name.text = item.name;
    _category.text = item.category;
    _price.text =
        '${item.priceMinor ~/ 100}.${(item.priceMinor % 100).toString().padLeft(2, '0')}';
    _available = item.isAvailable;
  }

  @override
  void dispose() {
    _session?.cancel();
    _name.dispose();
    _category.dispose();
    _price.dispose();
    super.dispose();
  }

  Future<void> _reload() async {
    if (_item == null || _blocked) return;
    final latest = await widget.repository.get(_item!.id);
    if (!mounted || _blocked) return;
    setState(() {
      _item = latest;
      _fill();
      _key = null;
      _fingerprint = null;
      _needsReload = false;
      _message = latest.isArchived
          ? 'This item is archived. Restore it before editing.'
          : 'Latest values loaded. Review them and save again.';
    });
  }

  Future<void> _save() async {
    if (_busy ||
        _blocked ||
        _needsReload ||
        _item?.isArchived == true ||
        !_form.currentState!.validate()) {
      return;
    }
    final draft = MenuDraft(
      _name.text,
      _category.text,
      MenuDraft.parsePrice(_price.text),
      _available,
    );
    final fingerprint = jsonEncode({
      'itemId': _item?.id,
      'version': _item?.version,
      ...draft.toData(),
    });
    if (_fingerprint != fingerprint) {
      _fingerprint = fingerprint;
      _key = newMenuRequestKey();
    }
    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      await widget.repository.save(item: _item, draft: draft, key: _key!);
      if (mounted && !_blocked) Navigator.pop(context, true);
    } catch (error) {
      if (!mounted || _blocked) return;
      setState(
        () => _message = error is MenuException
            ? error.message
            : 'Unable to save menu. Try again.',
      );
      if (error is MenuException &&
          [MenuFailure.stale, MenuFailure.conflict].contains(error.failure)) {
        setState(() => _needsReload = true);
        try {
          await _reload();
        } catch (_) {
          if (mounted) {
            setState(
              () => _message =
                  'Unable to reload this item. Use Reload Latest before saving.',
            );
          }
        }
      }
      if (error is MenuException &&
          [
            MenuFailure.permission,
            MenuFailure.session,
          ].contains(error.failure)) {
        setState(() => _blocked = true);
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: AppColors.background,
    appBar: AppBar(
      title: Text(widget.item == null ? 'Add Menu Item' : 'Edit Menu Item'),
      backgroundColor: AppColors.background,
    ),
    body: _blocked
        ? Center(
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Text(
                _message ?? const MenuException(MenuFailure.session).message,
              ),
            ),
          )
        : Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 680),
              child: Form(
                key: _form,
                child: ListView(
                  padding: const EdgeInsets.all(20),
                  children: [
                    TextFormField(
                      controller: _name,
                      enabled: !_busy && !_blocked,
                      maxLength: 100,
                      decoration: const InputDecoration(labelText: 'Name'),
                      validator: (value) =>
                          value != null && MenuItem.validText(value.trim(), 100)
                          ? null
                          : 'Enter a valid name.',
                    ),
                    const SizedBox(height: 12),
                    TextFormField(
                      controller: _category,
                      enabled: !_busy && !_blocked,
                      maxLength: 60,
                      decoration: const InputDecoration(labelText: 'Category'),
                      validator: (value) =>
                          value != null && MenuItem.validText(value.trim(), 60)
                          ? null
                          : 'Enter a valid category.',
                    ),
                    const SizedBox(height: 12),
                    TextFormField(
                      controller: _price,
                      enabled: !_busy && !_blocked,
                      keyboardType: const TextInputType.numberWithOptions(
                        decimal: true,
                      ),
                      decoration: const InputDecoration(
                        labelText: 'Price (RM)',
                      ),
                      validator: (value) {
                        try {
                          MenuDraft.parsePrice(value ?? '');
                          return null;
                        } on FormatException catch (error) {
                          return error.message;
                        }
                      },
                    ),
                    const SizedBox(height: 12),
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('Available'),
                      value: _available,
                      onChanged: _busy || _blocked
                          ? null
                          : (value) => setState(() => _available = value),
                    ),
                    const SizedBox(height: 16),
                    FilledButton(
                      onPressed:
                          _busy ||
                              _blocked ||
                              _needsReload ||
                              _item?.isArchived == true
                          ? null
                          : _save,
                      child: Text(
                        _busy
                            ? 'Saving…'
                            : widget.item == null
                            ? 'Create Menu Item'
                            : 'Save Changes',
                      ),
                    ),
                    if (_item != null)
                      TextButton(
                        onPressed: _busy || _blocked
                            ? null
                            : () async {
                                setState(() => _busy = true);
                                try {
                                  await _reload();
                                } catch (_) {
                                  if (mounted) {
                                    setState(
                                      () => _message =
                                          'Unable to reload this item. Try again.',
                                    );
                                  }
                                } finally {
                                  if (mounted) setState(() => _busy = false);
                                }
                              },
                        child: const Text('Reload Latest'),
                      ),
                    if (_message != null)
                      Semantics(liveRegion: true, child: Text(_message!)),
                  ],
                ),
              ),
            ),
          ),
  );
}

import 'package:flutter/material.dart';

import '../../core/theme/app_tokens.dart';
import '../../models/inventory_item.dart';
import '../../logic/low_stock_policy.dart';
import '../../logic/inventory_expiry_policy.dart';
import '../../repositories/workspace_inventory_repository.dart';
import '../../services/workspace_session.dart';
import '../../services/workspace_inventory_https_transport.dart';
import '../inventory/item_details_page.dart';
import '../notifications/widgets_notification/notification_filter_bar.dart';

class AlertsPage extends StatefulWidget {
  final WorkspaceSession? workspaceSession;
  final WorkspaceInventoryRepository? repository;
  final HttpsWorkspaceInventory? inventoryMutations;
  final StockAttention? initialStockAttention;

  const AlertsPage({
    super.key,
    this.workspaceSession,
    this.repository,
    this.inventoryMutations,
    this.initialStockAttention,
  });

  @override
  State<AlertsPage> createState() => _AlertsPageState();
}

class _AlertsPageState extends State<AlertsPage> {
  static const red = Color(0xFFEF4444);
  static const orange = Color(0xFFF97316);

  Stream<List<InventoryItem>>? _itemsStream;
  WorkspaceInventoryRepository? _repository;
  late String _selectedFilter;
  static final _filters = [
    'All',
    ...StockAttention.values.map((attention) => attention.label),
    'Near Expiry',
  ];

  @override
  void initState() {
    super.initState();
    _selectedFilter = widget.initialStockAttention?.label ?? 'All';
    _configureInventory();
  }

  @override
  void didUpdateWidget(covariant AlertsPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.workspaceSession, widget.workspaceSession) ||
        !identical(oldWidget.repository, widget.repository)) {
      _configureInventory();
    }
    if (oldWidget.initialStockAttention != widget.initialStockAttention) {
      _selectedFilter = widget.initialStockAttention?.label ?? 'All';
    }
  }

  void _configureInventory() {
    final session = widget.workspaceSession;
    _repository =
        widget.repository ??
        (session != null && session.isActive
            ? WorkspaceInventoryRepository(session: session)
            : null);
    _itemsStream = _hasVerifiedInventory ? _repository!.watchItems() : null;
  }

  bool get _hasVerifiedInventory =>
      widget.workspaceSession?.isActive == true &&
      identical(_repository?.session, widget.workspaceSession);

  static const _accessUnavailable = Center(
    child: Padding(
      padding: EdgeInsets.all(24),
      child: Text(
        'Alerts are unavailable because workspace access was not verified.',
        textAlign: TextAlign.center,
        style: TextStyle(color: AppColors.textSecondary),
      ),
    ),
  );

  bool _isNearExpiry(InventoryItem item, DateTime now) =>
      InventoryExpiryPolicy.isNearExpiry(item.expiryDate, now: now);

  bool _matchesFilter({
    required StockAttention? attention,
    required bool isNearExpiry,
  }) {
    if (_selectedFilter == 'Near Expiry') return isNearExpiry;
    if (_selectedFilter == 'All') return attention != null || isNearExpiry;
    return attention?.label == _selectedFilter;
  }

  void _openItem(
    InventoryItem item,
    WorkspaceSession session,
    WorkspaceInventoryRepository repository,
  ) {
    if (!_hasVerifiedInventory ||
        !identical(session, widget.workspaceSession) ||
        !identical(repository, _repository)) {
      return;
    }
    final mutations = widget.inventoryMutations;
    Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => ItemDetailsPage(
          item: item,
          workspaceSession: session,
          repository: repository,
          updater: mutations,
          stockAdjuster: mutations,
          lifecycleManager: mutations,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final itemsStream = _itemsStream;
    if (itemsStream == null || !_hasVerifiedInventory) {
      return const Scaffold(
        backgroundColor: AppColors.background,
        body: SafeArea(child: _accessUnavailable),
      );
    }

    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        backgroundColor: AppColors.background,
        elevation: 0,
        title: const Text(
          'Alerts',
          style: TextStyle(
            color: AppColors.textPrimary,
            fontWeight: FontWeight.w700,
          ),
        ),
        iconTheme: const IconThemeData(color: AppColors.textPrimary),
      ),
      body: StreamBuilder<List<InventoryItem>>(
        key: ObjectKey(itemsStream),
        stream: itemsStream,
        builder: (context, snapshot) {
          if (!_hasVerifiedInventory) return _accessUnavailable;
          if (snapshot.hasError) {
            return Center(
              child: TextButton.icon(
                onPressed: () => setState(_configureInventory),
                icon: const Icon(Icons.refresh_rounded),
                label: const Text('Retry alerts'),
              ),
            );
          }
          if (!snapshot.hasData) {
            return const Center(
              child: CircularProgressIndicator(color: AppColors.primary),
            );
          }

          final now = DateTime.now();
          final session = widget.workspaceSession!;
          final repository = _repository!;
          final alerts = snapshot.data!
              .where((item) {
                return _matchesFilter(
                  attention: LowStockPolicy.attention(item),
                  isNearExpiry: _isNearExpiry(item, now),
                );
              })
              .toList(growable: false);

          return Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 760),
              child: SizedBox(
                height: double.infinity,
                child: Column(
                  children: [
                    NotificationFilterBar(
                      selected: _selectedFilter,
                      options: _filters,
                      onSelected: (value) {
                        setState(() => _selectedFilter = value);
                      },
                    ),
                    const SizedBox(height: 8),
                    Expanded(
                      child: alerts.isEmpty
                          ? const _EmptyAlerts()
                          : ListView.builder(
                              padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
                              itemCount: alerts.length,
                              itemBuilder: (context, index) {
                                final item = alerts[index];
                                return _InventoryAlertCard(
                                  key: ValueKey('inventory-alert-${item.id}'),
                                  name: item.name,
                                  quantity: item.quantity,
                                  unit: item.unit,
                                  attention: LowStockPolicy.attention(item),
                                  isNearExpiry: _isNearExpiry(item, now),
                                  onTap: () =>
                                      _openItem(item, session, repository),
                                );
                              },
                            ),
                    ),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

class _InventoryAlertCard extends StatelessWidget {
  final String name;
  final int quantity;
  final String unit;
  final StockAttention? attention;
  final bool isNearExpiry;
  final VoidCallback onTap;

  const _InventoryAlertCard({
    super.key,
    required this.name,
    required this.quantity,
    required this.unit,
    required this.attention,
    required this.isNearExpiry,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final stockMessage = switch (attention) {
      StockAttention.outOfStock => 'Out of stock',
      StockAttention.lowStock => 'Low stock: $quantity $unit left',
      null => null,
    };
    final message = [
      ?stockMessage,
      if (isNearExpiry) 'Expiring soon',
    ].join(' · ');
    final color = attention != null
        ? _AlertsPageState.red
        : _AlertsPageState.orange;

    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.border),
      ),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(14),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Row(
            children: [
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: color.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(
                  attention != null
                      ? Icons.warning_amber_rounded
                      : Icons.access_time_rounded,
                  color: color,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      name,
                      style: const TextStyle(
                        color: AppColors.textPrimary,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      message,
                      style: const TextStyle(
                        color: AppColors.textSecondary,
                        fontSize: 12,
                        fontWeight: FontWeight.w400,
                      ),
                    ),
                  ],
                ),
              ),
              const Icon(Icons.chevron_right, color: AppColors.textSecondary),
            ],
          ),
        ),
      ),
    );
  }
}

class _EmptyAlerts extends StatelessWidget {
  const _EmptyAlerts();

  @override
  Widget build(BuildContext context) => const Center(
    child: Text(
      'No active alerts.\nYour inventory looks good.',
      textAlign: TextAlign.center,
      style: TextStyle(
        color: AppColors.textSecondary,
        fontWeight: FontWeight.w400,
        height: 1.5,
      ),
    ),
  );
}

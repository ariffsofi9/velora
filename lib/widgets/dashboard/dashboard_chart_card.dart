import '../../core/theme/app_tokens.dart';
import 'package:flutter/material.dart';

import '../../logic/firestore_service.dart';

class DashboardChartCard extends StatelessWidget {
  const DashboardChartCard({super.key});

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<List<WeeklyInventoryActivity>>(
      stream: FirestoreService.instance.getWeeklyActivityStream(),
      builder: (context, snapshot) {
        final data = snapshot.data ?? _emptyData();

        return _ChartContent(weeklyData: data);
      },
    );
  }

  List<WeeklyInventoryActivity> _emptyData() {
    final days = ['M', 'T', 'W', 'T', 'F', 'S', 'S'];

    return List.generate(7, (index) {
      return WeeklyInventoryActivity(day: days[index], stockIn: 0, stockOut: 0);
    });
  }
}

class _ChartContent extends StatelessWidget {
  final List<WeeklyInventoryActivity> weeklyData;

  const _ChartContent({required this.weeklyData});

  int get _maxValue {
    if (weeklyData.isEmpty) return 1;

    final max = weeklyData
        .map((item) {
          final bigger = item.stockIn > item.stockOut
              ? item.stockIn
              : item.stockOut;
          return bigger;
        })
        .fold<int>(0, (a, b) => a > b ? a : b);

    return max == 0 ? 1 : max;
  }

  int get _totalStockIn {
    return weeklyData.fold(0, (sum, item) => sum + item.stockIn);
  }

  int get _totalStockOut {
    return weeklyData.fold(0, (sum, item) => sum + item.stockOut);
  }

  int get _totalThisWeek {
    return _totalStockIn + _totalStockOut;
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(18, 18, 18, 16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: AppColors.border),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.04),
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _header(),
          const SizedBox(height: 16),
          SizedBox(
            height: 138,
            child: Stack(
              children: [
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: 34,
                  child: Container(height: 1, color: AppColors.border),
                ),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: List.generate(7, (index) {
                    final item = weeklyData.length > index
                        ? weeklyData[index]
                        : WeeklyInventoryActivity(
                            day: '',
                            stockIn: 0,
                            stockOut: 0,
                          );

                    return Expanded(
                      child: _barGroup(
                        item: item,
                        active: index == DateTime.now().weekday - 1,
                      ),
                    );
                  }),
                ),
              ],
            ),
          ),
          const SizedBox(height: 14),
          _legend(),
          const SizedBox(height: 12),
          _weeklyInsight(),
        ],
      ),
    );
  }

  Widget _header() {
    return Row(
      children: [
        const Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Inventory Activity',
                style: TextStyle(
                  fontSize: 17,
                  fontWeight: FontWeight.w600,
                  color: AppColors.textPrimary,
                ),
              ),
              SizedBox(height: 5),
              Text(
                'Real stock in and stock out this week',
                style: TextStyle(
                  fontSize: 12,
                  color: AppColors.textSecondary,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 7),
          decoration: BoxDecoration(
            color: AppColors.nude,
            borderRadius: BorderRadius.circular(18),
          ),
          child: const Row(
            children: [
              Icon(Icons.circle, size: 8, color: AppColors.primary),
              SizedBox(width: 7),
              Text(
                'Live Weekly',
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  color: AppColors.primary,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _barGroup({
    required WeeklyInventoryActivity item,
    required bool active,
  }) {
    final stockInHeight = item.stockIn == 0
        ? 9.0
        : 78 * (item.stockIn / _maxValue);
    final stockOutHeight = item.stockOut == 0
        ? 9.0
        : 78 * (item.stockOut / _maxValue);

    return Column(
      mainAxisAlignment: MainAxisAlignment.end,
      children: [
        Text(
          item.total.toString(),
          style: TextStyle(
            fontSize: active ? 13 : 11,
            fontWeight: FontWeight.w600,
            color: active ? AppColors.primary : AppColors.textSecondary,
          ),
        ),
        const SizedBox(height: 6),
        SizedBox(
          height: 78,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              _smallBar(
                height: stockInHeight,
                color: AppColors.primary,
                isEmpty: item.stockIn == 0,
              ),
              const SizedBox(width: 4),
              _smallBar(
                height: stockOutHeight,
                color: const Color(0xFFF97316),
                isEmpty: item.stockOut == 0,
              ),
            ],
          ),
        ),
        const SizedBox(height: 8),
        Container(
          padding: EdgeInsets.symmetric(
            horizontal: active ? 12 : 0,
            vertical: active ? 4 : 0,
          ),
          decoration: BoxDecoration(
            color: active ? AppColors.nude : Colors.transparent,
            borderRadius: BorderRadius.circular(18),
          ),
          child: Text(
            item.day,
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w600,
              color: active ? AppColors.primary : AppColors.textSecondary,
            ),
          ),
        ),
      ],
    );
  }

  Widget _smallBar({
    required double height,
    required Color color,
    required bool isEmpty,
  }) {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 350),
      width: 9,
      height: height,
      decoration: BoxDecoration(
        color: isEmpty ? AppColors.nude : color,
        borderRadius: BorderRadius.circular(18),
      ),
    );
  }

  Widget _legend() {
    return const Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        _LegendItem(color: AppColors.primary, label: 'Stock In'),
        SizedBox(width: 18),
        _LegendItem(color: Color(0xFFF97316), label: 'Stock Out'),
      ],
    );
  }

  Widget _weeklyInsight() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.background,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: const Color(0xFFE9D5FF)),
      ),
      child: Row(
        children: [
          Container(
            width: 42,
            height: 42,
            decoration: BoxDecoration(
              color: AppColors.nude,
              borderRadius: BorderRadius.circular(16),
            ),
            child: const Icon(
              Icons.auto_graph_rounded,
              color: AppColors.primary,
              size: 22,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              '$_totalThisWeek total activity this week • $_totalStockIn in • $_totalStockOut out',
              style: const TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: AppColors.textSecondary,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _LegendItem extends StatelessWidget {
  final Color color;
  final String label;

  const _LegendItem({required this.color, required this.label});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Container(
          width: 9,
          height: 9,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
        const SizedBox(width: 6),
        Text(
          label,
          style: const TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w600,
            color: AppColors.textSecondary,
          ),
        ),
      ],
    );
  }
}

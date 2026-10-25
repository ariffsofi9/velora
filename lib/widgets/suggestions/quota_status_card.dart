import 'package:flutter/material.dart';

class QuotaStatusCard extends StatelessWidget {
  final int used;
  final int limit;
  final int remaining;
  final int cooldownSeconds;
  final String resetCountdown;
  final String resetTimeText;
  final String geminiStatus;

  const QuotaStatusCard({
    super.key,
    required this.used,
    required this.limit,
    required this.remaining,
    required this.cooldownSeconds,
    required this.resetCountdown,
    required this.resetTimeText,
    required this.geminiStatus,
  });

  bool get _isQuotaLimited {
    return geminiStatus.toLowerCase().contains('quota');
  }

  Color get _statusColor {
    final status = geminiStatus.toLowerCase();

    if (_isQuotaLimited) return const Color(0xFFEF4444);

    if (status.contains('available')) {
      return const Color(0xFF10B981);
    }

    if (status.contains('error')) {
      return const Color(0xFFF97316);
    }

    return const Color(0xFF7C3AED);
  }

  IconData get _statusIcon {
    final status = geminiStatus.toLowerCase();

    if (_isQuotaLimited) {
      return Icons.warning_amber_rounded;
    }

    if (status.contains('available')) {
      return Icons.check_circle_rounded;
    }

    return Icons.auto_awesome_rounded;
  }

  String get _mainText {
    if (cooldownSeconds > 0) {
      return 'Please wait $cooldownSeconds seconds';
    }

    return '$remaining / $limit Velora requests left today';
  }

  String get _statusMessage {
    final status = geminiStatus.toLowerCase();

    if (_isQuotaLimited) {
      return 'Fallback mode is ready';
    }

    if (status.contains('available')) {
      return 'Groq is ready';
    }

    if (status.contains('error')) {
      return 'Check API key or internet';
    }

    if (status.contains('cache')) {
      return 'Using last successful result';
    }

    return 'Tap generate when ready';
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(18, 18, 18, 16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(26),
        border: Border.all(color: const Color(0xFFE5E7EB)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.035),
            blurRadius: 18,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _QuotaIconBox(color: _statusColor, icon: _statusIcon),

          const SizedBox(width: 16),

          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _mainText,
                  style: const TextStyle(
                    color: Color(0xFF111827),
                    fontSize: 15,
                    fontWeight: FontWeight.w900,
                  ),
                ),

                const SizedBox(height: 8),

                Text(
                  'Reset estimate: $resetCountdown',
                  style: const TextStyle(
                    color: Color(0xFF6B7280),
                    fontSize: 13,
                    fontWeight: FontWeight.w800,
                  ),
                ),

                const SizedBox(height: 3),

                Text(
                  resetTimeText,
                  style: const TextStyle(
                    color: Color(0xFF9CA3AF),
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                  ),
                ),

                const SizedBox(height: 12),

                _GroqStatusCard(
                  color: _statusColor,
                  status: geminiStatus,
                  message: _statusMessage,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _QuotaIconBox extends StatelessWidget {
  final Color color;
  final IconData icon;

  const _QuotaIconBox({required this.color, required this.icon});

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 58,
      width: 58,
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Icon(icon, color: color, size: 27),
    );
  }
}

class _GroqStatusCard extends StatelessWidget {
  final Color color;
  final String status;
  final String message;

  const _GroqStatusCard({
    required this.color,
    required this.status,
    required this.message,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: color.withValues(alpha: 0.18)),
      ),
      child: Row(
        children: [
          Container(
            height: 8,
            width: 8,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          ),

          const SizedBox(width: 9),

          Expanded(
            child: Text(
              'Groq API: $status • $message',
              style: TextStyle(
                color: color,
                fontSize: 11.5,
                fontWeight: FontWeight.w900,
                height: 1.25,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

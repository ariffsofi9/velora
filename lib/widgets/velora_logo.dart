import 'package:flutter/material.dart';

/// Approved logo, including its embedded VELORA wordmark.
class VeloraLogo extends StatelessWidget {
  final double size;

  const VeloraLogo({super.key, this.size = 136}) : assert(size > 0);

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: size,
      child: AspectRatio(
        aspectRatio: 1,
        child: Image.asset(
          'assets/images/velora_app_icon_final.png',
          fit: BoxFit.contain,
          semanticLabel: 'Velora logo',
          filterQuality: FilterQuality.medium,
        ),
      ),
    );
  }
}

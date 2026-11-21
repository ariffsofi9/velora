import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

bool usesSideNavigation(BuildContext context) {
  final size = MediaQuery.sizeOf(context);
  final desktop = switch (defaultTargetPlatform) {
    TargetPlatform.windows ||
    TargetPlatform.macOS ||
    TargetPlatform.linux => true,
    _ => false,
  };
  return size.width >= 720 &&
      (size.width > size.height || (desktop && size.width >= 1024));
}

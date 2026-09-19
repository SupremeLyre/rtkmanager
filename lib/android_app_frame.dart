import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Paints behind system bars while keeping page controls inside safe insets.
class AndroidAppFrame extends StatelessWidget {
  const AndroidAppFrame({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final background = Theme.of(context).colorScheme.surface;
    final style =
        ThemeData.estimateBrightnessForColor(background) == Brightness.dark
        ? SystemUiOverlayStyle.light
        : SystemUiOverlayStyle.dark;
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: style.copyWith(
        statusBarColor: Colors.transparent,
        systemNavigationBarColor: Colors.transparent,
        systemNavigationBarIconBrightness: style.statusBarIconBrightness,
        systemNavigationBarDividerColor: Colors.transparent,
        systemStatusBarContrastEnforced: false,
        systemNavigationBarContrastEnforced: false,
      ),
      // SafeArea only adds padding; its surrounding pixels need a painted surface.
      child: ColoredBox(
        color: background,
        child: SafeArea(child: child),
      ),
    );
  }
}

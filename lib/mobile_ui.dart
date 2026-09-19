import 'package:flutter/material.dart';

/// Shared visual language for the Android tools: blue, light and functional.
ThemeData mobileTheme(ThemeData base) {
  final colors = base.colorScheme;
  final shape = RoundedRectangleBorder(borderRadius: BorderRadius.circular(16));
  return base.copyWith(
    scaffoldBackgroundColor: colors.surfaceContainerLowest,
    appBarTheme: base.appBarTheme.copyWith(
      backgroundColor: colors.surfaceContainerLowest,
      surfaceTintColor: Colors.transparent,
      toolbarHeight: 56,
      titleTextStyle: base.textTheme.titleMedium?.copyWith(
        color: colors.onSurface,
        fontWeight: FontWeight.w700,
        fontSize: 18,
      ),
    ),
    cardTheme: CardThemeData(
      elevation: 0,
      margin: EdgeInsets.zero,
      color: colors.surfaceContainerLow,
      shape: shape,
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        minimumSize: const Size(48, 48),
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        minimumSize: const Size(48, 48),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: colors.surfaceContainerLow,
      contentPadding: const EdgeInsets.all(16),
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide(color: colors.outlineVariant),
      ),
    ),
    dividerTheme: DividerThemeData(color: colors.outlineVariant),
  );
}

class MobileIconTile extends StatelessWidget {
  const MobileIconTile(
    this.icon, {
    super.key,
    this.size = 44,
    this.active = false,
  });
  final IconData icon;
  final double size;
  final bool active;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return ExcludeSemantics(
      child: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          color: active ? colors.primary : colors.primaryContainer,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Icon(
          icon,
          size: 24,
          color: active ? colors.onPrimary : colors.onPrimaryContainer,
        ),
      ),
    );
  }
}

class MobilePanel extends StatelessWidget {
  const MobilePanel({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(16),
  });
  final Widget child;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) => Container(
    width: double.infinity,
    padding: padding,
    decoration: BoxDecoration(
      color: Theme.of(context).colorScheme.surfaceContainerLow,
      borderRadius: BorderRadius.circular(16),
      border: Border.all(
        color: Theme.of(
          context,
        ).colorScheme.outlineVariant.withValues(alpha: .55),
      ),
    ),
    child: child,
  );
}

class MobileSectionTitle extends StatelessWidget {
  const MobileSectionTitle(
    this.title, {
    super.key,
    required this.icon,
    this.trailing,
  });
  final String title;
  final IconData icon;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: 24, bottom: 12),
    child: Row(
      children: [
        ExcludeSemantics(
          child: Icon(
            icon,
            size: 20,
            color: Theme.of(context).colorScheme.primary,
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            title,
            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
          ),
        ),
        if (trailing != null) trailing!,
      ],
    ),
  );
}

class MobileStatusChip extends StatelessWidget {
  const MobileStatusChip(
    this.label, {
    super.key,
    required this.icon,
    this.emphasized = false,
  });
  final String label;
  final IconData icon;
  final bool emphasized;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final foreground = emphasized
        ? colors.onPrimaryContainer
        : colors.onSurfaceVariant;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: emphasized
            ? colors.primaryContainer
            : colors.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(24),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          ExcludeSemantics(child: Icon(icon, size: 16, color: foreground)),
          const SizedBox(width: 6),
          Flexible(
            child: Text(
              label,
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: foreground,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class MobileHero extends StatelessWidget {
  const MobileHero({
    super.key,
    required this.title,
    required this.description,
    required this.icon,
    required this.status,
    this.action,
  });
  final String title;
  final String description;
  final IconData icon;
  final Widget status;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: colors.primaryContainer.withValues(alpha: .42),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: colors.primary.withValues(alpha: .12)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Align(alignment: Alignment.centerLeft, child: status),
              ),
              const SizedBox(width: 12),
              ExcludeSemantics(
                child: SizedBox(
                  width: 84,
                  height: 84,
                  child: CustomPaint(
                    painter: _SignalPainter(colors.primary),
                    child: Center(
                      child: Icon(icon, size: 32, color: colors.primary),
                    ),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Text(
            title,
            style: Theme.of(context).textTheme.headlineSmall?.copyWith(
              fontWeight: FontWeight.w700,
              fontSize: 23,
              color: colors.onSurface,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            description,
            style: TextStyle(color: colors.onSurfaceVariant, height: 1.6),
          ),
          if (action != null) ...[
            const SizedBox(height: 20),
            SizedBox(width: double.infinity, child: action!),
          ],
        ],
      ),
    );
  }
}

class _SignalPainter extends CustomPainter {
  _SignalPainter(this.color);
  final Color color;
  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    final paint = Paint()
      ..color = color.withValues(alpha: .16)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;
    for (final radius in [25.0, 34.0, 41.0]) {
      canvas.drawCircle(center, radius, paint);
    }
    canvas.drawCircle(
      center,
      25,
      Paint()..color = color.withValues(alpha: .08),
    );
    for (final point in [
      const Offset(16, 20),
      const Offset(72, 58),
      const Offset(43, 1),
    ]) {
      canvas.drawCircle(
        point,
        3,
        Paint()..color = color.withValues(alpha: .65),
      );
    }
  }

  @override
  bool shouldRepaint(_SignalPainter oldDelegate) => oldDelegate.color != color;
}

class MobileMetric extends StatelessWidget {
  const MobileMetric({
    super.key,
    required this.label,
    required this.value,
    required this.icon,
  });
  final String label;
  final String value;
  final IconData icon;
  @override
  Widget build(BuildContext context) => MobilePanel(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ExcludeSemantics(
          child: Icon(
            icon,
            size: 20,
            color: Theme.of(context).colorScheme.primary,
          ),
        ),
        const SizedBox(height: 12),
        Text(
          value,
          style: const TextStyle(fontSize: 21, fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 4),
        Text(
          label,
          style: TextStyle(
            fontSize: 12,
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
      ],
    ),
  );
}

class MobileMetrics extends StatelessWidget {
  const MobileMetrics({super.key, required this.children});
  final List<Widget> children;
  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final columns =
          MediaQuery.textScalerOf(context).scale(14) > 22 &&
              constraints.maxWidth < 400
          ? 1
          : constraints.maxWidth >= 600
          ? children.length
          : 2;
      return Wrap(
        spacing: 12,
        runSpacing: 12,
        children: [
          for (final child in children)
            SizedBox(
              width: (constraints.maxWidth - (columns - 1) * 12) / columns,
              child: child,
            ),
        ],
      );
    },
  );
}

class MobileEmptyState extends StatelessWidget {
  const MobileEmptyState({
    super.key,
    required this.icon,
    required this.title,
    required this.message,
  });
  final IconData icon;
  final String title;
  final String message;
  @override
  Widget build(BuildContext context) => MobilePanel(
    child: Column(
      children: [
        const SizedBox(height: 8),
        MobileIconTile(icon, size: 56),
        const SizedBox(height: 16),
        Text(
          title,
          textAlign: TextAlign.center,
          style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 16),
        ),
        const SizedBox(height: 8),
        Text(
          message,
          textAlign: TextAlign.center,
          style: TextStyle(
            color: Theme.of(context).colorScheme.onSurfaceVariant,
            height: 1.6,
          ),
        ),
        const SizedBox(height: 8),
      ],
    ),
  );
}

class MobileNotice extends StatelessWidget {
  const MobileNotice(
    this.message, {
    super.key,
    this.error = false,
    this.icon = Icons.info_outline,
  });
  final String message;
  final bool error;
  final IconData icon;
  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: error ? colors.errorContainer : colors.surfaceContainerLow,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ExcludeSemantics(
            child: Icon(
              error ? Icons.error_outline : icon,
              size: 20,
              color: error ? colors.onErrorContainer : colors.primary,
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              message,
              style: TextStyle(
                fontSize: 13,
                height: 1.5,
                color: error
                    ? colors.onErrorContainer
                    : colors.onSurfaceVariant,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

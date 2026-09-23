import 'package:flutter/material.dart';
import 'mobile_ui.dart';

export 'mobile_ui.dart';

/// The same page chrome and controls are used on handheld and desktop tools.
class AppPageBar extends StatelessWidget implements PreferredSizeWidget {
  const AppPageBar({
    super.key,
    required this.title,
    this.onOpenDrawer,
    this.actions,
    this.bottom,
  });
  final String title;
  final VoidCallback? onOpenDrawer;
  final List<Widget>? actions;
  final PreferredSizeWidget? bottom;

  @override
  Size get preferredSize =>
      Size.fromHeight(56 + (bottom?.preferredSize.height ?? 0));

  @override
  Widget build(BuildContext context) => AppBar(
    toolbarHeight: 56,
    title: FittedBox(
      fit: BoxFit.scaleDown,
      alignment: Alignment.centerLeft,
      child: Text(
        title,
        style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
      ),
    ),
    leading: onOpenDrawer == null
        ? null
        : IconButton(
            tooltip: '打开导航',
            icon: const Icon(Icons.menu),
            onPressed: onOpenDrawer,
          ),
    actions: actions,
    bottom: bottom,
  );
}

class AppDestination {
  const AppDestination(this.icon, this.title, this.description);
  final IconData icon;
  final String title;
  final String description;
}

class AppNavigationDrawer extends StatelessWidget {
  const AppNavigationDrawer({
    super.key,
    required this.destinations,
    required this.selectedIndex,
    required this.onSelected,
    this.keyPrefix = 'app-nav',
  });
  final List<AppDestination> destinations;
  final int selectedIndex;
  final ValueChanged<int> onSelected;
  final String keyPrefix;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Drawer(
      width: MediaQuery.sizeOf(context).width < 360 ? 280 : 304,
      child: ListView(
        padding: EdgeInsets.zero,
        children: [
          Container(
            padding: const EdgeInsets.all(24),
            color: colors.primaryContainer,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const MobileIconTile(
                  Icons.satellite_alt,
                  active: true,
                  size: 48,
                ),
                const SizedBox(height: 16),
                Text(
                  'RTK Manager',
                  style: TextStyle(
                    color: colors.onPrimaryContainer,
                    fontWeight: FontWeight.w700,
                    fontSize: 21,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  'by SupremeLyre',
                  style: TextStyle(
                    color: colors.onPrimaryContainer,
                    fontSize: 12,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          for (final (index, destination) in destinations.indexed)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
              child: ListTile(
                key: ValueKey('$keyPrefix-$index'),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14),
                ),
                selectedTileColor: colors.primaryContainer.withValues(
                  alpha: .6,
                ),
                leading: Icon(destination.icon),
                title: Text(
                  destination.title,
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
                subtitle: Text(
                  destination.description,
                  style: const TextStyle(fontSize: 12),
                ),
                selected: selectedIndex == index,
                onTap: () => onSelected(index),
              ),
            ),
          const SizedBox(height: 16),
        ],
      ),
    );
  }
}

class AppSectionCard extends StatelessWidget {
  const AppSectionCard({
    super.key,
    required this.title,
    required this.icon,
    required this.child,
  });
  final String title;
  final IconData icon;
  final Widget child;

  @override
  Widget build(BuildContext context) => Card(
    margin: EdgeInsets.zero,
    child: Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              MobileIconTile(icon, size: 36),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  title,
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          child,
        ],
      ),
    ),
  );
}

/// Keeps the same sections on both layouts and lets available space choose columns.
class AppColumns extends StatelessWidget {
  const AppColumns({
    super.key,
    required this.primary,
    required this.secondary,
    this.primaryFlex = 1,
    this.secondaryFlex = 1,
  });
  final Widget primary;
  final Widget secondary;
  final int primaryFlex;
  final int secondaryFlex;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final wide =
          constraints.maxWidth >=
          880 * (MediaQuery.textScalerOf(context).scale(14) / 14).clamp(1, 1.5);
      if (!wide) {
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [primary, const SizedBox(height: 16), secondary],
        );
      }
      return Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(flex: primaryFlex, child: primary),
          const SizedBox(width: 16),
          Expanded(flex: secondaryFlex, child: secondary),
        ],
      );
    },
  );
}

/// A form row stacks before either field becomes too narrow to read or edit.
class AppFieldPair extends StatelessWidget {
  const AppFieldPair({super.key, required this.first, required this.second});
  final Widget first;
  final Widget second;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      if (constraints.maxWidth <
          420 *
              (MediaQuery.textScalerOf(context).scale(14) / 14).clamp(1, 1.5)) {
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [first, const SizedBox(height: 12), second],
        );
      }
      return Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(flex: 3, child: first),
          const SizedBox(width: 12),
          Expanded(flex: 2, child: second),
        ],
      );
    },
  );
}

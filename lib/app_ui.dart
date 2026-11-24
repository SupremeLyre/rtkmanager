import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
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

/// Marks a subtree whose own drag or text-selection gestures must not open the
/// navigation drawer when swiping right.
class DrawerSwipeBlocker extends SingleChildRenderObjectWidget {
  const DrawerSwipeBlocker({
    super.key,
    this.enabled = true,
    required super.child,
  });

  final bool enabled;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderDrawerSwipeBlocker(enabled: enabled);

  @override
  void updateRenderObject(
    BuildContext context,
    RenderObject renderObject,
  ) {
    (renderObject as _RenderDrawerSwipeBlocker).enabled = enabled;
  }
}

class _RenderDrawerSwipeBlocker extends RenderProxyBox {
  _RenderDrawerSwipeBlocker({required this.enabled});

  bool enabled;
}

/// Hosts the app's navigation [drawer] and allows pulling it out by swiping
/// right anywhere that does not conflict with existing drag interactions.
class AppDrawerShell extends StatefulWidget {
  const AppDrawerShell({
    super.key,
    required this.drawer,
    required this.body,
  });

  final Widget drawer;
  final Widget body;

  @override
  State<AppDrawerShell> createState() => AppDrawerShellState();
}

class AppDrawerShellState extends State<AppDrawerShell>
    with SingleTickerProviderStateMixin {
  static const double _kMinFlingVelocity = 240.0;
  static const Duration _kBaseSettleDuration = Duration(milliseconds: 246);

  late final AnimationController _controller = AnimationController(
    duration: _kBaseSettleDuration,
    vsync: this,
  )
    ..addListener(_handleAnimationChanged)
    ..addStatusListener(_handleAnimationStatusChanged);

  final GlobalKey _drawerBoxKey = GlobalKey();
  final FocusScopeNode _focusScopeNode = FocusScopeNode();
  LocalHistoryEntry? _historyEntry;
  bool _openingFromClosed = false;

  bool get isDrawerOpen =>
      !_controller.isDismissed &&
      _controller.status != AnimationStatus.reverse;

  double get _drawerWidth {
    final box = _drawerBoxKey.currentContext?.findRenderObject() as RenderBox?;
    if (box != null && box.hasSize && box.size.width > 0) {
      return box.size.width;
    }
    return MediaQuery.sizeOf(context).width < 360 ? 280.0 : 304.0;
  }

  int get _directionFactor =>
      Directionality.of(context) == TextDirection.rtl ? -1 : 1;

  void _handleAnimationChanged() {
    if (mounted) setState(() {});
  }

  void _ensureHistoryEntry() {
    if (_historyEntry != null) return;
    final route = ModalRoute.of(context);
    if (route != null) {
      _historyEntry = LocalHistoryEntry(
        onRemove: _handleHistoryEntryRemoved,
        impliesAppBarDismissal: false,
      );
      route.addLocalHistoryEntry(_historyEntry!);
      FocusScope.of(context).setFirstFocus(_focusScopeNode);
    }
  }

  void _removeHistoryEntry() {
    final entry = _historyEntry;
    if (entry != null) {
      _historyEntry = null;
      entry.remove();
    }
  }

  void _handleHistoryEntryRemoved() {
    final wasActive = _historyEntry != null;
    _historyEntry = null;
    if (wasActive && mounted) {
      closeDrawer();
    }
  }

  void _handleAnimationStatusChanged(AnimationStatus status) {
    switch (status) {
      case AnimationStatus.forward:
        _ensureHistoryEntry();
      case AnimationStatus.reverse:
      case AnimationStatus.dismissed:
        _removeHistoryEntry();
      case AnimationStatus.completed:
        break;
    }
  }

  void openDrawer() {
    _ensureHistoryEntry();
    _controller.fling(velocity: 1.0);
  }

  void closeDrawer() {
    if (_controller.isDismissed) {
      _removeHistoryEntry();
      return;
    }
    _controller.fling(velocity: -1.0);
  }

  void _handleSwipeStart() {
    _openingFromClosed = _controller.value < 0.05;
    _controller.stop();
    _ensureHistoryEntry();
  }

  void _handleOpenDrawerDragDown(DragDownDetails details) {
    _openingFromClosed = false;
    _controller.stop();
    _ensureHistoryEntry();
  }

  void _move(DragUpdateDetails details) {
    final delta = details.primaryDelta ?? 0.0;
    if (delta == 0.0) return;
    final next = (_controller.value + delta / _drawerWidth * _directionFactor)
        .clamp(0.0, 1.0);
    if (next > 0.0) {
      _ensureHistoryEntry();
    }
    _controller.value = next;
  }

  void _settle(DragEndDetails details) {
    if (_controller.isDismissed) {
      _removeHistoryEntry();
      return;
    }
    final double xVelocity = details.velocity.pixelsPerSecond.dx;
    if (xVelocity.abs() >= _kMinFlingVelocity) {
      final double visualVelocity =
          xVelocity / _drawerWidth * _directionFactor;
      _controller.fling(velocity: visualVelocity);
    } else {
      final double threshold = _openingFromClosed ? 0.30 : 0.70;
      if (_controller.value < threshold) {
        closeDrawer();
      } else {
        openDrawer();
      }
    }
  }

  void _handleDragCancel() {
    if (_controller.isDismissed || _controller.isAnimating) {
      if (_controller.isDismissed) _removeHistoryEntry();
      return;
    }
    final double threshold = _openingFromClosed ? 0.30 : 0.70;
    if (_controller.value < threshold) {
      closeDrawer();
    } else {
      openDrawer();
    }
  }

  @override
  void dispose() {
    _removeHistoryEntry();
    _controller.dispose();
    _focusScopeNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final textDirection = Directionality.of(context);
    final scrimBase =
        DrawerTheme.of(context).scrimColor ?? Colors.black54;
    final effectiveScrimColor = scrimBase.withValues(
      alpha: scrimBase.a * _controller.value,
    );
    final platformHasBackButton =
        defaultTargetPlatform == TargetPlatform.android;

    final mediaQuery = MediaQuery.of(context);
    final rawTouchSlop = mediaQuery.gestureSettings.touchSlop;
    // Android devices report scaledTouchSlop around 6–8dp (~1mm), which causes
    // ListView's direction-blind VerticalDragGestureRecognizer to lock onto
    // thumb-pad contact roll before a horizontal swipe establishes direction.
    final effectiveGestureSettings = DeviceGestureSettings(
      touchSlop: rawTouchSlop == null
          ? kTouchSlop
          : math.max(kTouchSlop, rawTouchSlop),
    );

    return Actions(
      actions: <Type, Action<Intent>>{
        DismissIntent: CallbackAction<DismissIntent>(
          onInvoke: (_) {
            if (!_controller.isDismissed) closeDrawer();
            return null;
          },
        ),
      },
      child: Material(
        color: theme.scaffoldBackgroundColor,
        child: Stack(
          fit: StackFit.expand,
          children: [
            MediaQuery(
              data: mediaQuery.copyWith(
                gestureSettings: effectiveGestureSettings,
              ),
              child: _DrawerSwipeSurface(
                enabled: _controller.isDismissed,
                textDirection: textDirection,
                gestureSettings: effectiveGestureSettings,
                onStart: _handleSwipeStart,
                onUpdate: _move,
                onEnd: _settle,
                onCancel: _handleDragCancel,
                child: widget.body,
              ),
            ),
            if (!_controller.isDismissed)
              MediaQuery.removePadding(
                context: context,
                removeLeft: textDirection == TextDirection.rtl,
                removeRight: textDirection == TextDirection.ltr,
                child: ListTileTheme.merge(
                  style: ListTileStyle.drawer,
                  child: GestureDetector(
                    onHorizontalDragDown: _handleOpenDrawerDragDown,
                    onHorizontalDragUpdate: _move,
                    onHorizontalDragEnd: _settle,
                    onHorizontalDragCancel: _handleDragCancel,
                    excludeFromSemantics: true,
                    child: RepaintBoundary(
                      child: Stack(
                        fit: StackFit.expand,
                        children: [
                          BlockSemantics(
                            child: ExcludeSemantics(
                              excluding: platformHasBackButton,
                              child: GestureDetector(
                                behavior: HitTestBehavior.opaque,
                                onTap: closeDrawer,
                                child: Semantics(
                                  label: MaterialLocalizations.of(
                                    context,
                                  ).modalBarrierDismissLabel,
                                  child: ColoredBox(
                                    color: effectiveScrimColor,
                                    child: const SizedBox.expand(),
                                  ),
                                ),
                              ),
                            ),
                          ),
                          Align(
                            alignment: AlignmentDirectional.centerStart,
                            child: Align(
                              alignment: AlignmentDirectional.centerEnd,
                              widthFactor: _controller.value,
                              child: RepaintBoundary(
                                child: FocusScope(
                                  key: _drawerBoxKey,
                                  node: _focusScopeNode,
                                  child: widget.drawer,
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _DrawerSwipeSurface extends SingleChildRenderObjectWidget {
  const _DrawerSwipeSurface({
    required this.enabled,
    required this.textDirection,
    required this.gestureSettings,
    required this.onStart,
    required this.onUpdate,
    required this.onEnd,
    required this.onCancel,
    required super.child,
  });

  final bool enabled;
  final TextDirection textDirection;
  final DeviceGestureSettings? gestureSettings;
  final VoidCallback onStart;
  final ValueChanged<DragUpdateDetails> onUpdate;
  final ValueChanged<DragEndDetails> onEnd;
  final VoidCallback onCancel;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderDrawerSwipeSurface(
        enabled: enabled,
        textDirection: textDirection,
        gestureSettings: gestureSettings,
        onStart: onStart,
        onUpdate: onUpdate,
        onEnd: onEnd,
        onCancel: onCancel,
      );

  @override
  void updateRenderObject(
    BuildContext context,
    covariant _RenderDrawerSwipeSurface renderObject,
  ) {
    renderObject
      ..enabled = enabled
      ..textDirection = textDirection
      ..gestureSettings = gestureSettings
      ..onStart = onStart
      ..onUpdate = onUpdate
      ..onEnd = onEnd
      ..onCancel = onCancel;
  }
}

class _RenderDrawerSwipeSurface extends RenderProxyBox {
  _RenderDrawerSwipeSurface({
    required bool enabled,
    required TextDirection textDirection,
    required DeviceGestureSettings? gestureSettings,
    required VoidCallback onStart,
    required ValueChanged<DragUpdateDetails> onUpdate,
    required ValueChanged<DragEndDetails> onEnd,
    required VoidCallback onCancel,
  }) : _enabled = enabled,
       _textDirection = textDirection,
       _gestureSettings = gestureSettings,
       _onStart = onStart,
       _onUpdate = onUpdate,
       _onEnd = onEnd,
       _onCancel = onCancel;

  bool _enabled;
  set enabled(bool value) => _enabled = value;

  TextDirection _textDirection;
  set textDirection(TextDirection value) {
    _textDirection = value;
    _recognizer?.textDirection = value;
  }

  DeviceGestureSettings? _gestureSettings;
  set gestureSettings(DeviceGestureSettings? value) {
    _gestureSettings = value;
    _recognizer?.gestureSettings = value;
  }

  VoidCallback _onStart;
  set onStart(VoidCallback value) {
    _onStart = value;
    _recognizer?.onStart = value;
  }

  ValueChanged<DragUpdateDetails> _onUpdate;
  set onUpdate(ValueChanged<DragUpdateDetails> value) {
    _onUpdate = value;
    _recognizer?.onUpdate = value;
  }

  ValueChanged<DragEndDetails> _onEnd;
  set onEnd(ValueChanged<DragEndDetails> value) {
    _onEnd = value;
    _recognizer?.onEnd = value;
  }

  VoidCallback _onCancel;
  set onCancel(VoidCallback value) {
    _onCancel = value;
    _recognizer?.onCancel = value;
  }

  _RightSwipeGestureRecognizer? _recognizer;

  _RightSwipeGestureRecognizer _ensureRecognizer() {
    return _recognizer ??= _RightSwipeGestureRecognizer(debugOwner: this)
      ..textDirection = _textDirection
      ..gestureSettings = _gestureSettings
      ..onStart = _onStart
      ..onUpdate = _onUpdate
      ..onEnd = _onEnd
      ..onCancel = _onCancel;
  }

  static bool _isBlockedTarget(HitTestTarget target) {
    if (target is _RenderDrawerSwipeBlocker && target.enabled) {
      return true;
    }
    if (target is RenderEditable) {
      return true;
    }
    if (target is RenderTapRegion && target.groupId == EditableText) {
      return true;
    }
    return false;
  }

  @override
  bool hitTest(BoxHitTestResult result, {required Offset position}) {
    if (!size.contains(position)) return false;
    if (!_enabled) {
      return hitTestChildren(result, position: position);
    }
    final probe = BoxHitTestResult();
    final bool hitChild = hitTestChildren(probe, position: position);
    final bool blocked = probe.path.any(
      (entry) => _isBlockedTarget(entry.target),
    );
    if (!blocked) {
      // Register before vertical scrollables in body so angle-checked horizontal
      // right swipes on Android are not preempted by direction-blind vertical drags.
      result.add(BoxHitTestEntry(this, position));
    }
    hitTestChildren(result, position: position);
    return !blocked || hitChild;
  }

  @override
  void handleEvent(PointerEvent event, BoxHitTestEntry entry) {
    assert(debugHandleEvent(event, entry));
    if (event is PointerDownEvent && _enabled) {
      _ensureRecognizer().addPointer(event);
    }
  }

  @override
  void detach() {
    _recognizer?.dispose();
    _recognizer = null;
    super.detach();
  }

  @override
  void dispose() {
    _recognizer?.dispose();
    _recognizer = null;
    super.dispose();
  }
}

class _RightSwipeGestureRecognizer extends OneSequenceGestureRecognizer {
  _RightSwipeGestureRecognizer({super.debugOwner})
    : super(allowedButtonsFilter: (buttons) => buttons == kPrimaryButton);

  TextDirection textDirection = TextDirection.ltr;
  VoidCallback? onStart;
  ValueChanged<DragUpdateDetails>? onUpdate;
  ValueChanged<DragEndDetails>? onEnd;
  VoidCallback? onCancel;

  bool _tracking = false;
  bool _wonArena = false;
  bool _dragging = false;
  bool _startedCallbackSent = false;
  Offset _initialPosition = Offset.zero;
  Offset _lastPosition = Offset.zero;
  VelocityTracker? _velocityTracker;

  @override
  String get debugDescription => 'drawer right swipe';

  @override
  bool isPointerAllowed(PointerDownEvent event) {
    return !_tracking && super.isPointerAllowed(event);
  }

  @override
  void handleNonAllowedPointer(PointerDownEvent event) {
    if (!_tracking) {
      super.handleNonAllowedPointer(event);
    }
  }

  @override
  void addAllowedPointer(PointerDownEvent event) {
    super.addAllowedPointer(event);
    _tracking = true;
    _wonArena = false;
    _dragging = false;
    _startedCallbackSent = false;
    _initialPosition = event.position;
    _lastPosition = event.position;
    _velocityTracker = VelocityTracker.withKind(event.kind)
      ..addPosition(event.timeStamp, event.position);
  }

  void _emitStartIfNeeded() {
    if (!_startedCallbackSent) {
      _startedCallbackSent = true;
      invokeCallback<void>('onStart', () => onStart?.call());
    }
  }

  @override
  void handleEvent(PointerEvent event) {
    if (!_tracking) return;
    if (event is PointerMoveEvent) {
      if (!event.synthesized) {
        _velocityTracker?.addPosition(event.timeStamp, event.position);
      }
      final Offset totalDelta = event.position - _initialPosition;
      final Offset stepDelta = event.position - _lastPosition;
      _lastPosition = event.position;

      if (_dragging) {
        if (_wonArena && stepDelta.dx != 0.0) {
          _emitStartIfNeeded();
          invokeCallback<void>(
            'onUpdate',
            () => onUpdate?.call(
              DragUpdateDetails(
                sourceTimeStamp: event.timeStamp,
                globalPosition: event.position,
                localPosition: event.localPosition,
                delta: Offset(stepDelta.dx, 0.0),
                primaryDelta: stepDelta.dx,
              ),
            ),
          );
        }
        return;
      }

      final double dirSign = textDirection == TextDirection.rtl ? -1.0 : 1.0;
      final double forwardDx = totalDelta.dx * dirSign;
      final double absDy = totalDelta.dy.abs();
      final double rawSlop = computeHitSlop(event.kind, gestureSettings);
      final double slop = switch (event.kind) {
        PointerDeviceKind.mouse ||
        PointerDeviceKind.trackpad => math.max(kTouchSlop, rawSlop),
        _ => rawSlop,
      };

      if (forwardDx > slop && forwardDx > absDy) {
        _dragging = true;
        if (!_wonArena) {
          resolve(GestureDisposition.accepted);
        }
        if (_wonArena) {
          _emitStartIfNeeded();
          final double initialDelta = (forwardDx - slop) * dirSign;
          if (initialDelta != 0.0) {
            invokeCallback<void>(
              'onUpdate',
              () => onUpdate?.call(
                DragUpdateDetails(
                  sourceTimeStamp: event.timeStamp,
                  globalPosition: event.position,
                  localPosition: event.localPosition,
                  delta: Offset(initialDelta, 0.0),
                  primaryDelta: initialDelta,
                ),
              ),
            );
          }
        }
        return;
      }

      if (forwardDx < -slop || absDy > slop) {
        resolve(GestureDisposition.rejected);
        stopTrackingPointer(event.pointer);
        return;
      }
    } else if (event is PointerUpEvent) {
      if (_dragging && _wonArena) {
        _emitStartIfNeeded();
        final double vx = (_velocityTracker?.getVelocity() ?? Velocity.zero)
            .pixelsPerSecond
            .dx;
        invokeCallback<void>(
          'onEnd',
          () => onEnd?.call(
            DragEndDetails(
              velocity: Velocity(pixelsPerSecond: Offset(vx, 0.0)),
              primaryVelocity: vx,
              globalPosition: event.position,
              localPosition: event.localPosition,
            ),
          ),
        );
      } else {
        resolve(GestureDisposition.rejected);
      }
      stopTrackingPointer(event.pointer);
    } else if (event is PointerCancelEvent) {
      if (_dragging && _wonArena) {
        invokeCallback<void>('onCancel', () => onCancel?.call());
      } else {
        resolve(GestureDisposition.rejected);
      }
      stopTrackingPointer(event.pointer);
    }
  }

  @override
  void acceptGesture(int pointer) {
    _wonArena = true;
    if (_dragging) {
      _emitStartIfNeeded();
    }
  }

  @override
  void rejectGesture(int pointer) {
    final bool wasDragging = _dragging && _wonArena;
    _wonArena = false;
    _dragging = false;
    if (wasDragging) {
      invokeCallback<void>('onCancel', () => onCancel?.call());
    }
    stopTrackingPointer(pointer);
  }

  @override
  void didStopTrackingLastPointer(int pointer) {
    _tracking = false;
    _wonArena = false;
    _dragging = false;
    _startedCallbackSent = false;
    _velocityTracker = null;
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

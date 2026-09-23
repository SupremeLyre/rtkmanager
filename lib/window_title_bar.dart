import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:window_manager/window_manager.dart';

/// macOS-style visuals with the app's existing desktop window actions.
class WindowTitleBar extends StatefulWidget {
  const WindowTitleBar({super.key});

  @override
  State<WindowTitleBar> createState() => _WindowTitleBarState();
}

class _WindowTitleBarState extends State<WindowTitleBar> with WindowListener {
  bool _active = true;
  bool _maximized = false;
  bool _changingSize = false;
  int _revision = 0;

  @override
  void initState() {
    super.initState();
    windowManager.addListener(this);
    _readWindowState();
  }

  Future<void> _readWindowState() async {
    final revision = ++_revision;
    try {
      final values = await Future.wait([
        windowManager.isFocused(),
        windowManager.isMaximized(),
      ]);
      if (!mounted || revision != _revision) return;
      setState(() {
        _active = values[0];
        _maximized = values[1];
      });
    } catch (_) {
      // flutter-pi has no desktop window manager.
    }
  }

  void _update(VoidCallback update) {
    if (!mounted) return;
    _revision++;
    setState(update);
  }

  @override
  void onWindowFocus() => _update(() => _active = true);

  @override
  void onWindowBlur() => _update(() => _active = false);

  @override
  void onWindowMaximize() => _update(() => _maximized = true);

  @override
  void onWindowUnmaximize() => _update(() => _maximized = false);

  Future<void> _resize() async {
    if (_changingSize) return;
    _changingSize = true;
    try {
      // Read native state at activation, including changes made outside Flutter.
      if (await windowManager.isMaximized()) {
        await windowManager.unmaximize();
      } else {
        await windowManager.maximize();
      }
      await _readWindowState();
    } catch (_) {
      // No native window on embedded targets.
    } finally {
      _changingSize = false;
    }
  }

  Future<void> _close() async {
    try {
      await windowManager.close();
    } catch (_) {
      await SystemNavigator.pop();
    }
  }

  Future<void> _minimize() async {
    try {
      await windowManager.minimize();
    } catch (_) {
      // No native window on embedded targets.
    }
  }

  Future<void> _drag() async {
    try {
      await windowManager.startDragging();
    } catch (_) {
      // No native window on embedded targets.
    }
  }

  @override
  void dispose() {
    windowManager.removeListener(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    return SizedBox(
      height: 28,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: dark ? const Color(0xFF2B2B2B) : const Color(0xFFF1F1F1),
          border: Border(
            bottom: BorderSide(
              color: dark ? const Color(0xFF1D1D1D) : const Color(0xFFD9D9D9),
              width: .5,
            ),
          ),
        ),
        child: Stack(
          fit: StackFit.expand,
          children: [
            GestureDetector(
              key: const ValueKey('window-drag-area'),
              behavior: HitTestBehavior.opaque,
              onPanStart: (_) => _drag(),
              onDoubleTap: _resize,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 80),
                child: Center(
                  child: Text(
                    'RTK Manager',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: dark
                          ? (_active
                                ? const Color(0xFFE0E0E0)
                                : const Color(0xFF888888))
                          : (_active
                                ? const Color(0xFF4C4C4C)
                                : const Color(0xFF999999)),
                    ),
                  ),
                ),
              ),
            ),
            Positioned(
              left: 8,
              top: 0,
              bottom: 0,
              child: WindowButtons(
                active: _active,
                maximized: _maximized,
                onClose: _close,
                onMinimize: _minimize,
                onExpand: _resize,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class WindowButtons extends StatefulWidget {
  const WindowButtons({
    super.key,
    required this.active,
    required this.maximized,
    required this.onClose,
    required this.onMinimize,
    required this.onExpand,
  });

  final bool active;
  final bool maximized;
  final VoidCallback onClose;
  final VoidCallback onMinimize;
  final VoidCallback onExpand;

  @override
  State<WindowButtons> createState() => _WindowButtonsState();
}

class _WindowButtonsState extends State<WindowButtons> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) => MouseRegion(
    cursor: SystemMouseCursors.basic,
    onEnter: (_) => setState(() => _hovered = true),
    onExit: (_) => setState(() => _hovered = false),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        _TrafficLight(
          name: 'close',
          label: '关闭窗口',
          color: const Color(0xFFFF5F57),
          border: const Color(0xFFE0443E),
          ink: const Color(0xFF4D0000),
          glyph: _WindowGlyph.close,
          active: widget.active || _hovered,
          onPressed: widget.onClose,
        ),
        _TrafficLight(
          name: 'minimize',
          label: '最小化',
          color: const Color(0xFFFFBD2E),
          border: const Color(0xFFDEA123),
          ink: const Color(0xFF995700),
          glyph: _WindowGlyph.minimize,
          active: widget.active || _hovered,
          onPressed: widget.onMinimize,
        ),
        _TrafficLight(
          name: 'expand',
          label: widget.maximized ? '还原窗口' : '最大化',
          color: const Color(0xFF28C840),
          border: const Color(0xFF1AAB29),
          ink: const Color(0xFF006500),
          glyph: widget.maximized ? _WindowGlyph.restore : _WindowGlyph.expand,
          active: widget.active || _hovered,
          onPressed: widget.onExpand,
        ),
      ],
    ),
  );
}

enum _WindowGlyph { close, minimize, expand, restore }

class _TrafficLight extends StatefulWidget {
  const _TrafficLight({
    required this.name,
    required this.label,
    required this.color,
    required this.border,
    required this.ink,
    required this.glyph,
    required this.active,
    required this.onPressed,
  });

  final String name;
  final String label;
  final Color color;
  final Color border;
  final Color ink;
  final _WindowGlyph glyph;
  final bool active;
  final VoidCallback? onPressed;

  @override
  State<_TrafficLight> createState() => _TrafficLightState();
}

class _TrafficLightState extends State<_TrafficLight> {
  bool _pressed = false;
  bool _hovered = false;
  bool _focusHighlight = false;

  @override
  Widget build(BuildContext context) {
    final enabled = widget.onPressed != null;
    final colored = enabled && (widget.active || _focusHighlight);
    final dark = Theme.of(context).brightness == Brightness.dark;
    final fill = colored
        ? (_pressed
              ? Color.lerp(widget.color, Colors.black, .16)!
              : widget.color)
        : (dark ? const Color(0xFF555555) : const Color(0xFFDCDCDC));
    return Semantics(
      key: ValueKey('window-${widget.name}'),
      button: true,
      enabled: enabled,
      label: widget.label,
      onTap: widget.onPressed,
      child: MouseRegion(
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: Tooltip(
          message: widget.label,
          excludeFromSemantics: true,
          waitDuration: const Duration(milliseconds: 650),
          child: FocusableActionDetector(
            enabled: enabled,
            mouseCursor: SystemMouseCursors.basic,
            onShowFocusHighlight: (value) =>
                setState(() => _focusHighlight = value),
            shortcuts: const {
              SingleActivator(LogicalKeyboardKey.enter): ActivateIntent(),
              SingleActivator(LogicalKeyboardKey.space): ActivateIntent(),
            },
            actions: {
              ActivateIntent: CallbackAction<ActivateIntent>(
                onInvoke: (_) {
                  widget.onPressed?.call();
                  return null;
                },
              ),
            },
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              excludeFromSemantics: true,
              onTapDown: enabled
                  ? (_) => setState(() => _pressed = true)
                  : null,
              onTapCancel: enabled
                  ? () => setState(() => _pressed = false)
                  : null,
              onTapUp: enabled
                  ? (details) {
                      setState(() => _pressed = false);
                      if (const Rect.fromLTWH(
                        0,
                        0,
                        20,
                        28,
                      ).contains(details.localPosition)) {
                        widget.onPressed?.call();
                      }
                    }
                  : null,
              child: SizedBox(
                width: 20,
                height: 28,
                child: Center(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      border: _focusHighlight
                          ? Border.all(
                              color: Theme.of(context).colorScheme.primary,
                              width: 2,
                            )
                          : null,
                    ),
                    child: Padding(
                      padding: const EdgeInsets.all(3),
                      child: Container(
                        key: ValueKey('window-${widget.name}-disc'),
                        width: 12,
                        height: 12,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: fill,
                          border: Border.all(
                            width: .6,
                            color: colored
                                ? widget.border
                                : (dark
                                      ? const Color(0xFF444444)
                                      : const Color(0xFFC5C5C5)),
                          ),
                        ),
                        child:
                            enabled && (_hovered || _focusHighlight || _pressed)
                            ? CustomPaint(
                                key: ValueKey('window-${widget.name}-glyph'),
                                painter: _WindowGlyphPainter(
                                  widget.glyph,
                                  widget.ink,
                                ),
                              )
                            : null,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _WindowGlyphPainter extends CustomPainter {
  const _WindowGlyphPainter(this.glyph, this.color);
  final _WindowGlyph glyph;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.scale(size.width / 12, size.height / 12);
    final pen = Paint()
      ..color = color
      ..strokeWidth = 1.15
      ..strokeCap = StrokeCap.square;
    switch (glyph) {
      case _WindowGlyph.close:
        canvas.drawLine(const Offset(3.7, 3.7), const Offset(8.3, 8.3), pen);
        canvas.drawLine(const Offset(8.3, 3.7), const Offset(3.7, 8.3), pen);
      case _WindowGlyph.minimize:
        canvas.drawLine(const Offset(3, 6), const Offset(9, 6), pen);
      case _WindowGlyph.expand:
        canvas.drawPath(
          Path()
            ..moveTo(2.8, 2.8)
            ..lineTo(7, 2.8)
            ..lineTo(2.8, 7)
            ..close()
            ..moveTo(9.2, 9.2)
            ..lineTo(5, 9.2)
            ..lineTo(9.2, 5)
            ..close(),
          pen,
        );
      case _WindowGlyph.restore:
        canvas.drawPath(
          Path()
            ..moveTo(5.3, 5.3)
            ..lineTo(1.6, 5.3)
            ..lineTo(5.3, 1.6)
            ..close()
            ..moveTo(6.7, 6.7)
            ..lineTo(10.4, 6.7)
            ..lineTo(6.7, 10.4)
            ..close(),
          pen,
        );
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(_WindowGlyphPainter oldDelegate) =>
      glyph != oldDelegate.glyph || color != oldDelegate.color;
}

import 'dart:collection';
import 'package:flutter/material.dart';

/// Display state shared by map layers from any data source.
class MapLayerEntry {
  const MapLayerEntry({
    required this.id,
    required this.label,
    required this.color,
    this.visible = true,
  });

  final String id;
  final String label;
  final Color color;
  final bool visible;
}

class MapLayerController extends ChangeNotifier {
  final Map<String, MapLayerEntry> _layers = {};
  int _nextColorIndex = 0;
  UnmodifiableListView<MapLayerEntry> get layers =>
      UnmodifiableListView(_layers.values);
  MapLayerEntry? operator [](String id) => _layers[id];
  bool isVisible(String id) => _layers[id]?.visible ?? false;

  MapLayerEntry ensureLayer(String id, {String? label, Color? color}) {
    final existing = _layers[id];
    if (existing != null) return existing;
    final entry = MapLayerEntry(
      id: id,
      label: label ?? id,
      color: color ?? _deviceColor(_nextColorIndex++),
    );
    _layers[id] = entry;
    notifyListeners();
    return entry;
  }

  void setVisible(String id, bool visible) {
    final entry = _layers[id];
    if (entry == null || entry.visible == visible) return;
    _layers[id] = MapLayerEntry(
      id: id,
      label: entry.label,
      color: entry.color,
      visible: visible,
    );
    notifyListeners();
  }

  void setAllVisible(bool visible) {
    var changed = false;
    for (final entry in _layers.values.toList()) {
      if (entry.visible == visible) continue;
      _layers[entry.id] = MapLayerEntry(
        id: entry.id,
        label: entry.label,
        color: entry.color,
        visible: visible,
      );
      changed = true;
    }
    if (changed) notifyListeners();
  }

  void removeLayer(String id) {
    if (_layers.remove(id) != null) notifyListeners();
  }

  static Color _deviceColor(int index) {
    const palette = [
      Color(0xFF1565C0),
      Color(0xFFE65100),
      Color(0xFF00897B),
      Color(0xFF8E24AA),
      Color(0xFFC62828),
      Color(0xFF827717),
      Color(0xFF0086B3),
      Color(0xFFAD1457),
      Color(0xFF6D4C41),
      Color(0xFF3949AB),
      Color(0xFF2E7D32),
      Color(0xFFEF6C00),
    ];
    if (index < palette.length) return palette[index];
    return HSVColor.fromAHSV(1, (index * 137.508) % 360, .72, .8).toColor();
  }
}

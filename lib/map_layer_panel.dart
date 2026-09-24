import 'package:flutter/material.dart';
import 'map_layer_controller.dart';

/// A source-independent layer list; hiding a layer never deletes its data.
class MapLayerPanel extends StatelessWidget {
  const MapLayerPanel({
    super.key,
    required this.controller,
    this.pointCounts = const {},
    this.selectedId,
    this.onLocate,
    this.emptyMessage = '暂无图层',
  });

  final MapLayerController controller;
  final Map<String, int> pointCounts;
  final String? selectedId;
  final ValueChanged<String>? onLocate;
  final String emptyMessage;

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: controller,
    builder: (context, _) => Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Wrap(
          alignment: WrapAlignment.end,
          spacing: 8,
          children: [
            TextButton.icon(
              onPressed: controller.layers.isEmpty
                  ? null
                  : () => controller.setAllVisible(true),
              icon: const Icon(Icons.visibility_outlined, size: 18),
              label: const Text('全部显示'),
            ),
            TextButton.icon(
              onPressed: controller.layers.isEmpty
                  ? null
                  : () => controller.setAllVisible(false),
              icon: const Icon(Icons.visibility_off_outlined, size: 18),
              label: const Text('全部隐藏'),
            ),
          ],
        ),
        if (controller.layers.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 24),
            child: Text(emptyMessage, textAlign: TextAlign.center),
          ),
        for (final layer in controller.layers)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Row(
              children: [
                Checkbox(
                  key: ValueKey('layer-visible-${layer.id}'),
                  value: layer.visible,
                  semanticLabel:
                      '${layer.visible ? '隐藏' : '显示'} ${layer.label}',
                  onChanged: (value) => controller.setVisible(layer.id, value!),
                ),
                Container(
                  width: 12,
                  height: 12,
                  decoration: BoxDecoration(
                    color: layer.color,
                    shape: BoxShape.circle,
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        layer.label,
                        style: TextStyle(
                          fontWeight: selectedId == layer.id
                              ? FontWeight.w700
                              : FontWeight.w500,
                        ),
                      ),
                      Text(
                        '${pointCounts[layer.id] ?? 0} 个轨迹点',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ],
                  ),
                ),
                if (onLocate != null)
                  IconButton(
                    tooltip: '定位 ${layer.label}',
                    onPressed: (pointCounts[layer.id] ?? 0) == 0
                        ? null
                        : () => onLocate!(layer.id),
                    icon: const Icon(Icons.my_location, size: 20),
                  ),
              ],
            ),
          ),
      ],
    ),
  );
}

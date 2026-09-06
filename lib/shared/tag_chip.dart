import 'package:flutter/material.dart';

class TagChip extends StatelessWidget {
  const TagChip({
    super.key,
    required this.label,
    this.onDeleted,
  });

  final String label;
  final VoidCallback? onDeleted;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return InputChip(
      label: Text(label),
      visualDensity: VisualDensity.compact,
      backgroundColor: scheme.secondaryContainer,
      side: BorderSide.none,
      onDeleted: onDeleted,
      deleteIcon: onDeleted == null ? null : const Icon(Icons.close, size: 16),
    );
  }
}

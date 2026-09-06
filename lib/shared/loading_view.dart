import 'package:flutter/material.dart';

class LoadingView extends StatelessWidget {
  const LoadingView({super.key, this.label = '加载中…'});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const CircularProgressIndicator(),
          const SizedBox(height: 12),
          Text(label,
              style: TextStyle(
                  color: Theme.of(context).colorScheme.onSurfaceVariant)),
        ],
      ),
    );
  }
}

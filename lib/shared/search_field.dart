import 'package:flutter/material.dart';

import '../core/theme/glass.dart';

/// 全站搜索框：玻璃胶囊，塞在顶部动作行里而不是单独占一排。
///
/// 注意 `filled: false` + `InputBorder.none`：一旦有填充色，
/// 下面 [GlassPanel] 的 BackdropFilter 模糊就被盖住，玻璃质感全丢。
class SearchField extends StatelessWidget {
  const SearchField({
    super.key,
    required this.controller,
    required this.onChanged,
    this.hintText = '搜索',
    this.autofocus = false,
  });

  final TextEditingController controller;
  final ValueChanged<String> onChanged;
  final String hintText;
  final bool autofocus;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return GlassPanel(
      radius: 18,
      blur: 14,
      shadowY: 2,
      padding: const EdgeInsets.symmetric(horizontal: 10),
      child: Row(
        children: [
          Icon(Icons.search, size: 18, color: scheme.onSurfaceVariant),
          const SizedBox(width: 6),
          Expanded(
            child: TextField(
              controller: controller,
              autofocus: autofocus,
              onChanged: onChanged,
              textInputAction: TextInputAction.search,
              style: const TextStyle(fontSize: 14),
              decoration: InputDecoration(
                hintText: hintText,
                hintStyle: TextStyle(
                  fontSize: 13.5,
                  color: scheme.onSurfaceVariant,
                ),
                isDense: true,
                filled: false,
                border: InputBorder.none,
                enabledBorder: InputBorder.none,
                focusedBorder: InputBorder.none,
                contentPadding: const EdgeInsets.symmetric(vertical: 10),
              ),
            ),
          ),
          if (controller.text.isNotEmpty)
            InkWell(
              borderRadius: BorderRadius.circular(12),
              onTap: () {
                controller.clear();
                onChanged('');
              },
              child: Padding(
                padding: const EdgeInsets.all(4),
                child: Icon(
                  Icons.clear,
                  size: 17,
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

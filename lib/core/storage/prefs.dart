import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// shared_preferences 封装：非敏感设置、迷你缓存。
class Prefs {
  Prefs._();

  static const _panelOrderKey = 'panel_order';
  static const _defaultPanelKey = 'default_panel_id';
  static const _panelDataKey = 'panel_data';

  static Future<List<String>> readPanelOrder() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getStringList(_panelOrderKey) ?? [];
  }

  static Future<void> writePanelOrder(List<String> ids) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_panelOrderKey, ids);
  }

  static Future<String?> readDefaultPanelId() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_defaultPanelKey);
  }

  static Future<void> writeDefaultPanelId(String? id) async {
    final prefs = await SharedPreferences.getInstance();
    if (id == null) {
      await prefs.remove(_defaultPanelKey);
    } else {
      await prefs.setString(_defaultPanelKey, id);
    }
  }

  static Future<Map<String, String>> readPanelData() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_panelDataKey);
    if (raw == null || raw.isEmpty) return {};
    final map = jsonDecode(raw) as Map<String, dynamic>;
    return map.map((key, value) => MapEntry(key, value.toString()));
  }

  static Future<void> writePanelData(Map<String, String> data) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_panelDataKey, jsonEncode(data));
  }
}

import 'browser_models.dart';

/// 浏览器分身（虚拟浏览器数据镜像）。
///
/// 并不真的创建多个 WebView/内核，而是把“一个真实浏览器”的当前状态
/// 完整保存成一份镜像：当前网址、UA（指纹）、代理、收藏、历史、Cookie。
/// 切换分身 = 把真实浏览器整库替换成另一份镜像。
class BrowserProfile {
  BrowserProfile({
    required this.id,
    required this.name,
    this.isMain = false,
    this.ua,
    this.activeProxyId,
    this.currentUrl,
    List<BrowserBookmark>? bookmarks,
    List<BrowserHistoryEntry>? history,
    List<Map<String, dynamic>>? cookies,
    DateTime? updatedAt,
  })  : bookmarks = bookmarks ?? [],
        history = history ?? [],
        cookies = cookies ?? [],
        updatedAt = updatedAt ?? DateTime.now();

  final String id;
  String name;
  final bool isMain;
  String? ua;
  String? activeProxyId;
  String? currentUrl;
  List<BrowserBookmark> bookmarks;
  List<BrowserHistoryEntry> history;
  List<Map<String, dynamic>> cookies;
  DateTime updatedAt;

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'isMain': isMain,
        'ua': ua,
        'activeProxyId': activeProxyId,
        'currentUrl': currentUrl,
        'bookmarks': [for (final b in bookmarks) b.toJson()],
        'history': [for (final h in history) h.toJson()],
        'cookies': cookies,
        'updatedAt': updatedAt.toIso8601String(),
      };

  factory BrowserProfile.fromJson(Map<String, dynamic> json) {
    return BrowserProfile(
      id: json['id']?.toString() ?? '',
      name: json['name']?.toString() ?? '分身',
      isMain: json['isMain'] == true,
      ua: json['ua']?.toString(),
      activeProxyId: json['activeProxyId']?.toString(),
      currentUrl: json['currentUrl']?.toString(),
      bookmarks: [
        for (final item in (json['bookmarks'] as List? ?? const []))
          if (item is Map)
            BrowserBookmark.fromJson(Map<String, dynamic>.from(item)),
      ],
      history: [
        for (final item in (json['history'] as List? ?? const []))
          if (item is Map)
            BrowserHistoryEntry.fromJson(Map<String, dynamic>.from(item)),
      ],
      cookies: [
        for (final item in (json['cookies'] as List? ?? const []))
          if (item is Map)
            Map<String, dynamic>.from(item),
      ],
      updatedAt:
          DateTime.tryParse(json['updatedAt']?.toString() ?? '') ??
              DateTime.now(),
    );
  }
}

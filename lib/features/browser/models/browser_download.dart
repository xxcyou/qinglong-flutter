/// 浏览器下载任务。
class BrowserDownload {
  BrowserDownload({
    required this.id,
    required this.url,
    required this.name,
    this.status = BrowserDownloadStatus.downloading,
    this.progress = 0,
    this.receivedBytes = 0,
    this.totalBytes = 0,
    this.localPath,
    this.error,
  });

  final int id;
  final String url;
  final String name;
  BrowserDownloadStatus status;
  double progress;
  int receivedBytes;
  int totalBytes;
  String? localPath;
  String? error;

  BrowserDownload copyWith({
    BrowserDownloadStatus? status,
    double? progress,
    int? receivedBytes,
    int? totalBytes,
    String? localPath,
    String? error,
  }) {
    return BrowserDownload(
      id: id,
      url: url,
      name: name,
      status: status ?? this.status,
      progress: progress ?? this.progress,
      receivedBytes: receivedBytes ?? this.receivedBytes,
      totalBytes: totalBytes ?? this.totalBytes,
      localPath: localPath ?? this.localPath,
      error: error ?? this.error,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'url': url,
        'name': name,
        'status': status.name,
        'progress': progress,
        'receivedBytes': receivedBytes,
        'totalBytes': totalBytes,
        'localPath': localPath,
        'error': error,
      };

  factory BrowserDownload.fromJson(Map<String, dynamic> json) {
    return BrowserDownload(
      id: (json['id'] as num).toInt(),
      url: json['url']?.toString() ?? '',
      name: json['name']?.toString() ?? 'download',
      status: BrowserDownloadStatus.values.asNameMap()[json['status']] ??
          BrowserDownloadStatus.paused,
      progress: (json['progress'] as num?)?.toDouble() ?? 0,
      receivedBytes: (json['receivedBytes'] as num?)?.toInt() ?? 0,
      totalBytes: (json['totalBytes'] as num?)?.toInt() ?? 0,
      localPath: json['localPath']?.toString(),
      error: json['error']?.toString(),
    );
  }
}

enum BrowserDownloadStatus { downloading, paused, completed, failed }

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
}

enum BrowserDownloadStatus { downloading, paused, completed, failed }

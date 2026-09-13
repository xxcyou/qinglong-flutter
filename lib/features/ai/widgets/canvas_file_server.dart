import 'dart:io';

/// 画布本地文件服务。
///
/// ui_canvas 现在支持两类加载：
/// - 远程 URL：直接 WebView 加载，外链 CSS/JS/图片/请求都由页面本身负责；
/// - 本地路径：HTML 内容通过 `http://127.0.0.1:<随机端口>/` 提供，
///   同目录/子目录的 css/js/图片等相对路径资源也从这里读。
///
/// 之所以要起 HTTP 而不是 `file://`：WebView 跑 `file://` 页面时相对路径、
/// fetch 和外链限制很多；换成 localhost HTTP 后，HTML 的结构和普通网页一致。
class CanvasFileServer {
  CanvasFileServer._(this._server, this.baseUrl);

  final HttpServer _server;
  final String baseUrl;

  /// 开一个本地服务，[htmlContent] 作为首页返回，[rootPath] 为可选资源根目录。
  static Future<CanvasFileServer> start({
    required String htmlContent,
    String rootPath = '',
  }) async {
    final root = rootPath.trim().isEmpty ? null : Directory(rootPath.trim());
    if (root != null && !await root.exists()) {
      throw FileSystemException('资源根目录不存在', root.path);
    }
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final baseUrl = 'http://127.0.0.1:${server.port}/';

    server.listen((request) async {
      try {
        final rawPath = request.uri.path;
        final path = Uri.decodeComponent(rawPath);
        // 首页：一律放注入过桥代码的 HTML。
        if (path == '/' || path == '/index.html') {
          request.response
            ..statusCode = HttpStatus.ok
            ..headers.contentType = ContentType.html
            ..write(htmlContent);
          await request.response.close();
          return;
        }
        if (root == null) {
          await _notFound(request);
          return;
        }
        final file = await _resolveFile(root, path);
        if (file == null) {
          await _notFound(request);
          return;
        }
        final mime = _mimeFor(file.path);
        request.response
          ..statusCode = HttpStatus.ok
          ..headers.contentType = ContentType.parse(mime)
          ..headers.set('Cache-Control', 'no-store');
        await request.response.addStream(file.openRead());
        await request.response.close();
      } catch (_) {
        try {
          await _notFound(request);
        } catch (_) {}
      }
    });

    return CanvasFileServer._(server, baseUrl);
  }

  static Future<File?> _resolveFile(Directory root, String path) async {
    if (path.isEmpty || path == '/') return null;
    final rel = path.replaceFirst(RegExp(r'^/+'), '');
    // 拒绝路径穿越，只允许 root 内文件。
    if (rel.split('/').contains('..')) return null;
    final rootPath = root.absolute.path;
    final file = File('$rootPath${Platform.pathSeparator}$rel').absolute;
    if (!file.path.startsWith('$rootPath${Platform.pathSeparator}')) {
      return null;
    }
    final type = await FileSystemEntity.type(file.path);
    if (type != FileSystemEntityType.file) return null;
    return file;
  }

  static Future<void> _notFound(HttpRequest request) async {
    request.response
      ..statusCode = HttpStatus.notFound
      ..headers.contentType = ContentType.text
      ..write('404');
    await request.response.close();
  }

  static String _mimeFor(String path) {
    final ext = path.split('.').last.toLowerCase();
    return switch (ext) {
      'html' || 'htm' => 'text/html; charset=utf-8',
      'css' => 'text/css; charset=utf-8',
      'js' || 'mjs' => 'text/javascript; charset=utf-8',
      'json' => 'application/json; charset=utf-8',
      'png' => 'image/png',
      'jpg' || 'jpeg' => 'image/jpeg',
      'gif' => 'image/gif',
      'svg' => 'image/svg+xml',
      'webp' => 'image/webp',
      'ico' => 'image/x-icon',
      'bmp' => 'image/bmp',
      'avif' => 'image/avif',
      'woff' => 'font/woff',
      'woff2' => 'font/woff2',
      'ttf' => 'font/ttf',
      'otf' => 'font/otf',
      'eot' => 'application/vnd.ms-fontobject',
      'mp3' => 'audio/mpeg',
      'wav' => 'audio/wav',
      'ogg' => 'audio/ogg',
      'mp4' => 'video/mp4',
      'webm' => 'video/webm',
      'pdf' => 'application/pdf',
      'wasm' => 'application/wasm',
      'txt' => 'text/plain; charset=utf-8',
      'xml' => 'text/xml; charset=utf-8',
      'zip' => 'application/zip',
      _ => 'application/octet-stream',
    };
  }

  Future<void> close() async {
    await _server.close(force: true);
  }
}
